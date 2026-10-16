import Foundation
import Darwin

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

/// Carries the technical reason a raw device could not be opened; the UI wraps
/// it in a localized message.
struct DeviceLoadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Content backings

/// Read access to the document's unedited bytes. Indirection is what lets a
/// multi-GB raw disk be browsed without ever loading it all into memory.
private protocol ContentBacking: AnyObject {
    var count: Int { get }
    func byte(at offset: Int) -> UInt8
    func read(_ range: Range<Int>) -> [UInt8]
}

/// Ordinary files: a Data blob (usually memory-mapped via `.mappedIfSafe`).
private final class DataBacking: ContentBacking {
    let data: Data

    init(_ data: Data) { self.data = data }

    var count: Int { data.count }

    func byte(at offset: Int) -> UInt8 {
        guard offset >= 0, offset < data.count else { return 0 }
        return data[offset]
    }

    func read(_ range: Range<Int>) -> [UInt8] {
        let lo = max(0, range.lowerBound)
        let hi = min(data.count, range.upperBound)
        guard lo < hi else { return [] }
        return [UInt8](data[lo..<hi])
    }
}

/// Read-only aligned access to a raw device node.
///
/// `/dev/rdisk*` is a character device: the raw node rejects unaligned I/O,
/// and macOS does not implement `mmap` for it (ENODEV). Every read here is a
/// sector-aligned `pread` into an aligned buffer, with a tiny bounce handling
/// the unaligned head/tail, so the same code works on the buffered
/// `/dev/disk*` node as well.
final class DeviceIO {
    let fd: Int32
    let path: String
    let sectorSize: Int
    /// Media length in bytes; 0 when neither the hint nor the ioctl gave one.
    let mediaLength: Int

    // DKIOCGETBLOCKSIZE  = _IOR('d', 4,  UInt32)
    // DKIOCGETBLOCKCOUNT = _IOR('d', 25, UInt64)
    private static let ioctlBlockSize: UInt = 0x40046404
    private static let ioctlBlockCount: UInt = 0x40086419

    private init(fd: Int32, path: String, sectorSize: Int, mediaLength: Int) {
        self.fd = fd
        self.path = path
        self.sectorSize = sectorSize
        self.mediaLength = mediaLength
    }

    /// Opens `path` read-only. Returns nil (errno preserved) on failure.
    /// `hintedLength` (from DiskArbitration) is preferred; the block-count
    /// ioctl is only consulted when it is missing.
    static func open(path: String, hintedLength: Int) -> DeviceIO? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }

        var blockSize: UInt32 = 512
        if ioctl(fd, ioctlBlockSize, &blockSize) != 0 || blockSize == 0 {
            blockSize = 512
        }
        let sectors = Int(blockSize)

        var length = hintedLength
        if length <= 0 {
            var blocks: UInt64 = 0
            if ioctl(fd, ioctlBlockCount, &blocks) == 0, blocks > 0 {
                length = Int(blocks) * sectors
            }
        }
        return DeviceIO(fd: fd, path: path, sectorSize: sectors, mediaLength: length)
    }

    deinit { close(fd) }

    /// Reads an arbitrary range (any alignment). A short read at media end
    /// returns just the available bytes.
    func read(offset: Int, count: Int) -> [UInt8]? {
        guard count > 0 else { return [] }
        let s = sectorSize
        let alignedStart = (offset / s) * s
        let requestedEnd = offset + count
        var alignedEnd = ((requestedEnd + s - 1) / s) * s
        if mediaLength > 0 { alignedEnd = min(alignedEnd, mediaLength) }

        guard alignedEnd > alignedStart,
              let aligned = alignedRead(offset: alignedStart, count: alignedEnd - alignedStart) else {
            return nil
        }
        if alignedStart == offset && alignedEnd == requestedEnd { return aligned }
        let inner = offset - alignedStart
        let take = min(count, aligned.count - inner)
        guard take > 0 else { return [] }
        return Array(aligned[inner..<(inner + take)])
    }

    /// Sector-aligned read into a page-aligned buffer (required by raw nodes).
    private func alignedRead(offset: Int, count: Int) -> [UInt8]? {
        var raw: UnsafeMutableRawPointer?
        guard posix_memalign(&raw, 4096, count) == 0, let dest = raw else { return nil }
        defer { free(dest) }

        var done = 0
        while done < count {
            let n = pread(fd, dest.advanced(by: done), count - done, off_t(offset + done))
            if n > 0 {
                done += n
            } else if n == 0 {
                break // end of media
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return Array(UnsafeMutableRawBufferPointer(start: dest, count: done))
    }
}

/// Memory-mapped device. Media length is not necessarily a multiple of the CPU
/// page size, so the trailing partial page (if any) is served by `pread`.
private final class MappedDeviceBacking: ContentBacking {
    let count: Int
    private let mapped: Data
    private let io: DeviceIO

    private var mappedCount: Int { mapped.count }

    init(mapped: Data, io: DeviceIO, count: Int) {
        self.mapped = mapped
        self.io = io
        self.count = count
    }

    func byte(at offset: Int) -> UInt8 {
        guard offset >= 0, offset < count else { return 0 }
        if offset < mappedCount { return mapped[offset] }
        return io.read(offset: offset, count: 1)?.first ?? 0
    }

    func read(_ range: Range<Int>) -> [UInt8] {
        let lo = max(0, range.lowerBound)
        let hi = min(count, range.upperBound)
        guard lo < hi else { return [] }

        var out = [UInt8](repeating: 0, count: hi - lo)
        let mappedEnd = min(hi, mappedCount)
        if lo < mappedEnd {
            out.replaceSubrange(0..<(mappedEnd - lo), with: mapped[lo..<mappedEnd])
        }
        let tailStart = max(lo, mappedCount)
        if hi > tailStart, let tail = io.read(offset: tailStart, count: hi - tailStart) {
            let outStart = tailStart - lo
            out.replaceSubrange(outStart..<(outStart + tail.count), with: tail)
        }
        return out
    }
}

/// On-demand device reader backed by a bounded LRU window (32 × 1 MiB). The
/// whole disk is never held in memory; large (multi-block) reads stream
/// straight from the device so FAT/bitmap scans do not evict the window.
private final class RawDeviceBacking: ContentBacking {
    let count: Int

    private let io: DeviceIO
    private let blockSize = 1 << 20
    private let maxCachedBlocks = 32
    private let streamChunkSize = 4 << 20
    private var blocks: [Int: Data] = [:]
    private var lru: [Int] = []
    private let lock = NSLock()

    init(io: DeviceIO, count: Int) {
        self.io = io
        self.count = count
    }

    func byte(at offset: Int) -> UInt8 {
        guard offset >= 0, offset < count else { return 0 }
        return read(offset..<(offset + 1)).first ?? 0
    }

    func read(_ range: Range<Int>) -> [UInt8] {
        let lo = max(0, range.lowerBound)
        let hi = min(count, range.upperBound)
        guard lo < hi else { return [] }
        return (hi - lo) >= blockSize ? stream(lo, hi) : windowed(lo, hi)
    }

    private func stream(_ lo: Int, _ hi: Int) -> [UInt8] {
        let total = hi - lo
        var out = [UInt8](repeating: 0, count: total)
        var done = 0
        while done < total {
            let chunk = min(streamChunkSize, total - done)
            guard let part = io.read(offset: lo + done, count: chunk) else { break }
            if part.isEmpty { break }
            out.replaceSubrange(done..<(done + part.count), with: part)
            done += part.count
            if part.count < chunk { break }
        }
        return out
    }

    private func windowed(_ lo: Int, _ hi: Int) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }

        var out = [UInt8](repeating: 0, count: hi - lo)
        var pos = lo
        while pos < hi {
            let index = pos / blockSize
            let blockStart = index * blockSize
            guard let block = cachedBlock(index) else { break }
            let inner = pos - blockStart
            let available = block.count - inner
            guard available > 0 else { break }
            let take = min(available, hi - pos)
            out.replaceSubrange((pos - lo)..<(pos - lo + take),
                                with: block[inner..<(inner + take)])
            pos += take
        }
        return out
    }

    private func cachedBlock(_ index: Int) -> Data? {
        if let existing = blocks[index] {
            touch(index)
            return existing
        }
        let blockStart = index * blockSize
        guard let loaded = io.read(offset: blockStart,
                                   count: min(blockSize, count - blockStart)) else {
            return nil
        }
        let block = Data(loaded)
        blocks[index] = block
        lru.append(index)
        while lru.count > maxCachedBlocks {
            let oldest = lru.removeFirst()
            if oldest != index { blocks.removeValue(forKey: oldest) }
        }
        return block
    }

    private func touch(_ index: Int) {
        guard let position = lru.firstIndex(of: index) else { return }
        lru.remove(at: position)
        lru.append(index)
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

    private var backing: ContentBacking = DataBacking(Data())
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
            backing = DataBacking(Data())
            size = 0
            return
        }

        self.url = url
        isReadOnly = url.path.hasPrefix("/dev/")

        let fm = FileManager.default
        let data: Data
        if let mapped = try? Data(contentsOf: url, options: .mappedIfSafe) {
            data = mapped
        } else if !isReadOnly,
                  let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let fileSize = attrs[.size] as? Int, fileSize <= 512 << 20,
                  let plain = try? Data(contentsOf: url) {
            // Only regular files up to ~512 MB may fall back to a full read; a raw
            // device (or an oversized file) must never be slurped into memory.
            data = plain
        } else {
            data = Data()
        }

        backing = DataBacking(data)
        if data.count > 0 {
            chunks = [.original(offset: 0, count: data.count)]
        }
        rebuildIndex()
    }

    func reload() {
        load(url: url)
    }

    /// Opens a raw device, read-only, without ever loading it all into memory.
    ///
    /// Strategy:
    /// 1. `mmap` the raw `/dev/rdisk*` node (works on systems whose character
    ///    device implements mapping).
    /// 2. `mmap` the buffered `/dev/disk*` block node (raw node often returns
    ///    ENODEV while the block node maps).
    /// 3. Windowed, sector-aligned `pread` with a bounded LRU cache — always
    ///    works, memory stays flat for TB-class media.
    func loadDevice(url: URL, length: Int64) throws {
        resetForLoad()

        let rawPath = url.path
        var candidates = [rawPath]
        if rawPath.hasPrefix("/dev/r") {
            candidates.append("/dev/" + String(rawPath.dropFirst("/dev/r".count)))
        }

        let hinted = Int(length)
        var primary: DeviceIO?
        var reasons: [String] = []
        for path in candidates {
            if let io = DeviceIO.open(path: path, hintedLength: hinted) {
                primary = io
                break
            }
            reasons.append("\(path): \(String(cString: strerror(errno))) (\(errno))")
        }

        guard let io = primary else {
            throw DeviceLoadError(message: reasons.joined(separator: "\n"))
        }
        guard io.mediaLength > 0 else {
            throw DeviceLoadError(message: "Unknown device size (DAMediaSize and block-count ioctl both returned 0).")
        }
        let count = io.mediaLength

        // Tier 1/2: explicit mapping, whole pages only. The tail past the last
        // mapped page is served with pread by MappedDeviceBacking.
        let pageSize = max(1, sysconf(_SC_PAGESIZE))
        let mappedLength = (count / pageSize) * pageSize
        if mappedLength > 0 {
            if let data = mapDevice(io.fd, length: mappedLength) {
                backing = MappedDeviceBacking(mapped: data, io: io, count: count)
                finalizeDeviceLoad(url: url, count: count)
                return
            }
            for path in candidates where path != io.path {
                if let second = DeviceIO.open(path: path, hintedLength: count),
                   let data = mapDevice(second.fd, length: mappedLength) {
                    backing = MappedDeviceBacking(mapped: data, io: second, count: count)
                    finalizeDeviceLoad(url: url, count: count)
                    return
                }
            }
        }

        // Tier 3: on-demand aligned pread with a bounded window.
        backing = RawDeviceBacking(io: io, count: count)
        finalizeDeviceLoad(url: url, count: count)
    }

    private func resetForLoad() {
        backing = DataBacking(Data())
        chunks.removeAll()
        chunkStarts.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        isDirty = false
        url = nil
        isReadOnly = false
        rebuildIndex()
    }

    private func finalizeDeviceLoad(url: URL, count: Int) {
        self.url = url
        isReadOnly = true
        chunks = [.original(offset: 0, count: count)]
        rebuildIndex()
    }

    private func mapDevice(_ fd: Int32, length: Int) -> Data? {
        let mapped = mmap(nil, length, PROT_READ, MAP_PRIVATE, fd, 0)
        guard let base = mapped, Int(bitPattern: UnsafeRawPointer(base)) != -1 else { return nil }
        return Data(bytesNoCopy: base, count: length, deallocator: .custom { pointer, size in
            munmap(pointer, size)
        })
    }

    // MARK: - Reading

    func byte(at offset: Int) -> UInt8 {
        guard offset >= 0, offset < size else { return 0 }
        let (index, inner) = locate(offset)
        switch chunks[index] {
        case .original(let base, _):
            return backing.byte(at: base + inner)
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
                let start = base + inner
                out.append(contentsOf: backing.read(start..<(start + take)))
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
                    let start = base + written
                    try handle.write(contentsOf: backing.read(start..<(start + take)))
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