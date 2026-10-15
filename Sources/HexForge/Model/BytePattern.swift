import Foundation

/// A search pattern: each element is either a concrete byte or `nil` (wildcard, `??`).
struct BytePattern {

    let bytes: [UInt8?]
    var caseInsensitive = false

    var count: Int { bytes.count }
    var isEmpty: Bool { bytes.isEmpty }

    func matches(_ buffer: [UInt8], at index: Int) -> Bool {
        guard index >= 0, index + bytes.count <= buffer.count else { return false }
        for (k, expected) in bytes.enumerated() {
            guard let expected else { continue }          // wildcard
            let actual = buffer[index + k]
            if caseInsensitive {
                if Self.lower(actual) != Self.lower(expected) { return false }
            } else if actual != expected {
                return false
            }
        }
        return true
    }

    private static func lower(_ b: UInt8) -> UInt8 {
        (b >= 0x41 && b <= 0x5A) ? b + 0x20 : b
    }

    // MARK: - Parsing

    /// Parses a hex string such as "4D 5A ?? 00" or "4d5a??00". `??` is a wildcard.
    static func parseHex(_ raw: String) -> BytePattern? {
        var cleaned = raw.lowercased()
        for token in [" ", "\t", "\n", "\r", "0x", ",", "-", ":"] {
            cleaned = cleaned.replacingOccurrences(of: token, with: "")
        }
        guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }

        var out: [UInt8?] = []
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            let pair = String(cleaned[idx..<next])
            if pair == "??" {
                out.append(nil)
            } else if let value = UInt8(pair, radix: 16) {
                out.append(value)
            } else {
                return nil
            }
            idx = next
        }
        return BytePattern(bytes: out)
    }

    /// Parses a text string, encoded as UTF-8 bytes.
    static func parseText(_ text: String, caseSensitive: Bool) -> BytePattern? {
        guard !text.isEmpty else { return nil }
        var pattern = BytePattern(bytes: Array(text.utf8).map { Optional($0) })
        pattern.caseInsensitive = !caseSensitive
        return pattern
    }
}