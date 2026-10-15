import Foundation

enum DocumentError: LocalizedError {
    case readOnly
    case cannotOpen

    var errorDescription: String? {
        switch self {
        case .readOnly:   return "This source (raw device) is read-only."
        case .cannotOpen: return "Unable to open the file."
        }
    }
}

/// Backing store for an opened file.
///
/// The original file is memory-mapped (`mappedIfSafe`) so multi-GB images can be
/// viewed without loading them fully into RAM. The current content is modelled as
/// an ordered list of *chunks*, each either a slice of the mapped original or an
/// inserted byte array:
///
///   [ original(0, 1000) ][ bytes(41 42 43) ][ original(1000, 500) ]
///
/// Overwrite, insert and delete are all expressed as "replace a range with a list
/// of chunks", which keeps memory flat (only edited regions are materialised) and
/// supports a single undo model for every operation.
final class HexDocument {

    enum Chunk {
        case original(offset: Int, count: Int)
        case bytes([UInt8])

        var length: Int {
            switch self {
            case .original(_, let count): return count
            case .bytes(let b):           return b.count
            }
        }
    }

    struct Edit {
        let offset: Int
        let removed: [Chunk]
        let inserted: [Chunk]

        var removedLength: Int { removed.reduce(0) { $0 + $1.length } }
        var insertedLength: Int { inserted.reduce(0) { $0 + $1.length } }
    }

    private(set) var url: URL?
    private(set) var isReadOnly = false
    private(set) var isDirty = false
    private(set) var size = 0

    private var original = Data()
    private var chunks: [Chunk] = []
    /// Cached start offset of every chunk (prefix sums); rebuilt on structural change.
    private var chunkStarts: [Int] = []

    private var undoStack: [Edit] = []
    private var redoStack: [Edit] = []

    var fileName: String { url?.lastPathComponent ?? "Untitled" }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// Total number of bytes that no longer come straight from the original file.
    var editedByteCount: Int {
        chunks.reduce(0) { partial, chunk in
            if case .bytes(let b) = chunk { return partial + b.count }
            return partial
        }
    }

    // MARK: - Loading

    func load(url: URL?) {
        chunks.removeAll()
        chunkStarts.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        isDirty = false

        guard let url else {
            self.url = nil
            isReadOnly = false
            original = Data()
            size = 0
            return
        }

        self.url = url
        isReadOnly = url.path.hasPrefix("/dev/")

        let fm = FileManager.default
        if let mapped = try? Data(contentsOf: url, options: .mappedIfSafe) {
            original = mapped
        } else if !isReadOnly,
                  let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let fileSize = attrs[.size] as? Int, fileSize <= 512 << 20,
                  let plain = try? Data(contentsOf: url) {
            // Only regular files up to ~512 MB may fall back to a full read; a raw
            // device (or an oversized file) must never be slurped into memory.
            original = plain
        } else {
            original = Data()
        }

        if original.count > 0 {
            chunks = [.original(offset: 0, count: original.count)]
        }
        rebuildIndex()
    }

    func reload() {
        load(url: url)
    }

    // MARK: - Reading

    func byte(at offset: Int) -> UInt8 {
        guard offset >= 0, offset < size else { return 0 }
        let (index, inner) = locate(offset)
        switch chunks[index] {
        case .original(let base, _):
            return original.withUnsafeBytes { $0[base + inner] }
        case .bytes(let b):
            return b[inner]
        }
    }

    func bytes(in range: Range<Int>) -> [UInt8] {
        let lo = max(0, range.lowerBound)
        let hi = min(size, range.upperBound)
        guard lo < hi else { return [] }

        var out: [UInt8] = []
        out.reserveCapacity(hi - lo)
        var offset = lo
        while offset < hi {
            let (index, inner) = locate(offset)
            let chunk = chunks[index]
            let take = min(chunk.length - inner, hi - offset)
            switch chunk {
            case .original(let base, _):
                let start = original.startIndex + base + inner
                out.append(contentsOf: original[start..<(start + take)])
            case .bytes(let b):
                out.append(contentsOf: b[inner..<(inner + take)])
            }
            offset += take
        }
        return out
    }

    func contains(offset: Int) -> Bool { offset >= 0 && offset < size }

    // MARK: - Editing

    /// Overwrites bytes starting at `offset` (does not change the length).
    func overwrite(_ values: [UInt8], at offset: Int) {
        guard !isReadOnly, offset >= 0, offset < size, !values.isEmpty else { return }
        let count = min(values.count, size - offset)
        guard count > 0 else { return }
        replace(range: offset..<(offset + count),
                with: [.bytes(Array(values[0..<count]))],
                recordUndo: true)
    }

    func setByte(_ value: UInt8, at offset: Int) {
        overwrite([value], at: offset)
    }

    /// Replaces a range with new bytes, changing the length as needed.
    /// Used by transforms that produce a different number of bytes (Base64,
    /// AES/DES padding, …). Recorded on the undo stack as a single edit.
    func replace(range: Range<Int>, with values: [UInt8]) {
        guard !isReadOnly else { return }
        let lo = max(0, range.lowerBound)
        let hi = min(size, range.upperBound)
        guard lo <= hi else { return }
        let newChunks: [Chunk] = values.isEmpty ? [] : [.bytes(values)]
        replace(range: lo..<hi, with: newChunks, recordUndo: true)
    }

    func overwrite(repeating value: UInt8, range: Range<Int>) {
        guard !isReadOnly else { return }
        let lo = max(0, range.lowerBound)
        let hi = min(size, range.upperBound)
        guard lo < hi else { return }
        replace(range: lo..<hi,
                with: [.bytes([UInt8](repeating: value, count: hi - lo))],
                recordUndo: true)
    }

    /// Inserts bytes at `offset`, growing the content.
    func insert(_ values: [UInt8], at offset: Int) {
        guard !isReadOnly, !values.isEmpty else { return }
        let position = max(0, min(offset, size))
        replace(range: position..<position,
                with: [.bytes(values)],
                recordUndo: true)
    }

    /// Deletes the given range, shrinking the content.
    func delete(range: Range<Int>) {
        guard !isReadOnly else { return }
        let lo = max(0, range.lowerBound)
        let hi = min(size, range.upperBound)
        guard lo < hi else { return }
        replace(range: lo..<hi, with: [], recordUndo: true)
    }

    func undo() {
        guard let edit = undoStack.popLast() else { return }
        replace(range: edit.offset..<(edit.offset + edit.insertedLength),
                with: edit.removed,
                recordUndo: false)
        redoStack.append(edit)
        isDirty = !undoStack.isEmpty
    }

    func redo() {
        guard let edit = redoStack.popLast() else { return }
        replace(range: edit.offset..<(edit.offset + edit.removedLength),
                with: edit.inserted,
                recordUndo: false)
        undoStack.append(edit)
        isDirty = !undoStack.isEmpty
    }

    // MARK: - Core replacement

    private func replace(range: Range<Int>, with newChunks: [Chunk], recordUndo: Bool) {
        guard !isReadOnly else { return }
        let lo = max(0, range.lowerBound)
        let hi = min(size, range.upperBound)
        guard lo <= hi else { return }
        guard lo < hi || !newChunks.isEmpty else { return }

        let removed = chunkSlices(in: lo..<hi)

        var rebuilt: [Chunk] = []

        // Everything strictly before the affected region.
        if lo < size {
            let (firstIndex, innerOffset) = locate(lo)
            if firstIndex > 0 { rebuilt.append(contentsOf: chunks[0..<firstIndex]) }
            if innerOffset > 0 {
                rebuilt.append(slice(chunk: chunks[firstIndex], from: 0, length: innerOffset))
            }
        } else {
            rebuilt.append(contentsOf: chunks)
        }

        rebuilt.append(contentsOf: newChunks)

        // Everything strictly after the affected region.
        if hi < size {
            let (lastIndex, innerOffset) = locate(hi)
            let tailLength = chunks[lastIndex].length - innerOffset
            if tailLength > 0 {
                rebuilt.append(slice(chunk: chunks[lastIndex], from: innerOffset, length: tailLength))
            }
        }

        chunks = coalesce(rebuilt)
        rebuildIndex()
        isDirty = true

        if recordUndo {
            undoStack.append(Edit(offset: lo, removed: removed, inserted: newChunks))
            redoStack.removeAll()
        }
    }

    /// Returns the chunk pieces covering `range`, suitable for undo storage.
    private func chunkSlices(in range: Range<Int>) -> [Chunk] {
        guard range.lowerBound < range.upperBound else { return [] }
        var result: [Chunk] = []
        var offset = range.lowerBound
        while offset < range.upperBound {
            let (index, inner) = locate(offset)
            let take = min(chunks[index].length - inner, range.upperBound - offset)
            result.append(slice(chunk: chunks[index], from: inner, length: take))
            offset += take
        }
        return result
    }

    private func slice(chunk: Chunk, from start: Int, length: Int) -> Chunk {
        switch chunk {
        case .original(let base, _):
            return .original(offset: base + start, count: length)
        case .bytes(let b):
            let lo = b.startIndex + start
            return .bytes(Array(b[lo..<(lo + length)]))
        }
    }

    /// Merges adjacent chunks of the same kind to keep the list short.
    private func coalesce(_ list: [Chunk]) -> [Chunk] {
        var out: [Chunk] = []
        for chunk in list where chunk.length > 0 {
            if let last = out.last {
                switch (last, chunk) {
                case (.bytes(let a), .bytes(let b)):
                    out[out.count - 1] = .bytes(a + b)
                    continue
                case (.original(let o1, let n1), .original(let o2, _)):
                    if o1 + n1 == o2 {
                        out[out.count - 1] = .original(offset: o1, count: n1 + chunk.length)
                        continue
                    }
                default:
                    break
                }
            }
            out.append(chunk)
        }
        return out
    }

    private func rebuildIndex() {
        chunkStarts = []
        chunkStarts.reserveCapacity(chunks.count)
        var position = 0
        for chunk in chunks {
            chunkStarts.append(position)
            position += chunk.length
        }
        size = position
    }

    /// Maps a global offset to (chunk index, offset inside that chunk).
    private func locate(_ offset: Int) -> (Int, Int) {
        guard !chunks.isEmpty else { return (0, 0) }
        var low = 0
        var high = chunks.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if chunkStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return (low, offset - chunkStarts[low])
    }

    // MARK: - Saving

    func save(to destination: URL) throws {
        if isReadOnly && destination == url {
            throw DocumentError.readOnly
        }
        let fm = FileManager.default

        // Write to a sibling temp file first. The original may be memory-mapped,
        // so it must not be truncated in place.
        let directory = destination.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".hexforge-\(UUID().uuidString).tmp")
        fm.createFile(atPath: temp.path, contents: nil)

        var succeeded = false
        defer {
            if !succeeded { try? fm.removeItem(at: temp) }
        }

        let handle = try FileHandle(forWritingTo: temp)
        defer { try? handle.close() }

        let chunkSize = 1 << 20
        for chunk in chunks {
            switch chunk {
            case .original(let base, let count):
                var written = 0
                while written < count {
                    let take = min(chunkSize, count - written)
                    let start = original.startIndex + base + written
                    try handle.write(contentsOf: original[start..<(start + take)])
                    written += take
                }
            case .bytes(let b):
                try handle.write(contentsOf: Data(b))
            }
        }
        try handle.synchronize()
        try handle.close()

        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: destination)
        }
        succeeded = true

        load(url: destination)
    }
}