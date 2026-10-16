import SwiftUI
import AppKit

// MARK: - Colour palette

enum HexTheme {
    static let background   = NSColor(calibratedRed: 0.105, green: 0.115, blue: 0.135, alpha: 1)
    static let altRow       = NSColor(calibratedRed: 0.135, green: 0.148, blue: 0.170, alpha: 1)
    static let offsetText   = NSColor(calibratedRed: 0.44, green: 0.56, blue: 0.78, alpha: 1)
    static let hexText      = NSColor(calibratedWhite: 0.90, alpha: 1)
    static let asciiText    = NSColor(calibratedRed: 0.52, green: 0.83, blue: 0.60, alpha: 1)
    static let selection    = NSColor(calibratedRed: 0.19, green: 0.34, blue: 0.58, alpha: 1)
    static let diff         = NSColor(calibratedRed: 0.55, green: 0.16, blue: 0.16, alpha: 1)
    static let caret        = NSColor(calibratedRed: 0.98, green: 0.76, blue: 0.25, alpha: 1)
}

// MARK: - SwiftUI wrapper

struct HexEditorView: NSViewRepresentable {
    @EnvironmentObject var state: AppState

    final class Coordinator {
        var canvas: HexCanvasView?
        var lastScrollToken = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = HexTheme.background
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true

        let canvas = HexCanvasView()
        canvas.state = state
        scroll.documentView = canvas
        context.coordinator.canvas = canvas
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let canvas = context.coordinator.canvas else { return }
        canvas.state = state
        canvas.refresh()

        if state.scrollToken != context.coordinator.lastScrollToken {
            context.coordinator.lastScrollToken = state.scrollToken
            canvas.scrollToCursor()
        }
    }
}

// MARK: - Custom drawing view

final class HexCanvasView: NSView {

    weak var state: AppState?

    private let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    private lazy var charWidth: CGFloat = {
        ("0" as NSString).size(withAttributes: [.font: font]).width
    }()
    private lazy var lineHeight: CGFloat = {
        ceil(font.ascender - font.descender + font.leading)
    }()
    private lazy var rowHeight: CGFloat = lineHeight + 4

    /// Height of the column header band pinned to the top of the viewport.
    private var headerHeight: CGFloat { rowHeight + 2 }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Layout metrics

    private var bytesPerRow: Int { max(1, state?.bytesPerRow ?? 16) }
    private var showAscii: Bool { state?.showAscii ?? true }

    private var addressUnit: Int { max(1, state?.addressUnit ?? 1) }
    private var addressPrefix: String { state?.addressPrefix ?? "" }
    private var addressDigits: Int { max(8, state?.addressDigits ?? 8) }
    /// Decimal digits for the offset column (WinHex shows 10 digits).
    private var decimalDigits: Int {
        let units = max(1, (state?.size ?? 0) / addressUnit)
        return max(10, String(units).count)
    }
    /// Digit count actually used, depending on hex/decimal addressing.
    private var addressWidth: Int {
        state?.decimalAddress == true ? decimalDigits : addressDigits
    }
    private var offsetWidth: CGFloat { CGFloat(addressWidth + addressPrefix.count) * charWidth }
    private var hexOriginX: CGFloat { 12 + offsetWidth + charWidth * 2 }

    private func hexColumnX(_ column: Int) -> CGFloat {
        hexOriginX
            + CGFloat(column) * charWidth * 3
            + CGFloat(column / 8) * charWidth
    }
    private var asciiOriginX: CGFloat { hexColumnX(bytesPerRow) + charWidth * 2 }

    private var contentWidth: CGFloat {
        let width = showAscii
            ? asciiOriginX + CGFloat(bytesPerRow) * charWidth
            : hexColumnX(bytesPerRow)
        return max(width + 24, 240)
    }

    private var totalRows: Int {
        let size = state?.size ?? 0
        if size == 0 { return 1 }
        return (size + bytesPerRow - 1) / bytesPerRow
    }

    // MARK: Refresh

    func refresh() {
        let height = headerHeight + CGFloat(totalRows) * rowHeight + 6
        let visibleWidth = enclosingScrollView?.contentSize.width ?? contentWidth
        let width = max(contentWidth, visibleWidth)
        if abs(frame.width - width) > 0.5 || abs(frame.height - height) > 0.5 {
            setFrameSize(NSSize(width: width, height: height))
        }
        needsDisplay = true
        if let state {
            // Use the *viewport* height, not the document view height (which is the
            // whole file), otherwise Page Up/Down would step by the entire file.
            let viewportHeight = enclosingScrollView?.contentView.bounds.height ?? bounds.height
            state.visibleRows = max(1, Int(viewportHeight / rowHeight))
        }
    }

    func scrollToCursor() {
        guard let state else { return }
        let row = state.cursor / bytesPerRow
        if state.scrollCentered {
            // Jumps from the hit list / file system panel centre the target row
            // in the viewport so the surrounding bytes are readable.
            state.scrollCentered = false
            let viewportHeight = enclosingScrollView?.contentView.bounds.height ?? bounds.height
            var y = headerHeight + CGFloat(row) * rowHeight - (viewportHeight - rowHeight) / 2
            y = max(0, min(y, bounds.height - viewportHeight))
            scroll(NSPoint(x: 0, y: y))
            return
        }
        // Full-width rect keeps the caret vertically visible without resetting the
        // horizontal scroll position.
        let rect = NSRect(x: 0, y: headerHeight + CGFloat(row) * rowHeight,
                          width: max(1, bounds.width), height: rowHeight)
        scrollToVisible(rect)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
        }
        observeClipView()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// The column header is drawn at `visibleRect.minY` so it stays pinned while
    /// scrolling. Redraw the viewport whenever the clip view scrolls.
    private func observeClipView() {
        guard let clip = enclosingScrollView?.contentView else { return }
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: clip)
    }

    @objc private func clipBoundsChanged() {
        setNeedsDisplay(visibleRect)
    }

    // Reports the byte under the pointer so the file-system info panel can show
    // the current cluster, its owning file and the parent chain.

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil))
        observeClipView()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let headerTop = visibleRect.minY
        let inHeader = point.y >= headerTop && point.y < headerTop + headerHeight
        let newOffset: Int? = inHeader ? nil : offset(at: point)
        if state?.hoverOffset != newOffset {
            state?.hoverOffset = newOffset
        }
    }

    override func mouseExited(with event: NSEvent) {
        state?.hoverOffset = nil
    }

    // Redraw the caret whenever the canvas gains or loses focus so it does not
    // linger after the window loses key status.
    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        HexTheme.background.setFill()
        bounds.fill()

        guard let state else { return }
        let document = state.document

        let rh = rowHeight
        let header = headerHeight
        let firstRow = max(0, Int(floor((dirtyRect.minY - header) / rh)))
        let lastRow = min(totalRows - 1, Int(ceil((dirtyRect.maxY - header) / rh)))

        let hasSelection = state.hasSelection
        let selLo = hasSelection ? min(state.cursor, state.anchor) : -1
        let selHi = hasSelection ? max(state.cursor, state.anchor) : -1

        for row in firstRow..<max(firstRow, lastRow + 1) {
            let y = header + CGFloat(row) * rh
            let base = row * bytesPerRow

            if row % 2 == 1 {
                HexTheme.altRow.setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: rh).fill()
            }

            // Mark sector (and more strongly, cluster) boundaries. The parsed
            // file system's geometry wins over the manual sector/cluster sizing.
            let sectorStep = state.fsSectorSize > 0
                ? state.fsSectorSize
                : (state.addressMode != .fileOffset ? state.sectorSize : 0)
            let clusterStep = state.fsClusterSize > 0
                ? state.fsClusterSize
                : (state.addressMode != .fileOffset ? state.clusterSize : 0)
            if row > 0, sectorStep > 0, base % sectorStep == 0 {
                let isClusterStart = clusterStep > 0 && base % clusterStep == 0
                NSColor(calibratedWhite: 1.0, alpha: isClusterStart ? 0.35 : 0.16).setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: isClusterStart ? 2 : 1).fill()
            }

            // Highlight bytes that differ from the comparison file.
            if !state.compareDiffOffsets.isEmpty {
                for column in 0..<bytesPerRow {
                    let offset = base + column
                    guard offset < state.size, state.compareDiffOffsets.contains(offset) else { continue }
                    HexTheme.diff.setFill()
                    NSRect(x: hexColumnX(column) - 1, y: y, width: charWidth * 2 + 2, height: rh).fill()
                    if showAscii {
                        NSRect(x: asciiOriginX + CGFloat(column) * charWidth, y: y, width: charWidth, height: rh).fill()
                    }
                }
            }

            if hasSelection {
                for column in 0..<bytesPerRow {
                    let offset = base + column
                    guard offset >= selLo, offset <= selHi else { continue }
                    HexTheme.selection.setFill()
                    NSRect(x: hexColumnX(column) - 1, y: y, width: charWidth * 2 + 2, height: rh).fill()
                    if showAscii {
                        NSRect(x: asciiOriginX + CGFloat(column) * charWidth, y: y, width: charWidth, height: rh).fill()
                    }
                }
            }

            let count = min(bytesPerRow, max(0, (state.size - base)))
            let rowBytes = count > 0 ? document.bytes(in: base..<(base + count)) : []

            let offsetString = addressText(base)
            draw(offsetString, x: 12, y: y, color: HexTheme.offsetText)
            draw(hexString(rowBytes, total: bytesPerRow), x: hexOriginX, y: y, color: HexTheme.hexText)
            if showAscii {
                draw(asciiString(rowBytes, total: bytesPerRow), x: asciiOriginX, y: y, color: HexTheme.asciiText)
            }
        }

        drawCaret()
        drawHeader()
    }

    /// Renders the pinned column header: the clickable "Offset" label followed by
    /// the per-byte column numbers (0-F in hex, 0-15 in decimal).
    private func drawHeader() {
        guard let state else { return }
        let top = visibleRect.minY
        let h = headerHeight

        HexTheme.altRow.setFill()
        NSRect(x: 0, y: top, width: bounds.width, height: h).fill()
        HexTheme.offsetText.withAlphaComponent(0.45).setFill()
        NSRect(x: 0, y: top + h - 1, width: bounds.width, height: 1).fill()

        let label = state.decimalAddress ? L.t("Decimal") : L.t("Offset")
        draw(label, x: 12, y: top, color: HexTheme.caret)
        for column in 0..<bytesPerRow {
            let text = state.decimalAddress
                ? String(column)
                : String(column, radix: 16, uppercase: true)
            draw(text, x: hexColumnX(column), y: top, color: HexTheme.offsetText)
        }
    }

    private func addressText(_ byteOffset: Int) -> String {
        let value = byteOffset / addressUnit
        if state?.decimalAddress == true {
            return addressPrefix + paddedDecimal(value, width: decimalDigits)
        }
        return addressPrefix + paddedHex(value, width: addressDigits)
    }

    private func draw(_ string: String, x: CGFloat, y: CGFloat, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        (string as NSString).draw(at: NSPoint(x: x, y: y + 2), withAttributes: attributes)
    }

    private func paddedHex(_ value: Int, width: Int) -> String {
        var s = String(value, radix: 16, uppercase: true)
        while s.count < width { s = "0" + s }
        return s
    }

    private func paddedDecimal(_ value: Int, width: Int) -> String {
        var s = String(max(0, value))
        while s.count < width { s = "0" + s }
        return s
    }

    private func hexString(_ bytes: [UInt8], total: Int) -> String {
        var s = ""
        for column in 0..<total {
            if column < bytes.count {
                s += String(format: "%02X", bytes[column])
            } else {
                s += "  "
            }
            if column != total - 1 {
                s += " "
                if (column + 1) % 8 == 0 { s += " " }
            }
        }
        return s
    }

    private func asciiString(_ bytes: [UInt8], total: Int) -> String {
        var s = ""
        for column in 0..<total {
            if column < bytes.count {
                let b = bytes[column]
                s += (b >= 0x20 && b < 0x7F) ? String(UnicodeScalar(b)) : "."
            } else {
                s += " "
            }
        }
        return s
    }

    private func drawCaret() {
        guard let state, state.size > 0, window?.firstResponder === self else { return }
        let row = state.cursor / bytesPerRow
        let column = state.cursor % bytesPerRow
        let y = headerHeight + CGFloat(row) * rowHeight

        let rect: NSRect
        if state.activePane == .hex {
            rect = NSRect(x: hexColumnX(column) - 1, y: y + 0.5, width: charWidth * 2 + 2, height: rowHeight - 1)
        } else {
            rect = NSRect(x: asciiOriginX + CGFloat(column) * charWidth, y: y + 0.5, width: charWidth, height: rowHeight - 1)
        }
        HexTheme.caret.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1.5
        path.stroke()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)

        // Clicking the fixed "Offset" label toggles hex/decimal addressing.
        let headerTop = visibleRect.minY
        if point.y >= headerTop, point.y < headerTop + headerHeight {
            if point.x < hexOriginX, let state {
                state.decimalAddress.toggle()
                needsDisplay = true
            }
            return
        }

        state?.activePane = point.x >= asciiOriginX && showAscii ? .ascii : .hex
        state?.setCursor(offset(at: point), extend: event.modifierFlags.contains(.shift))
        autoscroll(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        state?.setCursor(offset(at: point), extend: true)
        autoscroll(with: event)
    }

    private func offset(at point: NSPoint) -> Int {
        let row = max(0, Int((point.y - headerHeight) / rowHeight))
        let base = row * bytesPerRow
        let size = state?.size ?? 0

        var column = 0
        if showAscii && point.x >= asciiOriginX {
            column = Int((point.x - asciiOriginX) / charWidth)
        } else if point.x >= hexOriginX {
            for c in 0..<bytesPerRow {
                if point.x >= hexColumnX(c) - charWidth * 0.5 { column = c } else { break }
            }
        }
        column = max(0, min(column, bytesPerRow - 1))
        let offset = base + column
        return max(0, min(offset, max(0, size - 1)))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        state?.handleKey(event)
    }

    // MARK: Standard edit actions (routed from the Edit menu)

    @objc(cut:) func hexCut(_ sender: Any?) { state?.cut() }
    @objc(copy:) func hexCopy(_ sender: Any?) { state?.copy() }
    @objc(paste:) func hexPaste(_ sender: Any?) { state?.paste() }
    override func selectAll(_ sender: Any?) { state?.selectAll() }
}