import Foundation

/// How the query text is read.
enum SearchPatternKind: String, CaseIterable, Identifiable {
    case hex  = "Hex Bytes"
    case text = "Text"

    var id: String { rawValue }
}

/// Which way "find next" walks.
enum SearchDirection: String, CaseIterable, Identifiable {
    case forward  = "Down"
    case backward = "Up"

    var id: String { rawValue }
}

/// Everything the search dialog collects, handed to the engine as-is.
struct SearchOptions {
    var kind: SearchPatternKind = .hex
    var hexText = ""
    var text = ""
    var caseInsensitive = true
    /// WinHex-style wildcard byte: every occurrence of this value matches anything.
    var wildcardByte: UInt8? = nil
    var direction: SearchDirection = .forward
    var selectionOnly = false
    /// "offset mod [modulus] = [remainder]". `modulus == nil` disables the filter.
    var alignmentModulus: Int? = nil
    var alignmentRemainder = 0
    /// Stop after this many recorded hits. `0` means unlimited.
    var maxResults = 0
}

/// A single match, ordered by offset.
struct SearchHit: Identifiable, Hashable {
    let offset: Int

    var id: Int { offset }
}

/// The pure scanning logic behind the search panel. It only ever reads from the
/// document through `HexDocument.bytes(in:)`, so it sees edited bytes exactly
/// like the hex view does, and it never copies the whole document into memory —
/// which matters when the target is a multi-terabyte raw device.
enum SearchEngine {

    /// Turns the dialog options into a byte pattern, or `nil` when unusable.
    static func makePattern(_ options: SearchOptions) -> BytePattern? {
        switch options.kind {
        case .text:
            guard !options.text.isEmpty else { return nil }
            return BytePattern.parseText(options.text, caseSensitive: !options.caseInsensitive)
        case .hex:
            guard let parsed = BytePattern.parseHex(options.hexText) else { return nil }
            guard let wildcard = options.wildcardByte else { return parsed }
            return BytePattern(bytes: parsed.bytes.map { byte -> UInt8? in
                byte == wildcard ? nil : byte
            })
        }
    }

    /// Scans `range` for every match and returns the offsets in ascending order.
    ///
    /// The document is walked in overlapping windows (`patternLength - 1` bytes
    /// of overlap) so matches that straddle a window boundary are still seen.
    /// `limit > 0` stops the scan as soon as that many hits have been recorded.
    /// `progress` receives the 0…1 fraction, the absolute offset the scan has
    /// reached, and how many hits have been recorded so far — the latter two
    /// feed the WinHex-style progress window. `isCancelled` is polled between
    /// windows so a long scan can be aborted.
    @discardableResult
    static func findAll(pattern: BytePattern,
                        document: HexDocument,
                        in range: Range<Int>,
                        options: SearchOptions,
                        limit: Int,
                        progress: ((_ fraction: Double, _ scannedOffset: Int, _ hitCount: Int) -> Void)? = nil,
                        isCancelled: (() -> Bool)? = nil) -> [Int] {
        let length = pattern.count
        guard length > 0 else { return [] }

        let low = max(0, range.lowerBound)
        let high = min(document.size, range.upperBound)
        guard high - low >= length else { return [] }

        var results: [Int] = []
        let window = 1 << 20
        let span = max(1, high - low)
        var position = low

        while position < high {
            if isCancelled?() == true { break }

            let windowEnd = min(high, position + window + length - 1)
            let buffer = document.bytes(in: position..<windowEnd)
            let isFinalWindow = windowEnd >= high

            if buffer.count >= length {
                var index = 0
                let lastStart = buffer.count - length
                while index <= lastStart {
                    if pattern.matches(buffer, at: index) {
                        // Skip duplicates that the window overlap would resurface.
                        let absolute = position + index
                        if (absolute < position + window || isFinalWindow),
                           fitsAlignment(absolute, options: options) {
                            results.append(absolute)
                            if limit > 0 && results.count >= limit { return results }
                        }
                    }
                    index += 1
                }
            }

            if isFinalWindow { break }
            position += window
            progress?(Double(position - low) / Double(span), position, results.count)
        }

        progress?(1, high, results.count)
        return results
    }

    private static func fitsAlignment(_ offset: Int, options: SearchOptions) -> Bool {
        guard let modulus = options.alignmentModulus, modulus > 0 else { return true }
        return offset % modulus == options.alignmentRemainder
    }

    /// Walks `range` backwards and returns the highest matching offset, or `nil`.
    ///
    /// Used for "find previous" so a multi-gigabyte device never has to assemble
    /// the full hit list just to look at its last element.
    static func findLast(pattern: BytePattern,
                         document: HexDocument,
                         in range: Range<Int>,
                         options: SearchOptions,
                         progress: ((_ fraction: Double, _ scannedOffset: Int, _ hitCount: Int) -> Void)? = nil,
                         isCancelled: (() -> Bool)? = nil) -> Int? {
        let length = pattern.count
        guard length > 0 else { return nil }

        let low = max(0, range.lowerBound)
        let high = min(document.size, range.upperBound)
        guard high - low >= length else { return nil }

        let window = 1 << 20
        var windowEnd = high

        while true {
            if isCancelled?() == true { return nil }

            let windowStart = max(low, windowEnd - window - (length - 1))
            let buffer = document.bytes(in: windowStart..<windowEnd)

            if buffer.count >= length {
                var index = buffer.count - length
                while index >= 0 {
                    if pattern.matches(buffer, at: index) {
                        let absolute = windowStart + index
                        if fitsAlignment(absolute, options: options) { return absolute }
                    }
                    index -= 1
                }
            }

            if windowStart <= low { break }
            windowEnd = windowStart + (length - 1)
            progress?(Double(high - windowEnd) / Double(high - low), windowEnd, 0)
        }

        progress?(1, low, 0)
        return nil
    }
}
