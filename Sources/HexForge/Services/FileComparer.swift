import Foundation

extension URL {
    /// Byte size of the file/device, or 0 when it cannot be determined.
    var byteSize: Int64 {
        if let values = try? resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize, size > 0 {
            return Int64(size)
        }
        // Fall back to lseek (covers raw devices that report no size via stat).
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        let end = lseek(fd, 0, SEEK_END)
        _ = lseek(fd, 0, SEEK_SET)
        return end > 0 ? Int64(end) : 0
    }
}

/// Compares the open document against another file/device, streaming in blocks
/// and grouping consecutive differing bytes into runs.
enum FileComparer {

    /// A run of consecutive bytes that differ between the two sides.
    struct Difference: Identifiable {
        let id = UUID()
        let offset: Int
        /// Full run length (may exceed the stored sample bytes).
        let length: Int
        /// Up to a small sample of bytes for display.
        let aBytes: [UInt8]
        let bBytes: [UInt8]

        var range: Range<Int> { offset..<(offset + length) }
    }

    struct Result {
        let aSize: Int
        let bSize: Int
        let differences: [Difference]
        let totalDifferenceRuns: Int
        let truncated: Bool

        /// Offsets (in the open document) that differ, capped at `limit` entries.
        func diffOffsetSet(limit: Int) -> Set<Int> {
            var set = Set<Int>()
            for difference in differences {
                for offset in difference.range {
                    if set.count >= limit { return set }
                    set.insert(offset)
                }
            }
            return set
        }

        func summaryText(openName: String, otherName: String) -> String {
            let sizeB = bSize > 0 ? "\(bSize)" : "?"
            var text = "\(openName) vs \(otherName)  ·  \(totalDifferenceRuns) difference run(s)  ·  \(aSize) / \(sizeB) bytes"
            if truncated { text += "  ·  list truncated" }
            return text
        }
    }

    enum CompareError: LocalizedError {
        case unreadable(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .unreadable(let path): return "Cannot read \(path)"
            case .cancelled:            return "Comparison cancelled."
            }
        }
    }

    /// - Parameter progress: called with `(bytesCompared, totalBytes)`; `totalBytes`
    ///   is 0 when the other file's size is unknown.
    static func compare(document: HexDocument,
                        against other: URL,
                        blockSize: Int = 1 << 20,
                        maxRuns: Int = 5000,
                        maxStoredBytes: Int = 32,
                        isCancelled: () -> Bool = { false },
                        progress: (Int, Int) -> Void = { _, _ in }) throws -> Result {

        let aSize = document.size
        let bSize = Int(min(Int64(Int.max), other.byteSize))
        let total = bSize > 0 ? max(aSize, bSize) : 0

        guard let handle = FileHandle(forReadingAtPath: other.path) else {
            throw CompareError.unreadable(other.path)
        }
        defer { try? handle.close() }

        var differences: [Difference] = []
        var totalRuns = 0
        var truncated = false
        var openOffset = -1
        var openLength = 0
        var openA: [UInt8] = []
        var openB: [UInt8] = []

        func beginRun(at offset: Int) {
            guard openOffset < 0 else { return }
            openOffset = offset
            openLength = 0
            openA = []
            openB = []
        }

        func appendByte(a: UInt8?, b: UInt8?) {
            openLength += 1
            if differences.count < maxRuns {
                if let a, openA.count < maxStoredBytes { openA.append(a) }
                if let b, openB.count < maxStoredBytes { openB.append(b) }
            }
        }

        func endRun() {
            guard openOffset >= 0 else { return }
            totalRuns += 1
            if differences.count < maxRuns {
                differences.append(Difference(offset: openOffset,
                                              length: openLength,
                                              aBytes: openA,
                                              bBytes: openB))
            } else {
                truncated = true
            }
            openOffset = -1
            openLength = 0
            openA = []
            openB = []
        }

        let block = max(4096, blockSize)
        var consumed = 0
        progress(0, total)

        while true {
            if isCancelled() { throw CompareError.cancelled }
            let chunk = try handle.read(upToCount: block) ?? Data()
            if chunk.isEmpty { break }
            let bArray = [UInt8](chunk)
            let remainingA = max(0, aSize - consumed)
            let common = min(bArray.count, remainingA)
            let aArray = common > 0 ? document.bytes(in: consumed..<(consumed + common)) : []

            for index in 0..<common {
                let a = index < aArray.count ? aArray[index] : 0
                let b = bArray[index]
                if a != b {
                    beginRun(at: consumed + index)
                    appendByte(a: a, b: b)
                } else {
                    endRun()
                }
            }

            // Bytes in the other file beyond the end of the open document.
            if bArray.count > common {
                beginRun(at: consumed + common)
                for index in common..<bArray.count {
                    appendByte(a: nil, b: bArray[index])
                }
            }

            consumed += bArray.count
            progress(consumed, total)
        }

        // Bytes in the open document beyond the end of the other file.
        if aSize > consumed {
            beginRun(at: consumed)
            let extra = aSize - consumed
            openLength += extra
            if differences.count < maxRuns, openA.count < maxStoredBytes {
                let take = min(maxStoredBytes - openA.count, extra)
                openA.append(contentsOf: document.bytes(in: consumed..<(consumed + take)))
            }
        }
        endRun()

        return Result(aSize: aSize,
                      bSize: bSize,
                      differences: differences,
                      totalDifferenceRuns: totalRuns,
                      truncated: truncated)
    }
}