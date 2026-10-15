import Foundation

/// One directory entry shown in the file system panel.
struct FSEntry: Identifiable {
    let id = UUID()
    let name: String
    let isDirectory: Bool
    let isDeleted: Bool
    let size: UInt64
    let firstCluster: UInt32
    /// Absolute byte offset of the entry's data (first cluster).
    let dataOffset: Int
    /// Byte length used when revealing the entry in the hex view.
    let revealLength: Int
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

    var clusterSize: Int { bytesPerSector * sectorsPerCluster }

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
                rootCluster: u32(boot, 0x60))
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
        guard [512, 1024, 2048, 4096].contains(bps),
              spc > 0, reserved > 0, fats > 0, fatSz > 0, rootClus >= 2,
              label == "FAT32   " else { return nil }
        let info = FSVolumeInfo(
            kind: .fat32,
            bytesPerSector: bps,
            sectorsPerCluster: spc,
            fatStartSector: reserved,
            sectorsPerFAT: fatSz,
            fatCount: fats,
            heapStartSector: reserved + fats * fatSz,
            rootCluster: rootClus)
        return FSVolume(info: info, document: document, base: base)
    }

    // MARK: - FAT chain

    /// Next cluster in the chain, or nil at end-of-chain / on read failure.
    func nextCluster(_ cluster: UInt32) -> UInt32? {
        guard cluster >= 2 else { return nil }
        let entryOffset = base + info.fatStartSector * info.bytesPerSector + Int(cluster) * 4
        guard entryOffset + 4 <= document.size else { return nil }
        let value = u32(document.bytes(in: entryOffset..<(entryOffset + 4)), 0) & 0x0FFF_FFFF
        if value >= 0x0FFF_FFF8 || value < 2 { return nil }   // EOC / free / bad
        return value
    }

    /// Reads a cluster chain (capped at 4 MiB — directories are small).
    private func readChain(start startCluster: UInt32) -> [UInt8] {
        var out: [UInt8] = []
        var cluster: UInt32? = startCluster
        var visited: Set<UInt32> = []
        let cap = (4 << 20) / max(1, info.clusterSize) + 1
        while let c = cluster, visited.count < cap, !visited.contains(c) {
            visited.insert(c)
            let offset = base + info.clusterOffset(c)
            let end = min(offset + info.clusterSize, document.size)
            guard offset >= 0, offset < end else { break }
            out.append(contentsOf: document.bytes(in: offset..<end))
            cluster = nextCluster(c)
        }
        return out
    }

    // MARK: - Directory listing

    func listDirectory(cluster startCluster: UInt32) -> [FSEntry] {
        let data = readChain(start: startCluster)
        switch info.kind {
        case .fat32: return parseFAT32Directory(data)
        case .exFAT: return parseExFATDirectory(data)
        }
    }

    /// FAT12/16/32 32-byte entries with LFN assembly.
    private func parseFAT32Directory(_ data: [UInt8]) -> [FSEntry] {
        var entries: [FSEntry] = []
        var lfnParts: [(index: Int, text: String)] = []
        var offset = 0

        while offset + 32 <= data.count {
            let e = Array(data[offset..<(offset + 32)])
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

            entries.append(makeEntry(name: name, isDir: isDir, deleted: deleted,
                                     size: size, cluster: cluster))
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
        var extBytes = Array(e[8..<11])
        if deleted { nameBytes[0] = 0x3F }             // '?' for the lost first char
        let name = String(bytes: nameBytes, encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let ext = String(bytes: extBytes, encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return ext.isEmpty ? name : "\(name).\(ext)"
    }

    /// exFAT entry sets: primary 0x85 + stream 0xC0 + name 0xC1…
    /// Deleted sets keep the same layout with the high bit of the type cleared.
    private func parseExFATDirectory(_ data: [UInt8]) -> [FSEntry] {
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
            let isDir = (UInt16(e[4]) | UInt16(e[5]) << 8) & 0x10 != 0

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
                                     size: size, cluster: cluster))
        }
        return sortEntries(entries)
    }

    private func makeEntry(name: String, isDir: Bool, deleted: Bool,
                           size: UInt64, cluster: UInt32) -> FSEntry {
        let offset = cluster >= 2 ? base + info.clusterOffset(cluster) : 0
        let reveal = isDir ? info.clusterSize : Int(min(size, UInt64(info.clusterSize)))
        return FSEntry(name: name, isDirectory: isDir, isDeleted: deleted,
                       size: size, firstCluster: cluster,
                       dataOffset: offset, revealLength: max(1, reveal))
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
    @Published private(set) var entries: [FSEntry] = []
    @Published private(set) var pathNames: [String] = []
    @Published var status = ""
    @Published var selectedEntryID: UUID?

    /// Cluster stack backing `pathNames` (root is the bottom).
    private var clusterStack: [UInt32] = []
    private var attempted = false

    func reset() {
        volume = nil
        entries = []
        pathNames = []
        clusterStack = []
        status = ""
        selectedEntryID = nil
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
        clusterStack = [volume.info.rootCluster]
        entries = volume.listDirectory(cluster: volume.info.rootCluster)
        status = ""
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
}
