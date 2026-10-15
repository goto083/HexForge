import Foundation

/// Creates and verifies disk images. An image is one or more raw volume files
/// (`name.img`, `name.002.img`, …) plus a JSON manifest (`name.hfmeta.json`)
/// that records per-block CRC-32 checksums so an image can be verified later.
///
/// When compression is enabled the image becomes a single volume holding a
/// length-prefixed LZFSE frame container (magic `HFIMGC1`); splitting is not
/// supported in that mode.
enum DiskImager {

    struct Options {
        /// Read size. Rounded down to a 512-byte boundary, minimum 512.
        var blockSize: Int = 1 << 20
        /// Maximum bytes per volume file; 0 = a single volume. Ignored when
        /// `compress` is true.
        var splitSize: Int64 = 0
        var compress = false
        /// Re-read the image afterwards and compare against the manifest.
        var verify = false
        /// Record a CRC-32 for every block in the manifest.
        var checksum = true
    }

    struct VolumeInfo: Codable {
        let name: String
        let size: Int64
    }

    struct Manifest: Codable {
        let version: Int
        let source: String
        let sourceSize: Int64
        let blockSize: Int
        let compressed: Bool
        let createdAt: Date
        let volumes: [VolumeInfo]
        /// One CRC-32 (8 hex digits) per block, in order; nil when not recorded.
        let blockChecksums: [String]?
    }

    struct VerifyReport {
        let blocksChecked: Int
        let mismatches: Int
        let firstMismatchOffset: Int64?
        /// False when the manifest carried no checksums (nothing to compare).
        let hadChecksums: Bool
    }

    enum ImageError: LocalizedError {
        case sourceUnreadable(String)
        case destinationUnwritable(String)
        case cancelled
        case compressionFailed
        case verifyMismatch(offset: Int64)
        case manifestUnreadable(String)

        var errorDescription: String? {
            switch self {
            case .sourceUnreadable(let path):      return L.f("Cannot read source: %@", path)
            case .destinationUnwritable(let path): return L.f("Cannot write: %@", path)
            case .cancelled:                       return L.t("Imaging cancelled.")
            case .compressionFailed:               return L.t("Compression failed.")
            case .verifyMismatch(let offset):
                return L.f("Verification failed at offset 0x%@.", String(offset, radix: 16).uppercased())
            case .manifestUnreadable(let path):    return L.f("Cannot read manifest: %@", path)
            }
        }
    }

    /// Cancellation token shared with the caller.
    final class Job {
        private let lock = NSLock()
        private var stopped = false
        func cancel() { lock.lock(); stopped = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    }

    static let containerMagic: [UInt8] = Array("HFIMGC1".utf8)
    /// Uncompressed bytes per compressed frame.
    static let frameBytes = 4 << 20

    // MARK: - Create

    @discardableResult
    static func createImage(from source: URL,
                            to folder: URL,
                            name: String,
                            options: Options,
                            job: Job = Job(),
                            progress: (Int64, Int64) -> Void) throws -> (manifest: Manifest, manifestURL: URL) {

        guard let sourceHandle = FileHandle(forReadingAtPath: source.path) else {
            throw ImageError.sourceUnreadable(source.path)
        }
        defer { try? sourceHandle.close() }

        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let baseName = sanitized(name.isEmpty ? source.deletingPathExtension().lastPathComponent : name)
        let block = max(512, options.blockSize & ~511)
        let compress = options.compress
        let splitSize = compress ? 0 : max(0, options.splitSize)
        let total = DiskCloner.size(of: source)

        var volumes: [VolumeInfo] = []
        var checksums: [String] = []
        var done: Int64 = 0
        progress(0, total)

        // One checksum per *fixed-size* block, matching the verify pass which
        // slices the stream at `block` boundaries. Raw reads may be short (common
        // on devices), so accumulate into `block`-sized chunks before hashing.
        var checksumBuf: [UInt8] = []
        checksumBuf.reserveCapacity(block)
        func accumulateChecksum(_ data: Data) {
            guard options.checksum else { return }
            checksumBuf.append(contentsOf: data)
            var i = 0
            while checksumBuf.count - i >= block {
                checksums.append(crc32Hex(Array(checksumBuf[i..<(i + block)])))
                i += block
            }
            if i > 0 { checksumBuf.removeFirst(i) }
        }
        func flushChecksum() {
            guard options.checksum, !checksumBuf.isEmpty else { return }
            checksums.append(crc32Hex(checksumBuf))
            checksumBuf.removeAll(keepingCapacity: true)
        }

        if compress {
            let outputName = "\(baseName).img"
            let url = folder.appendingPathComponent(outputName)
            if !fm.fileExists(atPath: url.path) { _ = fm.createFile(atPath: url.path, contents: nil) }
            guard let out = FileHandle(forWritingAtPath: url.path) else {
                throw ImageError.destinationUnwritable(url.path)
            }
            do {
                try out.truncate(atOffset: 0)
                try out.write(contentsOf: Data(containerMagic))
                var frame: [UInt8] = []
                frame.reserveCapacity(frameBytes)
                while true {
                    if job.isCancelled { throw ImageError.cancelled }
                    let data = try sourceHandle.read(upToCount: block) ?? Data()
                    if data.isEmpty { break }
                    accumulateChecksum(data)
                    frame.append(contentsOf: data)
                    if frame.count >= frameBytes {
                        try writeFrame(Data(frame), to: out)
                        frame.removeAll(keepingCapacity: true)
                    }
                    done += Int64(data.count)
                    progress(done, total)
                }
                if !frame.isEmpty { try writeFrame(Data(frame), to: out) }
                flushChecksum()
                try out.synchronize()
                try out.close()
                volumes.append(VolumeInfo(name: outputName, size: fileSize(url)))
            } catch {
                try? out.close()
                throw error
            }
        } else {
            var handle: FileHandle?
            var currentName = ""
            var currentSize: Int64 = 0
            var index = 0

            func openVolume() throws {
                try handle?.close()
                index += 1
                currentName = volumeName(base: baseName, index: index)
                let url = folder.appendingPathComponent(currentName)
                if !fm.fileExists(atPath: url.path) { _ = fm.createFile(atPath: url.path, contents: nil) }
                guard let h = FileHandle(forWritingAtPath: url.path) else {
                    throw ImageError.destinationUnwritable(url.path)
                }
                try? h.truncate(atOffset: 0)
                handle = h
                currentSize = 0
            }
            func closeVolume() throws {
                guard let h = handle else { return }
                try h.synchronize()
                try h.close()
                volumes.append(VolumeInfo(name: currentName, size: currentSize))
                handle = nil
            }

            do {
                try openVolume()
                while true {
                    if job.isCancelled { throw ImageError.cancelled }
                    let data = try sourceHandle.read(upToCount: block) ?? Data()
                    if data.isEmpty { break }
                    if splitSize > 0, currentSize > 0, currentSize + Int64(data.count) > splitSize {
                        try closeVolume()
                        try openVolume()
                    }
                    try handle?.write(contentsOf: data)
                    currentSize += Int64(data.count)
                    accumulateChecksum(data)
                    done += Int64(data.count)
                    progress(done, total)
                }
                flushChecksum()
                try closeVolume()
            } catch {
                try? handle?.close()
                throw error
            }
        }

        let manifest = Manifest(version: 1,
                                source: source.path,
                                sourceSize: done,
                                blockSize: block,
                                compressed: compress,
                                createdAt: Date(),
                                volumes: volumes,
                                blockChecksums: options.checksum ? checksums : nil)
        let manifestURL = folder.appendingPathComponent("\(baseName).hfmeta.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL)

        if options.verify {
            let report = try verifyImage(manifestURL: manifestURL, job: job, progress: progress)
            if report.mismatches > 0 {
                throw ImageError.verifyMismatch(offset: report.firstMismatchOffset ?? 0)
            }
        }
        return (manifest, manifestURL)
    }

    // MARK: - Verify

    @discardableResult
    static func verifyImage(manifestURL: URL,
                            job: Job = Job(),
                            progress: (Int64, Int64) -> Void) throws -> VerifyReport {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            throw ImageError.manifestUnreadable(manifestURL.path)
        }
        let folder = manifestURL.deletingLastPathComponent()
        let block = max(1, manifest.blockSize)
        let total = manifest.sourceSize

        var mismatches = 0
        var firstMismatch: Int64?
        var index = 0
        var done: Int64 = 0
        progress(0, total)

        var carry: [UInt8] = []
        var carryIndex = 0

        func consume(_ bytes: [UInt8]) {
            let blockStart = done
            if let expected = manifest.blockChecksums {
                if index < expected.count {
                    if crc32Hex(bytes) != expected[index] {
                        mismatches += 1
                        if firstMismatch == nil { firstMismatch = blockStart }
                    }
                } else {
                    // More data blocks than recorded checksums — treat as a mismatch
                    // rather than silently skipping the extra blocks.
                    mismatches += 1
                    if firstMismatch == nil { firstMismatch = blockStart }
                }
            }
            index += 1
            done += Int64(bytes.count)
            progress(done, total)
        }

        func feed(_ chunk: [UInt8]) {
            carry.append(contentsOf: chunk)
            while carry.count - carryIndex >= block {
                consume(Array(carry[carryIndex..<(carryIndex + block)]))
                carryIndex += block
            }
            if carryIndex == carry.count {
                carry.removeAll(keepingCapacity: true)
                carryIndex = 0
            } else if carryIndex >= 1 << 20 {
                carry.removeFirst(carryIndex)
                carryIndex = 0
            }
        }

        if manifest.compressed {
            guard let first = manifest.volumes.first else {
                throw ImageError.manifestUnreadable(manifestURL.path)
            }
            let url = folder.appendingPathComponent(first.name)
            guard let handle = FileHandle(forReadingAtPath: url.path) else {
                throw ImageError.manifestUnreadable(url.path)
            }
            defer { try? handle.close() }
            let magic = try handle.read(upToCount: containerMagic.count)
            guard magic == Data(containerMagic) else {
                throw ImageError.manifestUnreadable(url.path)
            }
            while true {
                if job.isCancelled { throw ImageError.cancelled }
                guard let lenData = try handle.read(upToCount: 4), lenData.count == 4 else { break }
                guard let rawLenData = try handle.read(upToCount: 4), rawLenData.count == 4 else { break }
                let compLen = Int(readU32(lenData))
                let rawLen = Int(readU32(rawLenData))
                guard let comp = try handle.read(upToCount: compLen), comp.count == compLen else {
                    throw ImageError.compressionFailed
                }
                let rawNS = try (comp as NSData).decompressed(using: .lzfse)
                guard rawNS.length == rawLen else { throw ImageError.compressionFailed }
                feed([UInt8](rawNS as Data))
            }
        } else {
            let reader = try MultiVolumeReader(folder: folder, volumes: manifest.volumes)
            defer { reader.close() }
            while true {
                if job.isCancelled { throw ImageError.cancelled }
                let chunk = try reader.read(upTo: block)
                if chunk.isEmpty { break }
                feed([UInt8](chunk))
            }
        }

        if carryIndex < carry.count {
            let tail = Array(carry[carryIndex...])
            if !tail.isEmpty { consume(tail) }
        }

        return VerifyReport(blocksChecked: index,
                            mismatches: mismatches,
                            firstMismatchOffset: firstMismatch,
                            hadChecksums: manifest.blockChecksums != nil)
    }

    // MARK: - Helpers

    /// Reads the concatenation of several volume files as one stream.
    private final class MultiVolumeReader {
        private var handles: [FileHandle] = []
        private var current = 0

        init(folder: URL, volumes: [VolumeInfo]) throws {
            for volume in volumes {
                let url = folder.appendingPathComponent(volume.name)
                guard let handle = FileHandle(forReadingAtPath: url.path) else {
                    throw ImageError.manifestUnreadable(url.path)
                }
                handles.append(handle)
            }
        }

        func read(upTo count: Int) throws -> Data {
            var out = Data()
            while out.count < count, current < handles.count {
                let chunk = try handles[current].read(upToCount: count - out.count) ?? Data()
                if chunk.isEmpty {
                    current += 1
                } else {
                    out.append(chunk)
                }
            }
            return out
        }

        func close() { for handle in handles { try? handle.close() } }
    }

    private static func writeFrame(_ raw: Data, to handle: FileHandle) throws {
        let compressedNS = try (raw as NSData).compressed(using: .lzfse)
        let compressed = compressedNS as Data
        try handle.write(contentsOf: u32le(UInt32(compressed.count)))
        try handle.write(contentsOf: u32le(UInt32(raw.count)))
        try handle.write(contentsOf: compressed)
    }

    static func crc32Hex(_ bytes: [UInt8]) -> String {
        String(format: "%08X", CRC32.update(0xFFFF_FFFF, bytes) ^ 0xFFFF_FFFF)
    }

    static func sanitized(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty ? "image" : cleaned
    }

    static func volumeName(base: String, index: Int) -> String {
        index <= 1 ? "\(base).img" : String(format: "%@.%03d.img", base, index)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func u32le(_ value: UInt32) -> Data {
        var x = value.littleEndian
        return Data(bytes: &x, count: 4)
    }

    private static func readU32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0) }
        return UInt32(littleEndian: value)
    }
}