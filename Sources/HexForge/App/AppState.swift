import Foundation
import Combine
import AppKit

struct Bookmark: Identifiable, Hashable {
    let id = UUID()
    let offset: Int
    var name: String
}

struct HashResult: Identifiable {
    let id = UUID()
    let algorithm: String
    let value: String
}

enum FindMode: String, CaseIterable, Identifiable {
    case hex  = "Hex Bytes"
    case text = "Text"
    var id: String { rawValue }
}

/// How the hex view labels each row: raw file offset, sector number or cluster number.
enum AddressMode: String, CaseIterable, Identifiable {
    case fileOffset = "File Offset"
    case sector     = "Sector"
    case cluster    = "Cluster"
    var id: String { rawValue }
}

/// Which sub-tool of the File Tools panel is showing.
enum FileToolTab: String, CaseIterable, Identifiable {
    case generate = "Random Data"
    case split    = "Split"
    case join     = "Join"
    var id: String { rawValue }
}

/// Where generated random bytes are placed in the document.
enum RandomGenerateMode: String, CaseIterable, Identifiable {
    case insertAtCursor      = "Insert at cursor"
    case overwriteFromCursor = "Overwrite from cursor"
    case replaceSelection    = "Replace selection"
    var id: String { rawValue }
}

/// How a file is divided into parts.
enum FileSplitMode: String, CaseIterable, Identifiable {
    case bySize  = "By size"
    case byCount = "By count"
    var id: String { rawValue }
}

/// Which field the disk pick list is filling.
enum DiskTarget {
    case open
    case cloneSource
    case imageSource
}

/// A saved imaging/backup job. Persisted in UserDefaults so it survives launches.
struct BackupJob: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var source: String
    var destinationFolder: String
    var imageName: String
    var blockSize: Int
    var splitSize: Int64
    var compress: Bool
    var verify: Bool
    var checksum: Bool
    /// Minutes between automatic runs; 0 = manual only.
    var intervalMinutes: Int
    var lastRun: Date?
}

/// Single source of truth for the UI. Owns the document and every piece of
/// editor state (cursor, selection, panels, bookmarks, search options).
final class AppState: ObservableObject {

    enum ActivePane { case hex, ascii }

    let document: HexDocument

    // Mutation counter — bumped on every change so SwiftUI re-renders and the
    // custom hex view redraws, even for edits that don't touch a @Published field.
    @Published private(set) var revision = 0

    /// UI language, mirrored into `L10n` so every string lookup follows it.
    @Published var language: AppLanguage = L10n.savedLanguage() {
        didSet {
            L10n.language = language
            L10n.persist(language)
        }
    }

    // Editor position
    @Published var cursor = 0
    @Published var anchor = 0
    @Published var bytesPerRow = 16
    @Published var showAscii = true
    @Published var activePane: ActivePane = .hex

    // Sector / cluster addressing
    @Published var addressMode: AddressMode = .fileOffset
    @Published var sectorSize = 512
    @Published var sectorsPerCluster = 8

    // Panels
    @Published var showFind = false
    @Published var showGotoSector = false
    @Published var showGotoOffset = false
    @Published var showFill = false
    @Published var showInsert = false
    @Published var showHash = false
    @Published var showTemplates = false
    @Published var showClone = false
    @Published var showSector = false
    @Published var showCompare = false
    @Published var showImage = false
    @Published var showTransform = false
    @Published var showStatistics = false
    @Published var showFileTools = false
    @Published var showDiskList = false
    @Published var showInspector = false

    // Attached disks, refreshed whenever the pick list opens.
    @Published var disks: [DiskInfo] = []
    @Published var diskTarget: DiskTarget = .open

    // Detected file format (from magic bytes)
    @Published var detectedFormat: String?
    @Published var detectedParseOffset = 0

    // Structure templates loaded from external files
    @Published var customTemplates: [StructureTemplate] = []

    // Disk clone
    @Published var cloneSource = ""
    @Published var cloneDestination = ""
    @Published var cloneBlockSize = 1 << 20
    @Published var cloneVerify = false
    @Published var isCloning = false
    @Published var cloneProgress: Double = 0
    @Published var cloneTotalBytes: Int64 = 0
    @Published var cloneStatus = ""
    private var cloner: DiskCloner?

    // File compare
    @Published var comparePath = ""
    @Published var compareDifferences: [FileComparer.Difference] = []
    @Published var compareDiffOffsets: Set<Int> = []
    @Published var compareSummary = ""
    @Published var isComparing = false
    @Published var compareTotalRuns = 0
    private var compareIndex = -1
    private var comparerCancelled = false

    // Disk imaging + backup jobs
    @Published var imageSource = ""
    @Published var imageDestinationFolder = ""
    @Published var imageName = ""
    @Published var imageBlockSize = 1 << 20
    @Published var imageSplitSize: Int64 = 0
    @Published var imageCompress = false
    @Published var imageVerify = false
    @Published var imageChecksum = true
    @Published var isImaging = false
    @Published var imageProgress: Double = 0
    @Published var imageTotalBytes: Int64 = 0
    @Published var imageStatus = ""
    @Published var imageVerifyResult = ""
    @Published var backupJobs: [BackupJob] = []
    private var imagerJob: DiskImager.Job?
    private var backupTimer: Timer?

    // Encrypt / convert
    @Published var transformOperation: TransformOperation = .xorKey
    @Published var transformScopeIsSelection = true
    @Published var transformKey = ""
    @Published var transformKeyIsHex = true
    @Published var transformConstant = "FF"
    @Published var transformWordSize = 4
    @Published var transformECBMode = true
    @Published var transformIV = ""
    @Published var transformStatus = ""

    // Find / replace options
    @Published var findMode: FindMode = .hex
    @Published var findHex = ""
    @Published var findText = ""
    @Published var replaceWith = ""
    @Published var caseSensitive = true

    // Search (WinHex-style find panel)
    @Published var showSearch = false
    @Published var searchKind: SearchPatternKind = .hex
    @Published var searchHex = ""
    @Published var searchText = ""
    @Published var searchCaseInsensitive = true
    @Published var searchWildcardIsOn = false
    @Published var searchWildcardByte = "3F"
    @Published var searchDirection: SearchDirection = .forward
    @Published var searchSelectionOnly = false
    @Published var searchAlignmentIsOn = false
    @Published var searchAlignmentModulus = "512"
    @Published var searchAlignmentRemainder = "0"
    @Published var searchLimitIsOn = true
    @Published var searchLimitText = "10000"
    @Published var searchResults: [SearchHit] = []
    @Published var searchTotalFound = 0
    @Published var isSearching = false
    @Published var searchProgress: Double = 0
    @Published var searchStatus = ""
    /// True once a "find next" has wrapped around the end/start of the data.
    var searchWrapped = false
    /// Set from the UI thread, read by the background scan.
    var searchCancelled = false
    var searchToken = 0
    /// Shows the WinHex-style hit list docked above the hex view.
    @Published var showHitList = false
    /// Offset of the hit row the user last clicked, for row highlighting.
    @Published var selectedHitOffset: Int? = nil

    // Data inspector (floating palette) + file system browser
    /// false = little-endian (Intel), true = big-endian (Motorola).
    @Published var inspectorBigEndian = false
    @Published var showFileSystem = false
    /// Set before bumping `scrollToken` when a jump should centre the target
    /// row in the viewport instead of barely scrolling it into view.
    var scrollCentered = false
    /// Browsing state for the file system panel; reset when a document loads.
    let fsBrowser = FileSystemBrowser()

    /// Geometry reported by the parsed file system (0 = none). Drives the
    /// sector / cluster boundary lines drawn in the hex view.
    @Published var fsSectorSize = 0
    @Published var fsClusterSize = 0
    /// Byte offset chosen by the last mouse click, for the info panel. Hovering
    /// or moving the caret with the keyboard deliberately does not update it.
    @Published var selectedOffset: Int? = nil

    /// Byte offset the UI addresses are displayed from: 0 normally, the volume's
    /// boot sector once a file system is parsed (DBR = sector 0, the MBR area
    /// before it is not addressed).
    var displayBase: Int { showFileSystem ? (fsBrowser.volume?.base ?? 0) : 0 }
    /// true = decimal offsets and 0-15 column headers in the hex view.
    @Published var decimalAddress = false

    // Hash results
    @Published var hashScopeIsSelection = false
    @Published var hashResults: [HashResult] = []
    @Published var isHashing = false

    // Byte statistics / histogram
    @Published var statistics = ByteStatistics.empty
    @Published var isComputingStatistics = false
    @Published var statisticsScopeIsSelection = false
    @Published var statisticsStatus = ""

    // File tools: random data generation + split / join
    @Published var fileToolTab: FileToolTab = .generate

    @Published var randomGenerateMode: RandomGenerateMode = .insertAtCursor
    @Published var randomGenerateCountText = "256"
    @Published var randomGenerateStatus = ""
    @Published var isGenerating = false
    @Published var generateProgress: Double = 0
    private var generateJob: FileTools.Job?

    @Published var splitSource = ""
    @Published var splitFolder = ""
    @Published var splitBaseName = ""
    @Published var splitMode: FileSplitMode = .bySize
    @Published var splitPartSize: Int64 = 20 * 1_000_000
    @Published var splitPartCountText = "2"
    @Published var splitStatus = ""
    @Published var isSplitting = false
    @Published var splitProgress: Double = 0
    @Published var splitTotalBytes: Int64 = 0
    private var splitJob: FileTools.Job?

    @Published var joinInputFolder = ""
    @Published var joinFilePaths: [String] = []
    @Published var joinDestination = ""
    @Published var joinStatus = ""
    @Published var isJoining = false
    @Published var joinProgress: Double = 0
    @Published var joinTotalBytes: Int64 = 0
    private var joinJob: FileTools.Job?

    // Bookmarks + status
    @Published var bookmarks: [Bookmark] = []
    @Published var statusMessage = "Ready"

    // Set by the hex view so keyboard paging knows how many rows are visible.
    var visibleRows = 40
    /// Bumped to ask the hex view to scroll the cursor into view.
    @Published var scrollToken = 0

    private var nibbleHigh = true

    init(document: HexDocument = HexDocument()) {
        self.document = document
        L10n.language = language
        statusMessage = L.t("Ready")
        backupJobs = Self.loadBackupJobs()
        startBackupTimer()
    }

    deinit {
        backupTimer?.invalidate()
    }

    // MARK: - Derived values

    var size: Int { document.size }
    var fileName: String { document.fileName }
    var isDirty: Bool { document.isDirty }
    var isReadOnly: Bool { document.isReadOnly }
    var hasContent: Bool { document.size > 0 }

    var hasSelection: Bool { cursor != anchor }
    var selectionRange: Range<Int> {
        let lo = min(cursor, anchor)
        let hi = max(cursor, anchor)
        return lo..<(hi + 1)
    }
    var selectionLength: Int { hasSelection ? abs(cursor - anchor) + 1 : 1 }

    // MARK: - Mutation

    func bump() {
        revision &+= 1
    }

    // MARK: - Cursor movement

    func setCursor(_ offset: Int, extend: Bool) {
        guard size > 0 else { cursor = 0; anchor = 0; bump(); return }
        let clamped = max(0, min(offset, size - 1))
        cursor = clamped
        nibbleHigh = true
        if !extend { anchor = clamped }
        // Ask the canvas to keep the caret in view for keyboard/mouse moves too.
        scrollToken &+= 1
        bump()
    }

    func moveCursor(by delta: Int, extend: Bool) {
        setCursor(cursor + delta, extend: extend)
    }

    private func rowStart(_ offset: Int) -> Int { (offset / bytesPerRow) * bytesPerRow }
    private func rowEnd(_ offset: Int) -> Int {
        min(rowStart(offset) + bytesPerRow - 1, max(0, size - 1))
    }

    func selectAll() {
        guard size > 0 else { return }
        anchor = 0
        cursor = size - 1
        statusMessage = L.f("Selected %d bytes", size)
        bump()
    }

    func goto(offset: Int) {
        setCursor(offset, extend: false)
        scrollToken &+= 1
    }

    // MARK: - Sector / cluster addressing

    var clusterSize: Int { max(1, sectorSize) * max(1, sectorsPerCluster) }
    var totalSectors: Int { size == 0 ? 0 : (size + sectorSize - 1) / sectorSize }
    var totalClusters: Int { size == 0 ? 0 : (size + clusterSize - 1) / clusterSize }

    var cursorSector: Int { sectorSize > 0 ? cursor / sectorSize : 0 }
    var cursorCluster: Int { clusterSize > 0 ? cursor / clusterSize : 0 }
    var cursorOffsetInSector: Int { sectorSize > 0 ? cursor % sectorSize : 0 }
    var cursorOffsetInCluster: Int { clusterSize > 0 ? cursor % clusterSize : 0 }
    var cursorSectorWithinCluster: Int {
        sectorSize > 0 ? (cursor % clusterSize) / sectorSize : 0
    }
    var cursorClusterStartSector: Int { cursorCluster * max(1, sectorsPerCluster) }

    /// Divisor that turns a byte offset into an address in the current mode.
    var addressUnit: Int {
        switch addressMode {
        case .fileOffset: return 1
        case .sector:     return max(1, sectorSize)
        case .cluster:    return clusterSize
        }
    }

    var addressPrefix: String {
        switch addressMode {
        case .fileOffset: return ""
        case .sector:     return "S"
        case .cluster:    return "C"
        }
    }

    /// Hex digit count for the address column in the current mode.
    var addressDigits: Int {
        let units = max(1, size / max(1, addressUnit))
        return max(8, String(units, radix: 16).count)
    }

    func sectorStart(_ index: Int) -> Int { max(0, index) * max(1, sectorSize) }
    func clusterStart(_ index: Int) -> Int { max(0, index) * clusterSize }

    func goto(sector index: Int) {
        guard size > 0 else { return }
        setCursor(sectorStart(index), extend: false)
        scrollToken &+= 1
    }

    func goto(cluster index: Int) {
        guard size > 0 else { return }
        setCursor(clusterStart(index), extend: false)
        scrollToken &+= 1
    }

    // MARK: - Keyboard

    func handleKey(_ event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)

        // Hardware key codes are used instead of NSEvent.specialKey so the
        // behaviour is identical across macOS versions.
        switch event.keyCode {
        case 0x7B: moveCursor(by: -1, extend: shift); return                 // left
        case 0x7C: moveCursor(by: 1, extend: shift); return                  // right
        case 0x7E: moveCursor(by: -bytesPerRow, extend: shift); return       // up
        case 0x7D: moveCursor(by: bytesPerRow, extend: shift); return        // down
        case 0x74: moveCursor(by: -bytesPerRow * visibleRows, extend: shift); return // page up
        case 0x79: moveCursor(by: bytesPerRow * visibleRows, extend: shift); return  // page down
        case 0x73: setCursor(rowStart(cursor), extend: shift); return        // home
        case 0x77: setCursor(rowEnd(cursor), extend: shift); return          // end
        case 0x30: activePane = activePane == .hex ? .ascii : .hex; bump(); return // tab
        case 0x33, 0x75: deleteForward(); return                             // delete / backspace
        default: break
        }

        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return }

        if activePane == .hex {
            if let ch = chars.first, let value = ch.hexDigitValue, (0...15).contains(value) {
                editNibble(UInt8(value))
            }
        } else {
            if let byte = chars.utf8.first, byte >= 0x20, byte < 0x7F {
                writeByte(byte)
                moveCursor(by: 1, extend: false)
            }
        }
    }

    private func deleteForward() {
        deleteSelection()
    }

    /// Deletes the current selection, or the single byte under the cursor.
    func deleteSelection() {
        guard size > 0, !document.isReadOnly else { return }
        let range = hasSelection ? selectionRange : cursor..<(cursor + 1)
        document.delete(range: range)
        let newCursor = min(range.lowerBound, max(0, size - 1))
        cursor = newCursor
        anchor = newCursor
        nibbleHigh = true
        statusMessage = L.f("Deleted %d byte(s)", range.count)
        bump()
    }

    /// Inserts bytes at the cursor, growing the file.
    func insertBytes(_ bytes: [UInt8]) {
        guard !document.isReadOnly, !bytes.isEmpty else { return }
        let position = min(cursor, size)
        document.insert(bytes, at: position)
        anchor = position
        cursor = min(position + bytes.count - 1, max(0, size - 1))
        nibbleHigh = true
        statusMessage = L.f("Inserted %d byte(s)", bytes.count)
        scrollToken &+= 1
        bump()
    }

    /// Parses a hex string (e.g. "DE AD BE EF") and inserts it at the cursor.
    func insertHex(_ text: String) {
        guard !document.isReadOnly else { return }
        guard let pattern = BytePattern.parseHex(text), !pattern.bytes.isEmpty else {
            statusMessage = L.t("Enter hex bytes to insert (e.g. DE AD BE EF)")
            return
        }
        insertBytes(pattern.bytes.map { $0 ?? 0x00 })
    }

    func insertFromClipboard() {
        guard !document.isReadOnly else { return }
        guard let text = NSPasteboard.general.string(forType: .string) else {
            statusMessage = L.t("Clipboard is empty")
            return
        }
        insertHex(text)
    }

    private func editNibble(_ value: UInt8) {
        guard size > 0 else { return }
        let current = document.byte(at: cursor)
        if nibbleHigh {
            document.setByte((current & 0x0F) | (value << 4), at: cursor)
            nibbleHigh = false
            bump()
        } else {
            document.setByte((current & 0xF0) | value, at: cursor)
            nibbleHigh = true
            moveCursor(by: 1, extend: false)
        }
    }

    private func writeByte(_ value: UInt8) {
        guard size > 0 else { return }
        document.setByte(value, at: cursor)
        bump()
    }

    func fillSelection(with value: UInt8) {
        guard size > 0, !document.isReadOnly else { return }
        let range = hasSelection ? selectionRange : cursor..<(cursor + 1)
        document.overwrite(repeating: value, range: range)
        statusMessage = L.f("Filled %d byte(s) with 0x%@", range.count, String(format: "%02X", value))
        bump()
    }

    // MARK: - Clipboard

    func copy() {
        guard size > 0 else { return }
        let range = hasSelection ? selectionRange : cursor..<(cursor + 1)
        let bytes = document.bytes(in: range)
        let string: String
        if activePane == .ascii {
            string = String(bytes.map { byte -> Character in
                (byte >= 0x20 && byte < 0x7F) ? Character(UnicodeScalar(byte)) : Character(".")
            })
        } else {
            string = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        statusMessage = L.f("Copied %d byte(s)", bytes.count)
    }

    func cut() {
        guard size > 0, !document.isReadOnly else { return }
        let count = selectionLength
        copy()
        deleteSelection()
        statusMessage = L.f("Cut %d byte(s)", count)
    }

    func paste() {
        guard !document.isReadOnly else { return }
        guard size > 0 else { statusMessage = L.t("Nothing to paste into — the file is empty."); return }
        guard let text = NSPasteboard.general.string(forType: .string) else {
            statusMessage = L.t("Clipboard is empty")
            return
        }
        let bytes: [UInt8]
        if activePane == .ascii {
            bytes = Array(text.utf8)
        } else if let pattern = BytePattern.parseHex(text.isEmpty ? "" : text) {
            bytes = pattern.bytes.map { $0 ?? 0x00 }
        } else {
            statusMessage = L.t("Clipboard is not valid hex")
            return
        }
        var offset = cursor
        var written = 0
        for byte in bytes {
            guard document.contains(offset: offset) else { break }
            document.setByte(byte, at: offset)
            offset += 1
            written += 1
        }
        if written > 0 {
            anchor = cursor
            cursor = min(cursor + written - 1, max(0, size - 1))
            nibbleHigh = true
        }
        statusMessage = L.f("Pasted %d byte(s)", written)
        bump()
    }

    // MARK: - Undo / redo

    func undo() {
        guard document.canUndo else { statusMessage = L.t("Nothing to undo"); return }
        document.undo()
        clampPositionAfterStructuralEdit()
        statusMessage = L.t("Undo")
        scrollToken &+= 1
        bump()
    }

    func redo() {
        guard document.canRedo else { statusMessage = L.t("Nothing to redo"); return }
        document.redo()
        clampPositionAfterStructuralEdit()
        statusMessage = L.t("Redo")
        scrollToken &+= 1
        bump()
    }

    /// Undo/redo can shrink the document; keep the cursor and anchor inside the
    /// new bounds so the caret and selection stay valid.
    private func clampPositionAfterStructuralEdit() {
        let lastIndex = max(0, size - 1)
        cursor = min(cursor, lastIndex)
        anchor = min(anchor, lastIndex)
        nibbleHigh = true
    }

    // MARK: - Find / replace

    func currentPattern() -> BytePattern? {
        switch findMode {
        case .hex:  return BytePattern.parseHex(findHex)
        case .text: return BytePattern.parseText(findText, caseSensitive: caseSensitive)
        }
    }

    private func patternForReplace() -> (BytePattern, [UInt8])? {
        guard let pattern = currentPattern() else { return nil }
        let replacement: [UInt8]
        switch findMode {
        case .hex:
            guard let p = BytePattern.parseHex(replaceWith), p.bytes.count == pattern.count else { return nil }
            replacement = p.bytes.map { $0 ?? 0x00 }
        case .text:
            let bytes = Array(replaceWith.utf8)
            guard bytes.count == pattern.count else { return nil }
            replacement = bytes
        }
        return (pattern, replacement)
    }

    func findNext() {
        guard let pattern = currentPattern() else { statusMessage = L.t("Invalid search pattern"); return }
        let start = cursor + 1
        if start < size {
            let hits = Finder.findAll(pattern: pattern, document: document, in: start..<size, limit: 1)
            if let hit = hits.first { selectMatch(at: hit, length: pattern.count); return }
        }
        // wrap
        let all = Finder.findAll(pattern: pattern, document: document, in: 0..<size, limit: 1)
        if let hit = all.first {
            selectMatch(at: hit, length: pattern.count)
            statusMessage = L.f("Match at 0x%@ (wrapped)", String(hit, radix: 16).uppercased())
        } else {
            statusMessage = L.t("Not found")
        }
    }

    func findPrevious() {
        guard let pattern = currentPattern() else { statusMessage = L.t("Invalid search pattern"); return }
        var start = cursor
        if start <= 0 { start = size }
        var hits = Finder.findAll(pattern: pattern, document: document, in: 0..<start)
        if hits.isEmpty {
            hits = Finder.findAll(pattern: pattern, document: document, in: 0..<size)
            if let hit = hits.last {
                selectMatch(at: hit, length: pattern.count)
                statusMessage = L.f("Match at 0x%@ (wrapped)", String(hit, radix: 16).uppercased())
            } else {
                statusMessage = L.t("Not found")
            }
            return
        }
        if let hit = hits.last {
            selectMatch(at: hit, length: pattern.count)
        }
    }

    func selectMatch(at offset: Int, length: Int) {
        anchor = offset
        cursor = min(offset + max(0, length - 1), max(0, size - 1))
        nibbleHigh = true
        statusMessage = L.f("Match at 0x%@", String(offset, radix: 16).uppercased())
        scrollToken &+= 1
        bump()
    }

    func replaceAll() {
        guard size > 0, !document.isReadOnly else { return }
        guard let (pattern, replacement) = patternForReplace() else {
            statusMessage = L.t("Invalid pattern or replacement length mismatch")
            return
        }
        let hits = Finder.findAll(pattern: pattern, document: document, in: 0..<size)
        guard !hits.isEmpty else { statusMessage = L.t("Not found"); return }
        for hit in hits {
            for (k, byte) in replacement.enumerated() {
                guard document.contains(offset: hit + k) else { break }
                document.setByte(byte, at: hit + k)
            }
        }
        statusMessage = L.f("Replaced %d occurrence(s)", hits.count)
        bump()
    }

    // MARK: - Hash

    func computeHashes(overSelection: Bool) {
        guard size > 0 else { return }
        let range = (overSelection && hasSelection) ? selectionRange : 0..<size
        hashScopeIsSelection = overSelection && hasSelection
        isHashing = true
        statusMessage = L.t("Computing checksums…")

        let doc = document
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var results: [HashResult] = []
            for algorithm in HashAlgorithm.allCases {
                let value = HashService.compute(
                    algorithm,
                    size: range.count,
                    base: range.lowerBound,
                    reader: { doc.bytes(in: $0) }
                )
                results.append(HashResult(algorithm: algorithm.rawValue, value: value))
            }
            DispatchQueue.main.async {
                self?.hashResults = results
                self?.isHashing = false
                self?.statusMessage = L.t("Checksums computed")
                self?.bump()
            }
        }
    }

    // MARK: - Byte statistics

    func computeStatistics(overSelection: Bool) {
        guard size > 0 else { return }
        let range = (overSelection && hasSelection) ? selectionRange : 0..<size
        statisticsScopeIsSelection = overSelection && hasSelection
        isComputingStatistics = true
        statisticsStatus = L.t("Computing…")
        statusMessage = L.t("Analysing byte frequencies…")

        let doc = document
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = ByteStatisticsService.compute(
                size: range.count,
                base: range.lowerBound,
                reader: { doc.bytes(in: $0) }
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.statistics = result
                self.isComputingStatistics = false
                let label = self.statisticsScopeIsSelection ? L.t("selection") : L.t("file")
                self.statisticsStatus = L.f("%d byte(s) analysed · %d distinct value(s) · entropy %.3f bits/byte",
                                            result.totalBytes, result.distinctValues, result.entropy)
                self.statusMessage = L.f("Byte statistics computed for %@", label)
                self.bump()
            }
        }
    }

    // MARK: - Bookmarks

    func addBookmarkAtCursor() {
        let name = "0x" + String(cursor, radix: 16).uppercased()
        bookmarks.append(Bookmark(offset: cursor, name: name))
        bookmarks.sort { $0.offset < $1.offset }
        statusMessage = L.f("Bookmark added at %@", name)
    }

    // MARK: - Format detection

    /// Identifies the file format from its signature bytes and caches the result
    /// for the UI (sidebar, templates panel).
    @discardableResult
    func detectFormat() -> FileSignature? {
        let signature = document.size > 0 ? SignatureDetector.detect(document) : nil
        detectedFormat = signature?.name
        detectedParseOffset = signature?.parseOffset ?? 0
        return signature
    }

    // MARK: - File operations

    func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L.t("Choose a file (or navigate to /dev for a raw device)")
        panel.directoryURL = URL(fileURLWithPath: "/")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        document.load(url: url)
        clearCompare()
        clearSearchResults()
        fsBrowser.reset()
        fsSectorSize = 0
        fsClusterSize = 0
        selectedOffset = nil
        if showFileSystem { fsBrowser.open(using: self) }
        cursor = 0; anchor = 0; nibbleHigh = true
        if let signature = detectFormat() {
            statusMessage = L.f("Opened %@ · %@", url.lastPathComponent, signature.name)
        } else {
            statusMessage = L.f("Opened %@ (%@)", url.lastPathComponent, byteCountString(document.size))
        }
        scrollToken &+= 1
        bump()
    }

    func openDevice() {
        let alert = NSAlert()
        alert.messageText = L.t("Open Raw Device")
        alert.informativeText = L.t("Enter an absolute device path, e.g. /dev/disk2 or /dev/rdisk2. Devices are opened read-only.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "/dev/rdisk2"
        alert.accessoryView = field
        alert.addButton(withTitle: L.t("Open"))
        alert.addButton(withTitle: L.t("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let path = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        openDevice(at: path)
    }

    /// Opens a file or raw device by path. Devices are mapped explicitly so a
    /// whole disk is never read into memory.
    func openDevice(at path: String) {
        let url = URL(fileURLWithPath: path)
        var opened = false

        if path.hasPrefix("/dev/") {
            let length = DiskService.deviceSize(ofPath: path)
            if length > 0 { opened = document.loadDevice(url: url, length: length) }
        } else {
            document.load(url: url)
            opened = document.size > 0
        }

        if !opened { document.load(url: nil) }
        clearCompare()
        clearSearchResults()
        fsBrowser.reset()
        fsSectorSize = 0
        fsClusterSize = 0
        selectedOffset = nil
        if showFileSystem { fsBrowser.open(using: self) }
        cursor = 0; anchor = 0; nibbleHigh = true

        if !opened {
            statusMessage = L.f("Could not open %@ (permission or unknown size)", path)
        } else if let signature = detectFormat() {
            statusMessage = L.f("Opened device %@ · %@", path, signature.name)
        } else {
            statusMessage = L.f("Opened device %@ (%@)", path, byteCountString(document.size))
        }
        scrollToken &+= 1
        bump()
    }

    // MARK: - Disk list

    /// Opens the pick list for `target`, refreshing the device list first.
    func presentDiskList(for target: DiskTarget) {
        diskTarget = target
        refreshDisks()
        showDiskList = true
    }

    func refreshDisks() {
        disks = DiskService.list()
        statusMessage = disks.isEmpty ? L.t("No disks found.") : L.f("Found %d disk(s).", disks.count)
    }

    /// Applies the picked device to whatever asked for it. Returns false when the
    /// pick could not be used and the sheet should stay open.
    func applyDiskSelection(_ disk: DiskInfo) -> Bool {
        switch diskTarget {
        case .open:
            guard DiskService.isPrivileged else {
                promptForAdministratorRights()
                return false
            }
            openDevice(at: disk.rawPath)
        case .cloneSource:
            cloneSource = disk.rawPath
            if !DiskService.isPrivileged { statusMessage = L.t("Raw devices need administrator rights.") }
        case .imageSource:
            imageSource = disk.rawPath
            if !DiskService.isPrivileged { statusMessage = L.t("Raw devices need administrator rights.") }
        }
        return true
    }

    func copyPath(_ path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
        statusMessage = L.f("Copied %@", path)
    }

    /// macOS only lets root open `/dev/disk*`, so offer to relaunch when a pick
    /// needs privileges the current process does not have.
    func promptForAdministratorRights() {
        let alert = NSAlert()
        alert.messageText = L.t("Administrator rights required")
        alert.informativeText = L.t("Reading a raw disk needs administrator rights. Restart HexForge as administrator to continue.")
        alert.addButton(withTitle: L.t("Restart as Administrator"))
        alert.addButton(withTitle: L.t("Copy Command"))
        alert.addButton(withTitle: L.t("Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            restartAsAdministrator()
        case .alertSecondButtonReturn:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(administratorCommand, forType: .string)
            statusMessage = L.t("Administrator command copied to the clipboard.")
        default:
            break
        }
    }

    var administratorCommand: String {
        let executable = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
        return "sudo '\(executable)'"
    }

    /// Relaunches through Terminal, which keeps the new process in the user's
    /// GUI session while `sudo` gives it root — a privileged helper or
    /// AppleScript "administrator privileges" would drop the window-server
    /// connection and the window would never appear.
    func restartAsAdministrator() {
        let executable = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
        guard !executable.isEmpty else { return }

        let escaped = administratorCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"

        var error: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard error == nil else {
            statusMessage = L.t("Could not start the administrator session.")
            return
        }
        NSApp.terminate(nil)
    }

    func save() {
        guard let url = document.url else { saveAs(); return }
        do {
            try document.save(to: url)
            statusMessage = L.f("Saved %@", url.lastPathComponent)
        } catch {
            statusMessage = L.f("Save failed: %@", error.localizedDescription)
        }
        bump()
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.url?.lastPathComponent ?? "untitled.bin"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.save(to: url)
            statusMessage = L.f("Saved %@", url.lastPathComponent)
        } catch {
            statusMessage = L.f("Save failed: %@", error.localizedDescription)
        }
        bump()
    }

    // MARK: - External templates

    /// Built-in templates followed by any loaded from files.
    var allTemplates: [StructureTemplate] { BuiltinTemplates.all + customTemplates }

    func loadTemplates() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L.t("Choose a HexForge structure template file (.json)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let loaded = try TemplateLoader.load(from: url)
            customTemplates.append(contentsOf: loaded)
            statusMessage = L.f("Loaded %d template(s) from %@", loaded.count, url.lastPathComponent)
        } catch {
            statusMessage = L.f("Template load failed: %@", error.localizedDescription)
        }
    }

    func clearCustomTemplates() {
        guard !customTemplates.isEmpty else { return }
        customTemplates.removeAll()
        statusMessage = L.t("Removed external templates")
    }

    // MARK: - Disk clone

    func chooseCloneSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L.t("Choose a source file, or navigate to /dev for a raw device")
        panel.directoryURL = document.url?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/")
        if panel.runModal() == .OK, let url = panel.url { cloneSource = url.path }
    }

    func chooseCloneDevice() {
        presentDiskList(for: .cloneSource)
    }

    func chooseCloneDestination() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clone.img"
        panel.message = L.t("Choose a destination image file")
        if panel.runModal() == .OK, let url = panel.url { cloneDestination = url.path }
    }

    func startClone() {
        guard !isCloning else { return }
        let source = cloneSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = cloneDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !destination.isEmpty else {
            cloneStatus = L.t("Enter both a source and a destination.")
            return
        }

        var options = DiskCloner.Options()
        options.blockSize = cloneBlockSize
        options.verify = cloneVerify

        let cloner = DiskCloner()
        self.cloner = cloner
        isCloning = true
        cloneProgress = 0
        cloneTotalBytes = DiskCloner.size(of: URL(fileURLWithPath: source))
        cloneStatus = L.t("Cloning…")
        statusMessage = L.f("Cloning %@", source)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try cloner.clone(from: URL(fileURLWithPath: source),
                                 to: URL(fileURLWithPath: destination),
                                 options: options) { done, total in
                    DispatchQueue.main.async {
                        if total > 0 {
                            self.cloneTotalBytes = total
                            self.cloneProgress = min(1.0, Double(done) / Double(total))
                            self.cloneStatus = "\(self.byteCountString(Int(done))) / \(self.byteCountString(Int(total)))"
                        } else {
                            self.cloneStatus = L.f("%@ copied", self.byteCountString(Int(done)))
                        }
                    }
                }
                DispatchQueue.main.async {
                    self.isCloning = false
                    self.cloneProgress = 1
                    self.cloneStatus = options.verify ? L.t("Clone written and verified.") : L.t("Clone complete.")
                    self.statusMessage = L.f("Clone complete: %@", destination)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isCloning = false
                    self.cloneStatus = error.localizedDescription
                    self.statusMessage = L.f("Clone failed: %@", error.localizedDescription)
                }
            }
        }
    }

    func cancelClone() {
        cloner?.cancel()
        cloneStatus = L.t("Cancelling…")
    }

    // MARK: - File compare

    func chooseCompareFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L.t("Choose the file to compare with the open document")
        panel.directoryURL = document.url?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/")
        if panel.runModal() == .OK, let url = panel.url { comparePath = url.path }
    }

    func runCompare() {
        guard !isComparing else { return }
        let path = comparePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            compareSummary = L.t("Choose a file to compare against.")
            return
        }
        guard document.size > 0 else {
            compareSummary = L.t("Open a file first.")
            return
        }
        let other = URL(fileURLWithPath: path)
        let doc = document
        isComparing = true
        comparerCancelled = false
        compareSummary = L.t("Comparing…")
        statusMessage = L.f("Comparing %@ with %@…", fileName, other.lastPathComponent)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try FileComparer.compare(
                    document: doc,
                    against: other,
                    isCancelled: { self?.comparerCancelled ?? false }
                )
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isComparing = false
                    self.compareDifferences = Array(result.differences.prefix(500))
                    self.compareDiffOffsets = result.diffOffsetSet(limit: 500_000)
                    self.compareTotalRuns = result.totalDifferenceRuns
                    self.compareSummary = result.summaryText(openName: doc.fileName,
                                                             otherName: other.lastPathComponent)
                    self.compareIndex = -1
                    self.statusMessage = L.f("Compare done · %d difference run(s)", result.totalDifferenceRuns)
                    if let first = result.differences.first {
                        self.goto(offset: first.offset)
                        // We already jumped to the first run, so the next "Next Diff"
                        // must advance to the second one.
                        self.compareIndex = 0
                    }
                    self.bump()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isComparing = false
                    self.compareSummary = error.localizedDescription
                    self.statusMessage = L.f("Compare failed: %@", error.localizedDescription)
                }
            }
        }
    }

    func cancelCompare() {
        comparerCancelled = true
        compareSummary = L.t("Cancelling…")
    }

    func gotoNextDifference() {
        guard !compareDifferences.isEmpty else { return }
        compareIndex = compareIndex + 1 >= compareDifferences.count ? 0 : compareIndex + 1
        goto(offset: compareDifferences[compareIndex].offset)
    }

    func gotoPreviousDifference() {
        guard !compareDifferences.isEmpty else { return }
        compareIndex = compareIndex - 1 < 0 ? compareDifferences.count - 1 : compareIndex - 1
        goto(offset: compareDifferences[compareIndex].offset)
    }

    func clearCompare() {
        compareDifferences = []
        compareDiffOffsets = []
        compareSummary = ""
        compareTotalRuns = 0
        compareIndex = -1
        isComparing = false
    }

    /// Drops the search hit list — called when a different document is loaded,
    /// because stored offsets would point into the wrong data.
    func clearSearchResults() {
        searchResults = []
        searchTotalFound = 0
        searchStatus = ""
        showHitList = false
        selectedHitOffset = nil
    }

    // MARK: - Encrypt / convert

    func applyTransform() {
        guard size > 0 else { transformStatus = L.t("Open a file first."); return }
        guard !document.isReadOnly else { transformStatus = L.t("Document is read-only."); return }
        if transformScopeIsSelection && !hasSelection {
            transformStatus = L.t("Select bytes first, or choose “Whole file”.")
            return
        }
        let range = (transformScopeIsSelection && hasSelection) ? selectionRange : 0..<size
        let input = document.bytes(in: range)

        var request = TransformRequest(operation: transformOperation)
        request.keyText = transformKey
        request.keyIsHex = transformKeyIsHex
        request.constantText = transformConstant
        request.wordSize = transformWordSize
        request.ecbMode = transformECBMode
        request.ivText = transformIV

        do {
            let outcome = try CryptoTransform.apply(request, to: input)
            document.replace(range: range, with: outcome.bytes)
            let start = range.lowerBound
            anchor = min(start, max(0, size - 1))
            cursor = min(start + max(0, outcome.bytes.count - 1), max(0, size - 1))
            nibbleHigh = true
            transformStatus = outcome.message
            statusMessage = outcome.message
            scrollToken &+= 1
            bump()
        } catch {
            transformStatus = error.localizedDescription
            statusMessage = L.f("Transform failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Disk imaging

    func chooseImageSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L.t("Choose a source file, or navigate to /dev for a raw device")
        panel.directoryURL = document.url?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/")
        if panel.runModal() == .OK, let url = panel.url { imageSource = url.path }
    }

    func chooseImageDevice() {
        presentDiskList(for: .imageSource)
    }

    func chooseImageDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L.t("Choose a folder for the image files")
        if panel.runModal() == .OK, let url = panel.url { imageDestinationFolder = url.path }
    }

    func startImage() {
        guard !isImaging else { return }
        let source = imageSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = imageDestinationFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !folder.isEmpty else {
            imageStatus = L.t("Choose both a source and a destination folder.")
            return
        }
        var options = DiskImager.Options()
        options.blockSize = imageBlockSize
        options.splitSize = imageCompress ? 0 : imageSplitSize
        options.compress = imageCompress
        options.verify = imageVerify
        options.checksum = imageChecksum
        runImageJob(source: URL(fileURLWithPath: source),
                    folder: URL(fileURLWithPath: folder),
                    name: imageName,
                    options: options)
    }

    func cancelImage() {
        imagerJob?.cancel()
        imageStatus = L.t("Cancelling…")
    }

    private func runImageJob(source: URL, folder: URL, name: String, options: DiskImager.Options) {
        guard !isImaging else { return }
        let job = DiskImager.Job()
        imagerJob = job
        isImaging = true
        imageProgress = 0
        imageVerifyResult = ""
        imageTotalBytes = DiskCloner.size(of: source)
        imageStatus = L.t("Imaging…")
        statusMessage = L.f("Imaging %@", source.lastPathComponent)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try DiskImager.createImage(from: source,
                                                        to: folder,
                                                        name: name,
                                                        options: options,
                                                        job: job) { done, total in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if total > 0 {
                            self.imageTotalBytes = total
                            self.imageProgress = min(1.0, Double(done) / Double(total))
                            self.imageStatus = "\(self.byteCountString(Int(done))) / \(self.byteCountString(Int(total)))"
                        } else {
                            self.imageStatus = L.f("%@ written", self.byteCountString(Int(done)))
                        }
                    }
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isImaging = false
                    self.imageProgress = 1
                    self.imageStatus = L.f("Image complete · %d volume(s) · %@", result.manifest.volumes.count, result.manifestURL.lastPathComponent)
                    self.statusMessage = L.f("Image written: %@", result.manifestURL.path)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isImaging = false
                    self.imageStatus = error.localizedDescription
                    self.statusMessage = L.f("Imaging failed: %@", error.localizedDescription)
                }
            }
        }
    }

    func verifyImageFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L.t("Choose an image manifest (name.hfmeta.json)")
        if !imageDestinationFolder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: imageDestinationFolder)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runVerify(manifestURL: url)
    }

    private func runVerify(manifestURL: URL) {
        guard !isImaging else { return }
        let job = DiskImager.Job()
        imagerJob = job
        isImaging = true
        imageVerifyResult = L.t("Verifying…")
        statusMessage = L.f("Verifying %@…", manifestURL.lastPathComponent)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let report = try DiskImager.verifyImage(manifestURL: manifestURL, job: job) { _, _ in }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isImaging = false
                    if !report.hadChecksums {
                        self.imageVerifyResult = L.f("Manifest has no checksums; %d block(s) read but not compared.", report.blocksChecked)
                        self.statusMessage = L.t("Verify: no checksums recorded")
                    } else if report.mismatches == 0 {
                        self.imageVerifyResult = L.f("Verified: %d block(s), all checksums match.", report.blocksChecked)
                        self.statusMessage = L.t("Image verified OK")
                    } else {
                        let at = report.firstMismatchOffset.map { "0x" + String($0, radix: 16).uppercased() } ?? "?"
                        self.imageVerifyResult = L.f("FAILED: %d mismatch(es), first at %@.", report.mismatches, at)
                        self.statusMessage = L.t("Image verification failed")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isImaging = false
                    self.imageVerifyResult = error.localizedDescription
                    self.statusMessage = L.f("Verify failed: %@", error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Backup jobs

    func addBackupJob() {
        let source = imageSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = imageDestinationFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !folder.isEmpty else {
            imageStatus = L.t("Set a source and destination folder before saving a backup job.")
            return
        }
        let job = BackupJob(name: imageName.isEmpty ? (source as NSString).lastPathComponent : imageName,
                            source: source,
                            destinationFolder: folder,
                            imageName: imageName,
                            blockSize: imageBlockSize,
                            splitSize: imageCompress ? 0 : imageSplitSize,
                            compress: imageCompress,
                            verify: imageVerify,
                            checksum: imageChecksum,
                            intervalMinutes: 0,
                            lastRun: nil)
        backupJobs.append(job)
        saveBackupJobs()
        statusMessage = L.f("Backup job saved: %@", job.name)
    }

    func removeBackupJob(_ job: BackupJob) {
        backupJobs.removeAll { $0.id == job.id }
        saveBackupJobs()
        statusMessage = L.t("Backup job removed")
    }

    func updateBackupJob(_ job: BackupJob) {
        guard let index = backupJobs.firstIndex(where: { $0.id == job.id }) else { return }
        backupJobs[index] = job
        saveBackupJobs()
    }

    func runBackupJob(_ job: BackupJob) {
        guard !isImaging else { return }
        var options = DiskImager.Options()
        options.blockSize = job.blockSize
        options.splitSize = job.compress ? 0 : job.splitSize
        options.compress = job.compress
        options.verify = job.verify
        options.checksum = job.checksum

        imageSource = job.source
        imageDestinationFolder = job.destinationFolder
        imageName = job.imageName
        imageBlockSize = job.blockSize
        imageSplitSize = job.splitSize
        imageCompress = job.compress
        imageVerify = job.verify
        imageChecksum = job.checksum

        runImageJob(source: URL(fileURLWithPath: job.source),
                    folder: URL(fileURLWithPath: job.destinationFolder),
                    name: job.imageName,
                    options: options)
        markJobRun(job)
    }

    private func markJobRun(_ job: BackupJob) {
        guard let index = backupJobs.firstIndex(where: { $0.id == job.id }) else { return }
        backupJobs[index].lastRun = Date()
        saveBackupJobs()
    }

    private static let backupJobsKey = "HexForge.backupJobs"

    private static func loadBackupJobs() -> [BackupJob] {
        guard let data = UserDefaults.standard.data(forKey: backupJobsKey) else { return [] }
        return (try? JSONDecoder().decode([BackupJob].self, from: data)) ?? []
    }

    private func saveBackupJobs() {
        guard let data = try? JSONEncoder().encode(backupJobs) else { return }
        UserDefaults.standard.set(data, forKey: Self.backupJobsKey)
    }

    private func startBackupTimer() {
        backupTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.runDueBackups()
        }
        RunLoop.main.add(timer, forMode: .common)
        backupTimer = timer
    }

    /// Runs the oldest job whose interval has elapsed (one per tick, to avoid
    /// overlapping imaging work).
    private func runDueBackups() {
        guard !isImaging else { return }
        let now = Date()
        let due = backupJobs.first { job in
            guard job.intervalMinutes > 0 else { return false }
            guard let last = job.lastRun else { return true }
            return now.timeIntervalSince(last) >= Double(job.intervalMinutes) * 60
        }
        if let due { runBackupJob(due) }
    }

    // MARK: - File tools (random data / split / join)

    /// Parses a byte count with an optional K/M/G suffix (e.g. "256", "4k", "1M").
    func parsedByteCount(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return 0 }
        let suffixes: [(String, Int)] = [
            ("kib", 1 << 10), ("mib", 1 << 20), ("gib", 1 << 30),
            ("kb", 1 << 10), ("mb", 1 << 20), ("gb", 1 << 30),
            ("k", 1 << 10), ("m", 1 << 20), ("g", 1 << 30)
        ]
        for (suffix, mult) in suffixes where trimmed.hasSuffix(suffix) {
            let number = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            if let value = Double(number) { return Int(value * Double(mult)) }
            return 0
        }
        return Int(trimmed) ?? 0
    }

    func fileSize(atPath path: String) -> Int {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey])
        return Int(values?.fileSize ?? 0)
    }

    // MARK: Random data

    func generateRandomData() {
        guard !isGenerating else { return }
        guard !document.isReadOnly else {
            randomGenerateStatus = L.t("Document is read-only.")
            return
        }
        let count = parsedByteCount(randomGenerateCountText)
        guard count > 0 else {
            randomGenerateStatus = L.t("Enter how many bytes to generate.")
            return
        }
        guard count <= FileTools.maxGenerateBytes else {
            randomGenerateStatus = L.f("At most %@ per edit.", byteCountString(FileTools.maxGenerateBytes))
            return
        }
        if randomGenerateMode == .replaceSelection && !hasSelection {
            randomGenerateStatus = L.t("Select bytes first, or choose another mode.")
            return
        }

        let job = FileTools.Job()
        generateJob = job
        isGenerating = true
        generateProgress = 0
        randomGenerateStatus = L.f("Generating %@…", byteCountString(count))
        statusMessage = L.t("Generating random data…")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let bytes = try FileTools.randomBytes(count: count, job: job) { done in
                    DispatchQueue.main.async {
                        self?.generateProgress = Double(done) / Double(count)
                    }
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isGenerating = false
                    self.generateProgress = 1
                    self.applyGeneratedBytes(bytes, mode: self.randomGenerateMode)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isGenerating = false
                    self.randomGenerateStatus = error.localizedDescription
                    self.statusMessage = L.f("Generate failed: %@", error.localizedDescription)
                }
            }
        }
    }

    func cancelGenerate() {
        generateJob?.cancel()
        randomGenerateStatus = L.t("Cancelling…")
    }

    private func applyGeneratedBytes(_ bytes: [UInt8], mode: RandomGenerateMode) {
        guard !bytes.isEmpty else { return }
        let placed: Int
        switch mode {
        case .insertAtCursor:
            let position = min(cursor, size)
            document.insert(bytes, at: position)
            anchor = position
            cursor = min(position + bytes.count - 1, max(0, size - 1))
            placed = bytes.count
        case .overwriteFromCursor:
            let start = min(cursor, size)
            if start >= size {
                document.insert(bytes, at: start)
                anchor = start
                cursor = min(start + bytes.count - 1, max(0, size - 1))
                placed = bytes.count
            } else {
                let n = min(bytes.count, size - start)
                document.replace(range: start..<(start + n), with: Array(bytes[0..<n]))
                anchor = start
                cursor = min(start + max(0, n - 1), max(0, size - 1))
                placed = n
            }
        case .replaceSelection:
            let range = selectionRange
            document.replace(range: range, with: bytes)
            anchor = min(range.lowerBound, max(0, size - 1))
            cursor = min(range.lowerBound + max(0, bytes.count - 1), max(0, size - 1))
            placed = bytes.count
        }
        nibbleHigh = true
        randomGenerateStatus = L.f("Generated %@ of random data.", byteCountString(placed))
        statusMessage = L.f("Generated %@ random byte(s)", byteCountString(placed))
        scrollToken &+= 1
        bump()
    }

    // MARK: Split

    func chooseSplitSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L.t("Choose the file to split")
        panel.directoryURL = document.url?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/")
        if panel.runModal() == .OK, let url = panel.url {
            splitSource = url.path
            if splitBaseName.isEmpty { splitBaseName = url.lastPathComponent }
        }
    }

    func chooseSplitFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L.t("Choose a folder for the parts")
        if panel.runModal() == .OK, let url = panel.url { splitFolder = url.path }
    }

    func startSplit() {
        guard !isSplitting else { return }
        let source = splitSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = splitFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !folder.isEmpty else {
            splitStatus = L.t("Choose a source file and a destination folder.")
            return
        }
        let sourceURL = URL(fileURLWithPath: source)
        let folderURL = URL(fileURLWithPath: folder)
        let total = DiskCloner.size(of: sourceURL)
        guard total > 0 else {
            splitStatus = L.t("The source is empty or unreadable.")
            return
        }

        let partSize: Int64
        switch splitMode {
        case .bySize:
            partSize = max(1, splitPartSize)
        case .byCount:
            let count = Int(splitPartCountText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            guard count >= 1 else {
                splitStatus = L.t("Enter a part count of at least 1.")
                return
            }
            partSize = (total + Int64(count) - 1) / Int64(count)
        }

        let base = splitBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let job = FileTools.Job()
        splitJob = job
        isSplitting = true
        splitProgress = 0
        splitTotalBytes = total
        splitStatus = L.t("Splitting…")
        statusMessage = L.f("Splitting %@…", sourceURL.lastPathComponent)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let parts = try FileTools.split(
                    source: sourceURL,
                    folder: folderURL,
                    baseName: base.isEmpty ? sourceURL.deletingPathExtension().lastPathComponent : base,
                    partSize: partSize,
                    job: job
                ) { done, total in
                    DispatchQueue.main.async {
                        self?.splitProgress = total > 0 ? Double(done) / Double(total) : 0
                    }
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isSplitting = false
                    self.splitProgress = 1
                    self.splitStatus = L.f("Split into %d part(s): ", parts.count)
                        + parts.prefix(3).map { $0.url.lastPathComponent }.joined(separator: ", ")
                        + (parts.count > 3 ? "…" : "")
                    self.statusMessage = L.f("Split complete: %d part(s)", parts.count)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isSplitting = false
                    self.splitStatus = error.localizedDescription
                    self.statusMessage = L.f("Split failed: %@", error.localizedDescription)
                }
            }
        }
    }

    func cancelSplit() {
        splitJob?.cancel()
        splitStatus = L.t("Cancelling…")
    }

    // MARK: Join

    func chooseJoinFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L.t("Choose the folder containing the parts")
        if panel.runModal() == .OK, let url = panel.url {
            joinInputFolder = url.path
            scanJoinFolder()
        }
    }

    func scanJoinFolder() {
        let folder = joinInputFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty else { joinStatus = L.t("Choose a folder of parts."); return }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: folder),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            joinStatus = L.t("Cannot read the folder.")
            return
        }
        joinFilePaths = items
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false }
            .map { $0.path }
            .sorted { ($0 as NSString).lastPathComponent < ($1 as NSString).lastPathComponent }
        joinStatus = joinFilePaths.isEmpty ? L.t("No files found in the folder.") : L.f("%d file(s) queued.", joinFilePaths.count)
    }

    func chooseJoinParts() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = L.t("Choose the parts to join, in order")
        panel.directoryURL = joinInputFolder.isEmpty ? nil : URL(fileURLWithPath: joinInputFolder)
        if panel.runModal() == .OK {
            joinFilePaths.append(contentsOf: panel.urls.map { $0.path })
            joinStatus = L.f("%d file(s) queued.", joinFilePaths.count)
        }
    }

    func clearJoinParts() {
        joinFilePaths.removeAll()
        joinStatus = ""
    }

    func chooseJoinDestination() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "joined.bin"
        panel.message = L.t("Choose the output file")
        if panel.runModal() == .OK, let url = panel.url { joinDestination = url.path }
    }

    func startJoin() {
        guard !isJoining else { return }
        let destination = joinDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else { joinStatus = L.t("Choose a destination file."); return }
        guard !joinFilePaths.isEmpty else { joinStatus = L.t("Add parts to join first."); return }

        let parts = joinFilePaths.map { URL(fileURLWithPath: $0) }
        let destURL = URL(fileURLWithPath: destination)
        let job = FileTools.Job()
        joinJob = job
        isJoining = true
        joinProgress = 0
        joinTotalBytes = parts.reduce(Int64(0)) { $0 + DiskCloner.size(of: $1) }
        joinStatus = L.t("Joining…")
        statusMessage = L.f("Joining %d part(s)…", parts.count)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let written = try FileTools.join(
                    parts: parts,
                    destination: destURL,
                    job: job
                ) { done, total in
                    DispatchQueue.main.async {
                        self?.joinProgress = total > 0 ? Double(done) / Double(total) : 0
                    }
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isJoining = false
                    self.joinProgress = 1
                    self.joinStatus = L.f("Joined %d part(s) → %@.", parts.count, self.byteCountString(Int(written)))
                    self.statusMessage = L.f("Join complete: %@", destURL.lastPathComponent)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isJoining = false
                    self.joinStatus = error.localizedDescription
                    self.statusMessage = L.f("Join failed: %@", error.localizedDescription)
                }
            }
        }
    }

    func cancelJoin() {
        joinJob?.cancel()
        joinStatus = L.t("Cancelling…")
    }

    // MARK: - Helpers

    func byteCountString(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(count))
    }
}