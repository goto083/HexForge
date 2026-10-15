import Foundation

/// Copies a source (regular file or raw device) to a destination byte for byte,
/// in fixed-size blocks, with progress reporting and cancellation.
///
/// `clone(from:to:options:progress:)` is blocking and should be run on a
/// background queue; `cancel()` is safe to call from any thread.
final class DiskCloner {

    struct Options {
        /// Block size in bytes. Rounded down to a 512-byte boundary, min 512.
        var blockSize: Int = 1 << 20      // 1 MiB
        /// Re-read both sides afterwards and compare.
        var verify: Bool = false
    }

    enum CloneError: LocalizedError {
        case sameSourceAndDestination
        case sourceUnreadable(String)
        case destinationUnwritable(String)
        case cancelled
        case verifyMismatch(offset: Int64)

        var errorDescription: String? {
            switch self {
            case .sameSourceAndDestination:
                return L.t("Source and destination are the same.")
            case .sourceUnreadable(let path):
                return L.f("Cannot read source: %@", path)
            case .destinationUnwritable(let path):
                return L.f("Cannot write destination: %@", path)
            case .cancelled:
                return L.t("Clone cancelled.")
            case .verifyMismatch(let offset):
                return L.f("Verification failed at offset 0x%@.", String(offset, radix: 16).uppercased())
            }
        }
    }

    private let lock = NSLock()
    private var stopped = false

    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    /// - Parameter progress: called with `(bytesDone, totalBytes)`; `totalBytes`
    ///   is 0 when the source size could not be determined (e.g. some devices).
    func clone(from source: URL,
               to destination: URL,
               options: Options,
               progress: (Int64, Int64) -> Void) throws {

        if source.standardizedFileURL == destination.standardizedFileURL {
            throw CloneError.sameSourceAndDestination
        }

        guard let sourceHandle = FileHandle(forReadingAtPath: source.path) else {
            throw CloneError.sourceUnreadable(source.path)
        }
        defer { try? sourceHandle.close() }

        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path) {
            _ = fm.createFile(atPath: destination.path, contents: nil)
        }
        guard let destHandle = FileHandle(forWritingAtPath: destination.path) else {
            throw CloneError.destinationUnwritable(destination.path)
        }
        defer { try? destHandle.close() }

        // Only regular files are truncated; a device is written in place.
        let destIsRegular = (try? destination.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
        if destIsRegular {
            try destHandle.truncate(atOffset: 0)
        }

        let total = Self.size(of: source)
        let block = max(512, options.blockSize & ~511)
        var copied: Int64 = 0
        progress(0, total)

        while true {
            if isCancelled { throw CloneError.cancelled }
            let data = try Self.readFully(sourceHandle, upTo: block)
            if data.isEmpty { break }
            try destHandle.write(contentsOf: data)
            copied += Int64(data.count)
            progress(copied, total)
        }
        try destHandle.synchronize()

        if options.verify {
            try verify(source: source, destination: destination, blockSize: block, progress: progress)
        }
    }

    // MARK: - Verification

    private func verify(source: URL,
                        destination: URL,
                        blockSize: Int,
                        progress: (Int64, Int64) -> Void) throws {
        guard let sourceHandle = FileHandle(forReadingAtPath: source.path),
              let destHandle = FileHandle(forReadingAtPath: destination.path) else {
            throw CloneError.sourceUnreadable(source.path)
        }
        defer { try? sourceHandle.close(); try? destHandle.close() }

        let total = Self.size(of: source)
        var offset: Int64 = 0
        progress(0, total)

        while true {
            if isCancelled { throw CloneError.cancelled }
            let a = try Self.readFully(sourceHandle, upTo: blockSize)
            let b = try Self.readFully(destHandle, upTo: blockSize)
            if a.isEmpty && b.isEmpty { break }
            if a != b { throw CloneError.verifyMismatch(offset: offset) }
            offset += Int64(a.count)
            progress(offset, total)
        }
    }

    // MARK: - Helpers

    /// Reads up to `count` bytes, looping until the requested amount is available
    /// or EOF is reached. Raw devices frequently return short reads, which would
    /// otherwise desynchronise block-aligned comparisons.
    static func readFully(_ handle: FileHandle, upTo count: Int) throws -> Data {
        var out = Data()
        while out.count < count {
            let chunk = try handle.read(upToCount: count - out.count) ?? Data()
            if chunk.isEmpty { break }
            out.append(chunk)
        }
        return out
    }

    /// Byte size of a path, or 0 when it cannot be determined.
    static func size(of url: URL) -> Int64 {
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize, size > 0 {
            return Int64(size)
        }
        // Fall back to lseek (covers raw devices that report no size via stat).
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        let end = lseek(fd, 0, SEEK_END)
        _ = lseek(fd, 0, SEEK_SET)
        return end > 0 ? Int64(end) : 0
    }
}