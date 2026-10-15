import Foundation
import Security

/// Stateless helpers for file utilities: secure random data generation, splitting
/// a file into ordered parts and joining parts back into a single file.
///
/// All heavy work streams in fixed-size blocks so memory stays flat regardless of
/// file size; callers run these functions on a background queue.
enum FileTools {

    /// Cancellation token shared with the caller (same shape as `DiskImager.Job`).
    final class Job {
        private let lock = NSLock()
        private var stopped = false
        func cancel() { lock.lock(); stopped = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    }

    enum ToolError: LocalizedError {
        case sourceUnreadable(String)
        case destinationUnwritable(String)
        case invalidSize
        case emptySource
        case noParts
        case cancelled
        case randomFailed

        var errorDescription: String? {
            switch self {
            case .sourceUnreadable(let path):      return "Cannot read source: \(path)"
            case .destinationUnwritable(let path): return "Cannot write destination: \(path)"
            case .invalidSize:                     return "The requested size is not valid."
            case .emptySource:                     return "The source is empty."
            case .noParts:                         return "No parts were supplied to join."
            case .cancelled:                       return "Operation cancelled."
            case .randomFailed:                    return "Could not obtain random bytes."
            }
        }
    }

    /// Upper bound for bytes generated straight into the editor, so a single edit
    /// never materialises an unbounded byte array in memory.
    static let maxGenerateBytes = 64 << 20   // 64 MiB

    // MARK: - Random data

    /// Generates `count` cryptographically-secure random bytes, reporting progress
    /// as each chunk is filled. Runs in a loop so large requests remain cancellable.
    static func randomBytes(count: Int,
                            job: Job = Job(),
                            progress: (Int) -> Void) throws -> [UInt8] {
        guard count > 0 else { throw ToolError.invalidSize }
        var out = [UInt8](repeating: 0, count: count)
        let chunk = 1 << 20
        var offset = 0
        while offset < count {
            if job.isCancelled { throw ToolError.cancelled }
            let n = min(chunk, count - offset)
            let ok: Bool = out.withUnsafeMutableBytes { buf in
                guard let base = buf.baseAddress else { return false }
                return SecRandomCopyBytes(kSecRandomDefault, n, base.advanced(by: offset)) == errSecSuccess
            }
            if !ok {
                // Fall back to the system generator (also cryptographically secure).
                var rng = SystemRandomNumberGenerator()
                for i in offset..<(offset + n) { out[i] = UInt8(truncatingIfNeeded: rng.next()) }
            }
            offset += n
            progress(offset)
        }
        return out
    }

    // MARK: - Split

    struct SplitPart {
        let url: URL
        let size: Int64
    }

    /// Splits `source` into ordered parts of at most `partSize` bytes each inside
    /// `folder`, named `<base>.<nnn>` (001, 002, …). Streams block by block.
    static func split(source: URL,
                      folder: URL,
                      baseName: String,
                      partSize: Int64,
                      blockSize: Int = 1 << 20,
                      job: Job = Job(),
                      progress: (Int64, Int64) -> Void) throws -> [SplitPart] {
        guard partSize > 0 else { throw ToolError.invalidSize }
        guard let input = FileHandle(forReadingAtPath: source.path) else {
            throw ToolError.sourceUnreadable(source.path)
        }
        defer { try? input.close() }

        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let base = DiskImager.sanitized(baseName)
        let total = DiskCloner.size(of: source)
        let block = max(512, blockSize & ~511)

        var parts: [SplitPart] = []
        var index = 0
        var handle: FileHandle?
        var partWritten: Int64 = 0
        var done: Int64 = 0
        progress(0, total)

        func openPart() throws {
            try handle?.close()
            index += 1
            let name = String(format: "%@.%03d", base, index)
            let url = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) { _ = fm.createFile(atPath: url.path, contents: nil) }
            guard let h = FileHandle(forWritingAtPath: url.path) else {
                throw ToolError.destinationUnwritable(url.path)
            }
            try? h.truncate(atOffset: 0)
            handle = h
            partWritten = 0
            parts.append(SplitPart(url: url, size: 0))
        }
        func closePart() throws {
            guard let h = handle else { return }
            try h.synchronize()
            try h.close()
            if !parts.isEmpty {
                parts[parts.count - 1] = SplitPart(url: parts[parts.count - 1].url, size: partWritten)
            }
            handle = nil
        }

        do {
            try openPart()
            while true {
                if job.isCancelled { throw ToolError.cancelled }
                let data = try DiskCloner.readFully(input, upTo: block)
                if data.isEmpty { break }
                var remaining = data
                while !remaining.isEmpty {
                    if partWritten >= partSize {
                        try closePart()
                        try openPart()
                    }
                    let take = min(partSize - partWritten, Int64(remaining.count))
                    try handle?.write(contentsOf: remaining.prefix(Int(take)))
                    partWritten += take
                    done += take
                    remaining = remaining.dropFirst(Int(take))
                    progress(done, total)
                }
            }
            try closePart()
        } catch {
            try? handle?.close()
            throw error
        }

        guard done > 0 else {
            for part in parts { try? fm.removeItem(at: part.url) }
            throw ToolError.emptySource
        }
        return parts
    }

    // MARK: - Join

    /// Concatenates `parts` (in the given order) into `destination`, streaming in
    /// fixed-size blocks. Returns the number of bytes written.
    @discardableResult
    static func join(parts: [URL],
                     destination: URL,
                     blockSize: Int = 1 << 20,
                     job: Job = Job(),
                     progress: (Int64, Int64) -> Void) throws -> Int64 {
        guard !parts.isEmpty else { throw ToolError.noParts }

        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path) {
            _ = fm.createFile(atPath: destination.path, contents: nil)
        }
        guard let out = FileHandle(forWritingAtPath: destination.path) else {
            throw ToolError.destinationUnwritable(destination.path)
        }
        defer { try? out.close() }

        // Only regular files are truncated; a device is written in place.
        let destIsRegular = (try? destination.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
        if destIsRegular { try out.truncate(atOffset: 0) }

        let block = max(512, blockSize & ~511)
        let total = parts.reduce(Int64(0)) { $0 + DiskCloner.size(of: $1) }
        var done: Int64 = 0
        progress(0, total)

        for part in parts {
            guard let input = FileHandle(forReadingAtPath: part.path) else {
                throw ToolError.sourceUnreadable(part.path)
            }
            do {
                while true {
                    if job.isCancelled { throw ToolError.cancelled }
                    let data = try DiskCloner.readFully(input, upTo: block)
                    if data.isEmpty { break }
                    try out.write(contentsOf: data)
                    done += Int64(data.count)
                    progress(done, total)
                }
                try input.close()
            } catch {
                try? input.close()
                throw error
            }
        }
        try out.synchronize()
        return done
    }
}
