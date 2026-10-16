import Foundation
import AppKit

/// One directory entry shown in the file system panel.
struct FSEntry: Identifiable {
    let id = UUID()
    let name: String
    let ext: String
    let isDirectory: Bool
    let isDeleted: Bool
    let size: UInt64
    let firstCluster: UInt32
    /// Absolute byte offset of the entry's data (first cluster).
    let dataOffset: Int
    /// Byte length used when revealing the entry in the hex view.
    let revealLength: Int
    /// Absolute offset of the entry (or exFAT entry set) inside its parent directory.
    let entryOffset: Int
    /// Bytes occupied by the directory record (32 on FAT32, set length on exFAT).
    let entryLength: Int
    let created: Date?
    let modified: Date?
    let accessed: Date?
    /// DOS attribute letters, e.g. "A" / "RHSA" (empty for directories).
    let attributes: String
}

/// Parsed boot-sector geometry, shared by FAT32 and exFAT.
struct FSVolumeInfo {
    enum Kind: String { case fat32 = "FAT32", exFAT = "exFAT" }
    let kind: Kind
    let bytesPerSector: Int
    let sectorsPerCluster: Int
    let fatStartSector: Int      // first FAT, in sectors
    let sectorsPerFAT: Int
    let fatCount: Int
    let heapStartSector: Int     // first data cluster, in sectors
    let rootCluster: UInt32
    let totalClusters: UInt32

    var clusterSize: Int { bytesPerSector * sectorsPerCluster }
    var fatOffset: Int { fatStartSector * bytesPerSector }
    var fatLength: Int { sectorsPerFAT * bytesPerSector }

    func clusterOffset(_ cluster: UInt32) -> Int {
        (heapStartSector + Int(cluster &- 2) * sectorsPerCluster) * bytesPerSector
    }
}

/// Reads directories from a FAT32 or exFAT volume inside a HexDocument.
/// All reads go through `HexDocument.bytes(in:)`, so mapped raw devices work.
struct FSVolume {
    let info: FSVolumeInfo
    let document: HexDocument
    /// Byte offset of the volume's boot sector: 0 for a bare file system,
    /// or the partition start when reached through an MBR partition table.
    let base: Int

    // MARK: - Detection

    /// Bare FAT32/exFAT at sector 0, or the first usable MBR partition.
    static func detect(_ document: HexDocument) -> FSVolume? {
        if let volume = detectVolume(document, base: 0) { return volume }
        guard document.size >= 512 else { return nil }
        let mbr = document.bytes(in: 0..<512)
        guard mbr[510] == 0x55, mbr[511] == 0xAA else { return nil }
        for index in 0..<4 {
            let e = 0x1BE + index * 16
            let type = mbr[e + 4]
            let startLBA = u32(mbr, e + 8)
            guard type != 0, type != 0xEE, startLBA > 0 else { continue }
            if let volume = detectVolume(document, base: Int(startLBA) * 512) { return volume }
        }
        return nil
    }

    private static func detectVolume(_ document: HexDocument, base: Int) -> FSVolume? {
        guard base >= 0, base + 512 <= document.size else { return nil }
        let boot = document.bytes(in: base..<(base + 512))

        // exFAT: OEM name field is "EXFAT   ".
        if String(bytes: boot[3..<11], encoding: .ascii) == "EXFAT   " {
            let bpsShift = Int(boot[0x6C]), spcShift = Int(boot[0x6D])
            guard (9...12).contains(bpsShift), spcShift <= 25 else { return nil }
            let info = FSVolumeInfo(
                kind: .exFAT,
                bytesPerSector: 1 << bpsShift,
                sectorsPerCluster: 1 << spcShift,
                fatStartSector: Int(u32(boot, 0x50)),
                sectorsPerFAT: Int(u32(boot, 0x54)),
                fatCount: Int(boot[0x6E]),
                heapStartSector: Int(u32(boot, 0x58)),
                rootCluster: u32(boot, 0x60),
                totalClusters: u32(boot, 0x5C))
            guard info.sectorsPerFAT > 0, info.heapStartSector > 0, info.rootCluster >= 2 else { return nil }
            return FSVolume(info: info, document: document, base: base)
        }

        // FAT32: sane BPB + non-zero FAT size + "FAT32   " label at 0x52.
        let bps = Int(u16(boot, 0x0B))
        let spc = Int(boot[0x0D])
        let reserved = Int(u16(boot, 0x0E))
        let fats = Int(boot[0x10])
        let fatSz = Int(u32(boot, 0x24))
        let rootClus = u32(boot, 0x2C)
        let label = String(bytes: boot[0x52..<0x5A], encoding: .ascii) ?? ""
        let totalSectors = Int(u32(boot, 0x28) != 0 ? u32(boot, 0x28) : UInt32(u16(boot, 0x20)))
        guard [512, 1024, 2048, 4096].contains(bps),
              spc > 0, reserved > 0, fats > 0, fatSz > 0, rootClus >= 2,
              label == "FAT32   " else { return nil }
        let heapStart = reserved + fats * fatSz
        let info = FSVolumeInfo(
            kind: .fat32,
            bytesPerSector: bps,
            sectorsPerCluster: spc,
            fatStartSector: reserved,
            sectorsPerFAT: fatSz,
            fatCount: fats,
            heapStartSector: heapStart,
            rootCluster: rootClus,
            totalClusters: totalSectors > heapStart ? UInt32((totalSectors - heapStart) / spc) : 0)
        return FSVolume(info: info, document: document, base: base)
    }

    // MARK: - Volume label

    /// FAT32 stores the label in the BPB; exFAT stores it in a root 0x83 entry.
    func volumeLabel() -> String {
        switch info.kind {
        case .fat32:
            let raw = document.bytes(in: (base + 0x47)..<(base + 0x52))
            return String(bytes: raw, encoding: .ascii)?
                .trimmingCharacters(in: .whitespaces) ?? ""
        case .exFAT:
            let chain = readChainDetailed(start: info.rootCluster)
            for offset in stride(from: 0, to: chain.bytes.count - 31, by: 32) {
                if chain.bytes[offset] == 0x83 {
                    let count = Int(chain.bytes[offset + 2])
                    guard count > 0, count <= 11 else { continue }
                    var chars: [UInt16] = []
                    for i in 0..<count {
                        let p = offset + 4 + i * 2
                        chars.append(UInt16(chain.bytes[p]) | (UInt16(chain.bytes[p + 1]) << 8))
                    }
                    return String(utf16CodeUnits: chars, count: chars.count)
                }
            }
            return ""
        }
    }

    // MARK: - Free space

    /// Counts free clusters. Returns nil if the allocation structures cannot be read.
    func freeClusterCount() -> UInt32? {
        switch info.kind {
        case .fat32:
            return fat32FreeClusters()
        case .exFAT:
            return exfatFreeClusters()
        }
    }

    private func fat32FreeClusters() -> UInt32 {
        var free: UInt32 = 0
        let count = Int(info.totalClusters) + 2
        let chunk = 1 << 18                          // 256 KiB of FAT entries
        var index = 2
        while index < count {
            let end = min(index + chunk / 4, count)
            let off = base + info.fatOffset + index * 4
            guard off + (end - index) * 4 <= document.size else { break }
            let block = document.bytes(in: off..<(off + (end - index) * 4))
            for i in stride(from: 0, to: block.count - 3, by: 4) {
                if u32(block, i) == 0 { free += 1 }
            }
            index = end
        }
        return free
    }

    private func exfatFreeClusters() -> UInt32? {
        // Find the allocation bitmap entry (0x81) in the root directory.
        let chain = readChainDetailed(start: info.rootCluster)
        var bitmapCluster: UInt32 = 0
        var bitmapLength: UInt64 = 0
        for offset in stride(from: 0, to: chain.bytes.count - 31, by: 32) {
            if chain.bytes[offset] == 0x81 {
                bitmapCluster = u32(chain.bytes, offset + 0x14)
                bitmapLength = u64(chain.bytes, offset + 0x18)
                break
            }
        }
        guard bitmapCluster >= 2, bitmapLength > 0 else { return nil }

        var free: UInt32 = 0
        var remaining = Int(bitmapLength)
        var cluster: UInt32? = bitmapCluster
        var visited: Set<UInt32> = []
        while let c = cluster, !visited.contains(c), remaining > 0 {
            visited.insert(c)
            let off = base + info.clusterOffset(c)
            let take = min(remaining, info.clusterSize, document.size - off)
            guard take > 0 else { break }
            for byte in document.bytes(in: off..<(off + take)) {
                free += UInt32(8 - byte.nonzeroBitCount)
            }
            remaining -= take
            cluster = nextCluster(c)
        }
        // Bits 0 and 1 map to the reserved clusters and are always marked used.
        return free >= 2 ? free - 2 : 0
    }

    // MARK: - FAT chain

    /// Next cluster in the chain, or nil at end-of-chain / on read failure.
    func nextCluster(_ cluster: UInt32) -> UInt32? {
        guard cluster >= 2 else { return nil }
        let entryOffset = base + info.fatOffset + Int(cluster) * 4
        guard entryOffset + 4 <= document.size else { return nil }
        let value = u32(document.bytes(in: entryOffset..<(entryOffset + 4)), 0) & 0x0FFF_FFFF
        if value >= 0x0FFF_FFF8 || value < 2 { return nil }   // EOC / free / bad
        return value
    }

    /// Walks a cluster chain, recording how the concatenated data maps to disk.
    private func readChainDetailed(start startCluster: UInt32) -> (bytes: [UInt8], segments: [(dataStart: Int, diskOffset: Int, length: Int)]) {
        var out: [UInt8] = []
        var segments: [(dataStart: Int, diskOffset: Int, length: Int)] = []
        var cluster: UInt32? = startCluster
        var visited: Set<UInt32> = []
        let cap = (4 << 20) / max(1, info.clusterSize) + 1
        while let c = cluster, visited.count < cap, !visited.contains(c) {
            visited.insert(c)
            let offset = base + info.clusterOffset(c)
            let end = min(offset + info.clusterSize, document.size)
            guard offset >= 0, offset < end else { break }
            let chunk = document.bytes(in: offset..<end)
            segments.append((dataStart: out.count, diskOffset: offset, length: chunk.count))
            out.append(contentsOf: chunk)
            cluster = nextCluster(c)
        }
        return (out, segments)
    }

    /// The full cluster chain of a file, streamed to `url` (recovery/copy).
    /// At most `logicalSize` bytes are written.
    func copyChain(start startCluster: UInt32, logicalSize: UInt64, to url: URL) throws {
        guard startCluster >= 2 else { return }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var cluster: UInt32? = startCluster
        var visited: Set<UInt32> = []
        var remaining = logicalSize
        while let c = cluster, !visited.contains(c), remaining > 0 {
            visited.insert(c)
            let offset = base + info.clusterOffset(c)
            let end = min(offset + info.clusterSize, document.size)
            guard offset >= 0, offset < end else { break }
            var chunk = document.bytes(in: offset..<end)
            if chunk.count > remaining { chunk = Array(chunk.prefix(Int(remaining))) }
            try handle.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
            cluster = nextCluster(c)
        }
    }

    /// Every cluster in a file's chain ("List Clusters").
    func clusterChain(start startCluster: UInt32) -> [UInt32] {
        var out: [UInt32] = []
        var cluster: UInt32? = startCluster
        var visited: Set<UInt32> = []
        while let c = cluster, !visited.contains(c) {
            visited.insert(c)
            out.append(c)
            cluster = nextCluster(c)
        }
        return out
    }

    // MARK: - Directory listing

    func listDirectory(cluster startCluster: UInt32) -> [FSEntry] {
        let chain = readChainDetailed(start: startCluster)
        switch info.kind {
        case .fat32: return parseFAT32Directory(chain.bytes, segments: chain.segments)
        case .exFAT: return parseExFATDirectory(chain.bytes, segments: chain.segments)
        }
    }

    private func resolve(_ dataIndex: Int, segments: [(dataStart: Int, diskOffset: Int, length: Int)]) -> Int {
        for seg in segments.reversed() where dataIndex >= seg.dataStart {
            return seg.diskOffset + (dataIndex - seg.dataStart)
        }
        return base
    }

    /// FAT12/16/32 32-byte entries with LFN assembly.
    private func parseFAT32Directory(_ data: [UInt8],
                                     segments: [(dataStart: Int, diskOffset: Int, length: Int)]) -> [FSEntry] {
        var entries: [FSEntry] = []
        var lfnParts: [(index: Int, text: String)] = []
        var offset = 0

        while offset + 32 <= data.count {
            let e = Array(data[offset..<(offset + 32)])
            let recordOffset = resolve(offset, segments: segments)
            offset += 32
            let first = e[0]
            if first == 0x00 { break }                 // end of directory
            let attr = e[0x0B]

            if attr == 0x0F {                          // LFN fragment
                if first != 0xE5 {
                    let index = Int(first & 0x1F)
                    lfnParts.append((index, lfnText(e)))
                }
                continue
            }
            if attr & 0x08 != 0 { lfnParts.removeAll(); continue }  // volume label

            let deleted = first == 0xE5
            let isDir = attr & 0x10 != 0
            let cluster = (UInt32(u16(e, 0x14)) << 16) | UInt32(u16(e, 0x1A))
            let size = UInt64(u32(e, 0x1C))

            let name: String
            if !deleted, !lfnParts.isEmpty {
                name = lfnParts.sorted { $0.index < $1.index }.map { $0.text }.joined()
            } else {
                name = shortName(e, deleted: deleted)
            }
            lfnParts.removeAll()
            if name.isEmpty || name == "." || name == ".." { continue }

            let created = fatTimestamp(date: u16(e, 0x10), time: u16(e, 0x0E),
                                       tenths: Int(e[0x0D]))
            let modified = fatTimestamp(date: u16(e, 0x18), time: u16(e, 0x16), tenths: 0)
            let accessed = fatTimestamp(date: u16(e, 0x12), time: 0, tenths: 0)

            entries.append(makeEntry(name: name, isDir: isDir, deleted: deleted,
                                     size: size, cluster: cluster,
                                     entryOffset: recordOffset, entryLength: 32,
                                     created: created, modified: modified, accessed: accessed,
                                     attributes: isDir ? "" : dosAttributes(UInt16(attr))))
        }
        return sortEntries(entries)
    }

    private func lfnText(_ e: [UInt8]) -> String {
        var chars: [UInt16] = []
        for range in [1..<11, 14..<26, 28..<32] {
            for i in stride(from: range.lowerBound, to: range.upperBound, by: 2) {
                let c = UInt16(e[i]) | (UInt16(e[i + 1]) << 8)
                if c == 0x0000 || c == 0xFFFF { return String(utf16CodeUnits: chars, count: chars.count) }
                chars.append(c)
            }
        }
        return String(utf16CodeUnits: chars, count: chars.count)
    }

    private func shortName(_ e: [UInt8], deleted: Bool) -> String {
        var nameBytes = Array(e[0..<8])
        if deleted { nameBytes[0] = 0x3F }             // '?' for the lost first char
        let name = String(bytes: nameBytes, encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let ext = String(bytes: Array(e[8..<11]), encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return ext.isEmpty ? name : "\(name).\(ext)"
    }

    /// Decodes a FAT directory date/time pair (plus 10 ms tick for creation).
    private func fatTimestamp(date: UInt16, time: UInt16, tenths: Int) -> Date? {
        guard date != 0 else { return nil }
        let day = Int(date & 0x1F)
        let month = Int((date >> 5) & 0x0F)
        let year = 1980 + Int((date >> 9) & 0x7F)
        let second = Int(time & 0x1F) * 2
        let minute = Int((time >> 5) & 0x3F)
        let hour = Int((time >> 11) & 0x1F)
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = hour; c.minute = minute; c.second = second
        guard let base = Calendar.current.date(from: c) else { return nil }
        return base.addingTimeInterval(TimeInterval(tenths) * 0.01)
    }

    /// exFAT entry sets: primary 0x85 + stream 0xC0 + name 0xC1…
    /// Deleted sets keep the same layout with the high bit of the type cleared.
    private func parseExFATDirectory(_ data: [UInt8],
                                     segments: [(dataStart: Int, diskOffset: Int, length: Int)]) -> [FSEntry] {
        var entries: [FSEntry] = []
        var offset = 0

        while offset + 32 <= data.count {
            let e = Array(data[offset..<(offset + 32)])
            let type = e[0]
            if type == 0x00 { break }
            let isFile = type == 0x85 || type == 0x05   // file / deleted file
            if !isFile { offset += 32; continue }       // label/bitmap/upcase/etc.

            let deleted = type == 0x05
            let secondaryCount = Int(e[1])
            let isDir = (u16(e, 4) & 0x10) != 0
            let recordOffset = resolve(offset, segments: segments)
            let created = exfatTimestamp(u32(e, 0x08), tenths: Int(e[0x0C]))
            let modified = exfatTimestamp(u32(e, 0x0E), tenths: Int(e[0x12]))
            let accessed = exfatTimestamp(u32(e, 0x14), tenths: Int(e[0x18]))

            var name = ""
            var size: UInt64 = 0
            var cluster: UInt32 = 0
            var cursor = offset + 32
            var remaining = secondaryCount
            while remaining > 0, cursor + 32 <= data.count {
                let s = Array(data[cursor..<(cursor + 32)])
                cursor += 32
                remaining -= 1
                switch s[0] {
                case 0xC0, 0x40:                        // stream extension
                    size = u64(s, 0x08)
                    cluster = u32(s, 0x14)
                case 0xC1, 0x41:                        // file name fragment
                    var chars: [UInt16] = []
                    for i in stride(from: 2, to: 32, by: 2) {
                        chars.append(UInt16(s[i]) | (UInt16(s[i + 1]) << 8))
                    }
                    name += String(utf16CodeUnits: chars, count: chars.count)
                default:
                    break
                }
            }
            offset = cursor
            name = name.replacingOccurrences(of: "\0", with: "")
            guard !name.isEmpty else { continue }
            entries.append(makeEntry(name: name, isDir: isDir, deleted: deleted,
                                     size: size, cluster: cluster,
                                     entryOffset: recordOffset,
                                     entryLength: (secondaryCount + 1) * 32,
                                     created: created, modified: modified, accessed: accessed,
                                     attributes: isDir ? "" : dosAttributes(u16(e, 4))))
        }
        return sortEntries(entries)
    }

    /// Decodes an exFAT 32-bit timestamp (1980 epoch, 2-second units) + 10 ms tick.
    private func exfatTimestamp(_ raw: UInt32, tenths: Int) -> Date? {
        guard raw != 0 else { return nil }
        let doubleSecond = Int(raw & 0x1F)
        let minute = Int((raw >> 5) & 0x3F)
        let hour = Int((raw >> 11) & 0x1F)
        let day = Int((raw >> 16) & 0x1F)
        let month = Int((raw >> 21) & 0x0F)
        let year = 1980 + Int((raw >> 25) & 0x7F)
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = hour; c.minute = minute; c.second = doubleSecond * 2
        guard let base = Calendar.current.date(from: c) else { return nil }
        return base.addingTimeInterval(TimeInterval(tenths) * 0.01)
    }

    private func dosAttributes(_ attr: UInt16) -> String {
        var s = ""
        if attr & 0x20 != 0 { s += "A" }
        if attr & 0x01 != 0 { s += "R" }
        if attr & 0x02 != 0 { s += "H" }
        if attr & 0x04 != 0 { s += "S" }
        return s
    }

    private func makeEntry(name: String, isDir: Bool, deleted: Bool,
                           size: UInt64, cluster: UInt32,
                           entryOffset: Int, entryLength: Int,
                           created: Date?, modified: Date?, accessed: Date?,
                           attributes: String) -> FSEntry {
        let offset = cluster >= 2 ? base + info.clusterOffset(cluster) : 0
        let reveal = isDir ? info.clusterSize : Int(min(size, UInt64(info.clusterSize)))
        let ext = (!isDir && name.contains(".")) ? String(name.split(separator: ".").last ?? "") : ""
        return FSEntry(name: name, ext: ext, isDirectory: isDir, isDeleted: deleted,
                       size: size, firstCluster: cluster,
                       dataOffset: offset, revealLength: max(1, reveal),
                       entryOffset: entryOffset, entryLength: entryLength,
                       created: created, modified: modified, accessed: accessed,
                       attributes: attributes)
    }

    private func sortEntries(_ entries: [FSEntry]) -> [FSEntry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

// MARK: - Scalar helpers (little-endian)

private func u16(_ b: [UInt8], _ o: Int) -> UInt16 {
    UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
}
private func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
}
private func u64(_ b: [UInt8], _ o: Int) -> UInt64 {
    UInt64(u32(b, o)) | (UInt64(u32(b, o + 4)) << 32)
}

// MARK: - Browsing state

/// Navigation state behind the file system panel.
final class FileSystemBrowser: ObservableObject {
    @Published private(set) var volume: FSVolume?
    @Published private(set) var label = ""
    @Published private(set) var freeClusters: UInt32? = nil
    @Published private(set) var entries: [FSEntry] = []
    @Published private(set) var pathNames: [String] = []
    @Published var status = ""
    @Published var selectedEntryID: UUID?
    /// "List Clusters" popover state.
    @Published var clusterListEntry: FSEntry?
    @Published var clusterList: [UInt32] = []

    /// Cluster stack backing `pathNames` (root is the bottom).
    private var clusterStack: [UInt32] = []
    private var attempted = false

    func reset() {
        volume = nil
        label = ""
        freeClusters = nil
        entries = []
        pathNames = []
        clusterStack = []
        status = ""
        selectedEntryID = nil
        clusterListEntry = nil
        clusterList = []
        attempted = false
    }

    /// Detects the file system and lists the root directory. Idempotent.
    func open(using state: AppState) {
        guard !attempted else { return }
        attempted = true
        guard let volume = FSVolume.detect(state.document) else {
            status = L.t("Unsupported or unknown file system.")
            return
        }
        self.volume = volume
        self.label = volume.volumeLabel()
        clusterStack = [volume.info.rootCluster]
        entries = volume.listDirectory(cluster: volume.info.rootCluster)
        status = ""
        computeFreeSpace(volume)
    }

    private func computeFreeSpace(_ volume: FSVolume) {
        DispatchQueue.global(qos: .utility).async {
            let free = volume.freeClusterCount()
            DispatchQueue.main.async { self.freeClusters = free }
        }
    }

    func enter(_ entry: FSEntry, using state: AppState) {
        guard entry.isDirectory, entry.firstCluster >= 2, let volume else { return }
        clusterStack.append(entry.firstCluster)
        pathNames.append(entry.name)
        entries = volume.listDirectory(cluster: entry.firstCluster)
        selectedEntryID = nil
    }

    func goUp(using state: AppState) {
        guard clusterStack.count > 1, let volume else { return }
        clusterStack.removeLast()
        pathNames.removeLast()
        entries = volume.listDirectory(cluster: clusterStack[clusterStack.count - 1])
        selectedEntryID = nil
    }

    /// "Open": folders navigate in, files reveal their data.
    func openEntry(_ entry: FSEntry, using state: AppState) {
        if entry.isDirectory { enter(entry, using: state) } else { reveal(entry, using: state) }
    }

    /// Selects the entry's data in the hex view, centred on screen.
    func reveal(_ entry: FSEntry, using state: AppState) {
        selectedEntryID = entry.id
        guard entry.dataOffset > 0, entry.dataOffset < state.size else { return }
        let end = min(entry.dataOffset + entry.revealLength, state.size) - 1
        state.anchor = max(entry.dataOffset, end)
        state.cursor = entry.dataOffset
        state.scrollCentered = true
        state.scrollToken &+= 1
        state.bump()
        state.statusMessage = L.f("Match at 0x%@", String(entry.dataOffset, radix: 16).uppercased())
    }

    /// Navigate → jump to the directory record itself.
    func gotoDirectoryEntry(_ entry: FSEntry, using state: AppState) {
        guard entry.entryOffset > 0 else { return }
        state.anchor = min(entry.entryOffset + entry.entryLength - 1, state.size - 1)
        state.cursor = entry.entryOffset
        state.scrollCentered = true
        state.scrollToken &+= 1
        state.bump()
        state.statusMessage = L.f("Match at 0x%@", String(entry.entryOffset, radix: 16).uppercased())
    }

    /// Navigate → build the cluster-chain list (shown in a sheet).
    func listClusters(_ entry: FSEntry) {
        guard let volume, entry.firstCluster >= 2 else {
            clusterListEntry = entry
            clusterList = []
            return
        }
        clusterListEntry = entry
        clusterList = volume.clusterChain(start: entry.firstCluster)
    }

    func jumpToCluster(_ cluster: UInt32, using state: AppState) {
        guard let volume else { return }
        let offset = volume.base + volume.info.clusterOffset(cluster)
        let length = min(volume.info.clusterSize, state.size - offset)
        guard offset > 0, length > 0 else { return }
        state.anchor = offset + length - 1
        state.cursor = offset
        state.scrollCentered = true
        state.scrollToken &+= 1
        state.bump()
        state.statusMessage = L.f("Cluster %d  ·  offset 0x%@", cluster,
                                  String(offset, radix: 16).uppercased())
    }

    /// Right-click "Recover / Copy…": stream the file's cluster chain to disk.
    func recover(_ entry: FSEntry, using state: AppState) {
        guard let volume, entry.firstCluster >= 2, !entry.isDirectory else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.canCreateDirectories = true
        panel.prompt = L.t("Recover / Copy…")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        status = L.f("Recovering %@…", entry.name)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try volume.copyChain(start: entry.firstCluster,
                                     logicalSize: entry.size, to: url)
                DispatchQueue.main.async {
                    self.status = L.f("Recovered %@ (%@)", entry.name,
                                      state.byteCountString(Int(entry.size)))
                }
            } catch {
                DispatchQueue.main.async {
                    self.status = L.f("Recovery failed: %@", error.localizedDescription)
                }
            }
        }
    }
}
