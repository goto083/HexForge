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
    @Published var showGoto = false
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
    @Published var showInspector = true

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
        statusMessage = "Selected \(size) bytes"
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
        statusMessage = "Deleted \(range.count) byte(s)"
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
        statusMessage = "Inserted \(bytes.count) byte(s)"
        scrollToken &+= 1
        bump()
    }

    /// Parses a hex string (e.g. "DE AD BE EF") and inserts it at the cursor.
    func insertHex(_ text: String) {
        guard !document.isReadOnly else { return }
        guard let pattern = BytePattern.parseHex(text), !pattern.bytes.isEmpty else {
            statusMessage = "Enter hex bytes to insert (e.g. DE AD BE EF)"
            return
        }
        insertBytes(pattern.bytes.map { $0 ?? 0x00 })
    }

    func insertFromClipboard() {
        guard !document.isReadOnly else { return }
        guard let text = NSPasteboard.general.string(forType: .string) else {
            statusMessage = "Clipboard is empty"
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
        statusMessage = "Filled \(range.count) byte(s) with 0x" + String(format: "%02X", value)
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
        statusMessage = "Copied \(bytes.count) byte(s)"
    }

    func cut() {
        guard size > 0, !document.isReadOnly else { return }
        let count = selectionLength
        copy()
        deleteSelection()
        statusMessage = "Cut \(count) byte(s)"
    }

    func paste() {
        guard !document.isReadOnly else { return }
        guard size > 0 else { statusMessage = "Nothing to paste into — the file is empty."; return }
        guard let text = NSPasteboard.general.string(forType: .string) else {
            statusMessage = "Clipboard is empty"
            return
        }
        let bytes: [UInt8]
        if activePane == .ascii {
            bytes = Array(text.utf8)
        } else if let pattern = BytePattern.parseHex(text.isEmpty ? "" : text) {
            bytes = pattern.bytes.map { $0 ?? 0x00 }
        } else {
            statusMessage = "Clipboard is not valid hex"
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
        statusMessage = "Pasted \(written) byte(s)"
        bump()
    }

    // MARK: - Undo / redo

    func undo() {
        guard document.canUndo else { statusMessage = "Nothing to undo"; return }
        document.undo()
        clampPositionAfterStructuralEdit()
        statusMessage = "Undo"
        scrollToken &+= 1
        bump()
    }

    func redo() {
        guard document.canRedo else { statusMessage = "Nothing to redo"; return }
        document.redo()
        clampPositionAfterStructuralEdit()
        statusMessage = "Redo"
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
        guard let pattern = currentPattern() else { statusMessage = "Invalid search pattern"; return }
        let start = cursor + 1
        if start < size {
            let hits = Finder.findAll(pattern: pattern, document: document, in: start..<size, limit: 1)
            if let hit = hits.first { selectMatch(at: hit, length: pattern.count); return }
        }
        // wrap
        let all = Finder.findAll(pattern: pattern, document: document, in: 0..<size, limit: 1)
        if let hit = all.first {
            selectMatch(at: hit, length: pattern.count)
            statusMessage = "Match at 0x\(String(hit, radix: 16).uppercased()) (wrapped)"
        } else {
            statusMessage = "Not found"
        }
    }

    func findPrevious() {
        guard let pattern = currentPattern() else { statusMessage = "Invalid search pattern"; return }
        var start = cursor
        if start <= 0 { start = size }
        var hits = Finder.findAll(pattern: pattern, document: document, in: 0..<start)
        if hits.isEmpty {
            hits = Finder.findAll(pattern: pattern, document: document, in: 0..<size)
            if let hit = hits.last {
                selectMatch(at: hit, length: pattern.count)
                statusMessage = "Match at 0x\(String(hit, radix: 16).uppercased()) (wrapped)"
            } else {
                statusMessage = "Not found"
            }
            return
        }
        if let hit = hits.last {
            selectMatch(at: hit, length: pattern.count)
        }
    }

    private func selectMatch(at offset: Int, length: Int) {
        anchor = offset
        cursor = min(offset + max(0, length - 1), max(0, size - 1))
        nibbleHigh = true
        statusMessage = "Match at 0x\(String(offset, radix: 16).uppercased())"
        scrollToken &+= 1
        bump()
    }

    func replaceAll() {
        guard size > 0, !document.isReadOnly else { return }
        guard let (pattern, replacement) = patternForReplace() else {
            statusMessage = "Invalid pattern or replacement length mismatch"
            return
        }
        let hits = Finder.findAll(pattern: pattern, document: document, in: 0..<size)
        guard !hits.isEmpty else { statusMessage = "Not found"; return }
        for hit in hits {
            for (k, byte) in replacement.enumerated() {
                guard document.contains(offset: hit + k) else { break }
                document.setByte(byte, at: hit + k)
            }
        }
        statusMessage = "Replaced \(hits.count) occurrence(s)"
        bump()
    }

    // MARK: - Hash

    func computeHashes(overSelection: Bool) {
        guard size > 0 else { return }
        let range = (overSelection && hasSelection) ? selectionRange : 0..<size
        hashScopeIsSelection = overSelection && hasSelection
        isHashing = true
        statusMessage = "Computing checksums…"

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
                self?.statusMessage = "Checksums computed"
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
        statisticsStatus = "Computing…"
        statusMessage = "Analysing byte frequencies…"

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
                let label = self.statisticsScopeIsSelection ? "selection" : "file"
                self.statisticsStatus = String(
                    format: "%d byte(s) analysed · %d distinct value(s) · entropy %.3f bits/byte",
                    result.totalBytes, result.distinctValues, result.entropy)
                self.statusMessage = "Byte statistics computed for \(label)"
                self.bump()
            }
        }
    }

    // MARK: - Bookmarks

    func addBookmarkAtCursor() {
        let name = "0x" + String(cursor, radix: 16).uppercased()
        bookmarks.append(Bookmark(offset: cursor, name: name))
        bookmarks.sort { $0.offset < $1.offset }
        statusMessage = "Bookmark added at \(name)"
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
        panel.message = "Choose a file (or navigate to /dev for a raw device)"
        panel.directoryURL = URL(fileURLWithPath: "/")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        document.load(url: url)
        clearCompare()
        cursor = 0; anchor = 0; nibbleHigh = true
        if let signature = detectFormat() {
            statusMessage = "Opened \(url.lastPathComponent) · \(signature.name)"
        } else {
            statusMessage = "Opened \(url.lastPathComponent) (\(byteCountString(document.size)))"
        }
        scrollToken &+= 1
        bump()
    }

    func openDevice() {
        let alert = NSAlert()
        alert.messageText = "Open Raw Device"
        alert.informativeText = "Enter an absolute device path, e.g. /dev/disk2 or /dev/rdisk2. Devices are opened read-only."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "/dev/rdisk2"
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let path = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        document.load(url: URL(fileURLWithPath: path))
        clearCompare()
        cursor = 0; anchor = 0
        let signature = detectFormat()
        if document.size == 0 {
            statusMessage = "Could not open \(path) (permission or unknown size)"
        } else if let signature {
            statusMessage = "Opened device \(path) · \(signature.name)"
        } else {
            statusMessage = "Opened device \(path) (\(byteCountString(document.size)))"
        }
        scrollToken &+= 1
        bump()
    }

    func save() {
        guard let url = document.url else { saveAs(); return }
        do {
            try document.save(to: url)
            statusMessage = "Saved \(url.lastPathComponent)"
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
        bump()
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.url?.lastPathComponent ?? "untitled.bin"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.save(to: url)
            statusMessage = "Saved \(url.lastPathComponent)"
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
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
        panel.message = "Choose a HexForge structure template file (.json)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let loaded = try TemplateLoader.load(from: url)
            customTemplates.append(contentsOf: loaded)
            statusMessage = "Loaded \(loaded.count) template(s) from \(url.lastPathComponent)"
        } catch {
            statusMessage = "Template load failed: \(error.localizedDescription)"
        }
    }

    func clearCustomTemplates() {
        guard !customTemplates.isEmpty else { return }
        customTemplates.removeAll()
        statusMessage = "Removed external templates"
    }

    // MARK: - Disk clone

    func chooseCloneSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a source file, or navigate to /dev for a raw device"
        panel.directoryURL = document.url?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/")
        if panel.runModal() == .OK, let url = panel.url { cloneSource = url.path }
    }

    func chooseCloneDevice() {
        let alert = NSAlert()
        alert.messageText = "Choose Source Device"
        alert.informativeText = "Enter a raw device path, e.g. /dev/rdisk2. Raw (r) devices read faster than buffered ones."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "/dev/rdisk2"
        alert.accessoryView = field
        alert.addButton(withTitle: "Use")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let path = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty { cloneSource = path }
    }

    func chooseCloneDestination() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clone.img"
        panel.message = "Choose a destination image file"
        if panel.runModal() == .OK, let url = panel.url { cloneDestination = url.path }
    }

    func startClone() {
        guard !isCloning else { return }
        let source = cloneSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = cloneDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !destination.isEmpty else {
            cloneStatus = "Enter both a source and a destination."
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
        cloneStatus = "Cloning…"
        statusMessage = "Cloning \(source)"

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
                            self.cloneStatus = "\(self.byteCountString(Int(done))) copied"
                        }
                    }
                }
                DispatchQueue.main.async {
                    self.isCloning = false
                    self.cloneProgress = 1
                    self.cloneStatus = options.verify ? "Clone written and verified." : "Clone complete."
                    self.statusMessage = "Clone complete: \(destination)"
                }
            } catch {
                DispatchQueue.main.async {
                    self.isCloning = false
                    self.cloneStatus = error.localizedDescription
                    self.statusMessage = "Clone failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func cancelClone() {
        cloner?.cancel()
        cloneStatus = "Cancelling…"
    }

    // MARK: - File compare

    func chooseCompareFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the file to compare with the open document"
        panel.directoryURL = document.url?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/")
        if panel.runModal() == .OK, let url = panel.url { comparePath = url.path }
    }

    func runCompare() {
        guard !isComparing else { return }
        let path = comparePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            compareSummary = "Choose a file to compare against."
            return
        }
        guard document.size > 0 else {
            compareSummary = "Open a file first."
            return
        }
        let other = URL(fileURLWithPath: path)
        let doc = document
        isComparing = true
        comparerCancelled = false
        compareSummary = "Comparing…"
        statusMessage = "Comparing \(fileName) with \(other.lastPathComponent)…"

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
                    self.statusMessage = "Compare done · \(result.totalDifferenceRuns) difference run(s)"
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
                    self.statusMessage = "Compare failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func cancelCompare() {
        comparerCancelled = true
        compareSummary = "Cancelling…"
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

    // MARK: - Encrypt / convert

    func applyTransform() {
        guard size > 0 else { transformStatus = "Open a file first."; return }
        guard !document.isReadOnly else { transformStatus = "Document is read-only."; return }
        if transformScopeIsSelection && !hasSelection {
            transformStatus = "Select bytes first, or choose “Whole file”."
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
            statusMessage = "Transform failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Disk imaging

    func chooseImageSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a source file, or navigate to /dev for a raw device"
        panel.directoryURL = document.url?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/")
        if panel.runModal() == .OK, let url = panel.url { imageSource = url.path }
    }

    func chooseImageDevice() {
        let alert = NSAlert()
        alert.messageText = "Choose Source Device"
        alert.informativeText = "Enter a raw device path, e.g. /dev/rdisk2. Raw (r) devices read faster than buffered ones."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "/dev/rdisk2"
        alert.accessoryView = field
        alert.addButton(withTitle: "Use")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let path = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty { imageSource = path }
    }

    func chooseImageDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for the image files"
        if panel.runModal() == .OK, let url = panel.url { imageDestinationFolder = url.path }
    }

    func startImage() {
        guard !isImaging else { return }
        let source = imageSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = imageDestinationFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !folder.isEmpty else {
            imageStatus = "Choose both a source and a destination folder."
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
        imageStatus = "Cancelling…"
    }

    private func runImageJob(source: URL, folder: URL, name: String, options: DiskImager.Options) {
        guard !isImaging else { return }
        let job = DiskImager.Job()
        imagerJob = job
        isImaging = true
        imageProgress = 0
        imageVerifyResult = ""
        imageTotalBytes = DiskCloner.size(of: source)
        imageStatus = "Imaging…"
        statusMessage = "Imaging \(source.lastPathComponent)"

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
                            self.imageStatus = "\(self.byteCountString(Int(done))) written"
                        }
                    }
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isImaging = false
                    self.imageProgress = 1
                    self.imageStatus = "Image complete · \(result.manifest.volumes.count) volume(s) · \(result.manifestURL.lastPathComponent)"
                    self.statusMessage = "Image written: \(result.manifestURL.path)"
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isImaging = false
                    self.imageStatus = error.localizedDescription
                    self.statusMessage = "Imaging failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func verifyImageFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image manifest (name.hfmeta.json)"
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
        imageVerifyResult = "Verifying…"
        statusMessage = "Verifying \(manifestURL.lastPathComponent)…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let report = try DiskImager.verifyImage(manifestURL: manifestURL, job: job) { _, _ in }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isImaging = false
                    if !report.hadChecksums {
                        self.imageVerifyResult = "Manifest has no checksums; \(report.blocksChecked) block(s) read but not compared."
                        self.statusMessage = "Verify: no checksums recorded"
                    } else if report.mismatches == 0 {
                        self.imageVerifyResult = "Verified: \(report.blocksChecked) block(s), all checksums match."
                        self.statusMessage = "Image verified OK"
                    } else {
                        let at = report.firstMismatchOffset.map { "0x" + String($0, radix: 16).uppercased() } ?? "?"
                        self.imageVerifyResult = "FAILED: \(report.mismatches) mismatch(es), first at \(at)."
                        self.statusMessage = "Image verification failed"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isImaging = false
                    self.imageVerifyResult = error.localizedDescription
                    self.statusMessage = "Verify failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Backup jobs

    func addBackupJob() {
        let source = imageSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = imageDestinationFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !folder.isEmpty else {
            imageStatus = "Set a source and destination folder before saving a backup job."
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
        statusMessage = "Backup job saved: \(job.name)"
    }

    func removeBackupJob(_ job: BackupJob) {
        backupJobs.removeAll { $0.id == job.id }
        saveBackupJobs()
        statusMessage = "Backup job removed"
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
            randomGenerateStatus = "Document is read-only."
            return
        }
        let count = parsedByteCount(randomGenerateCountText)
        guard count > 0 else {
            randomGenerateStatus = "Enter how many bytes to generate."
            return
        }
        guard count <= FileTools.maxGenerateBytes else {
            randomGenerateStatus = "At most \(byteCountString(FileTools.maxGenerateBytes)) per edit."
            return
        }
        if randomGenerateMode == .replaceSelection && !hasSelection {
            randomGenerateStatus = "Select bytes first, or choose another mode."
            return
        }

        let job = FileTools.Job()
        generateJob = job
        isGenerating = true
        generateProgress = 0
        randomGenerateStatus = "Generating \(byteCountString(count))…"
        statusMessage = "Generating random data…"

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
                    self.statusMessage = "Generate failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func cancelGenerate() {
        generateJob?.cancel()
        randomGenerateStatus = "Cancelling…"
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
        randomGenerateStatus = "Generated \(byteCountString(placed)) of random data."
        statusMessage = "Generated \(byteCountString(placed)) random byte(s)"
        scrollToken &+= 1
        bump()
    }

    // MARK: Split

    func chooseSplitSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the file to split"
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
        panel.message = "Choose a folder for the parts"
        if panel.runModal() == .OK, let url = panel.url { splitFolder = url.path }
    }

    func startSplit() {
        guard !isSplitting else { return }
        let source = splitSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = splitFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !folder.isEmpty else {
            splitStatus = "Choose a source file and a destination folder."
            return
        }
        let sourceURL = URL(fileURLWithPath: source)
        let folderURL = URL(fileURLWithPath: folder)
        let total = DiskCloner.size(of: sourceURL)
        guard total > 0 else {
            splitStatus = "The source is empty or unreadable."
            return
        }

        let partSize: Int64
        switch splitMode {
        case .bySize:
            partSize = max(1, splitPartSize)
        case .byCount:
            let count = Int(splitPartCountText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            guard count >= 1 else {
                splitStatus = "Enter a part count of at least 1."
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
        splitStatus = "Splitting…"
        statusMessage = "Splitting \(sourceURL.lastPathComponent)…"

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
                    self.splitStatus = "Split into \(parts.count) part(s): "
                        + parts.prefix(3).map { $0.url.lastPathComponent }.joined(separator: ", ")
                        + (parts.count > 3 ? "…" : "")
                    self.statusMessage = "Split complete: \(parts.count) part(s)"
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isSplitting = false
                    self.splitStatus = error.localizedDescription
                    self.statusMessage = "Split failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func cancelSplit() {
        splitJob?.cancel()
        splitStatus = "Cancelling…"
    }

    // MARK: Join

    func chooseJoinFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder containing the parts"
        if panel.runModal() == .OK, let url = panel.url {
            joinInputFolder = url.path
            scanJoinFolder()
        }
    }

    func scanJoinFolder() {
        let folder = joinInputFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty else { joinStatus = "Choose a folder of parts."; return }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: folder),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            joinStatus = "Cannot read the folder."
            return
        }
        joinFilePaths = items
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false }
            .map { $0.path }
            .sorted { ($0 as NSString).lastPathComponent < ($1 as NSString).lastPathComponent }
        joinStatus = joinFilePaths.isEmpty ? "No files found in the folder." : "\(joinFilePaths.count) file(s) queued."
    }

    func chooseJoinParts() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose the parts to join, in order"
        panel.directoryURL = joinInputFolder.isEmpty ? nil : URL(fileURLWithPath: joinInputFolder)
        if panel.runModal() == .OK {
            joinFilePaths.append(contentsOf: panel.urls.map { $0.path })
            joinStatus = "\(joinFilePaths.count) file(s) queued."
        }
    }

    func clearJoinParts() {
        joinFilePaths.removeAll()
        joinStatus = ""
    }

    func chooseJoinDestination() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "joined.bin"
        panel.message = "Choose the output file"
        if panel.runModal() == .OK, let url = panel.url { joinDestination = url.path }
    }

    func startJoin() {
        guard !isJoining else { return }
        let destination = joinDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else { joinStatus = "Choose a destination file."; return }
        guard !joinFilePaths.isEmpty else { joinStatus = "Add parts to join first."; return }

        let parts = joinFilePaths.map { URL(fileURLWithPath: $0) }
        let destURL = URL(fileURLWithPath: destination)
        let job = FileTools.Job()
        joinJob = job
        isJoining = true
        joinProgress = 0
        joinTotalBytes = parts.reduce(Int64(0)) { $0 + DiskCloner.size(of: $1) }
        joinStatus = "Joining…"
        statusMessage = "Joining \(parts.count) part(s)…"

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
                    self.joinStatus = "Joined \(parts.count) part(s) → \(self.byteCountString(Int(written)))."
                    self.statusMessage = "Join complete: \(destURL.lastPathComponent)"
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isJoining = false
                    self.joinStatus = error.localizedDescription
                    self.statusMessage = "Join failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func cancelJoin() {
        joinJob?.cancel()
        joinStatus = "Cancelling…"
    }

    // MARK: - Helpers

    func byteCountString(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(count))
    }
}