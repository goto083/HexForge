import Foundation

/// Chunked byte search that never loads the whole file at once.
enum Finder {

    /// Finds matches whose start offset lies within `range`, scanning forward.
    /// Stops early once `limit` matches are collected.
    static func findAll(pattern: BytePattern,
                        document: HexDocument,
                        in range: Range<Int>,
                        limit: Int = 200_000) -> [Int] {
        let m = pattern.count
        guard m > 0 else { return [] }

        let size = document.size
        let lo = max(0, range.lowerBound)
        let hi = min(size, range.upperBound)
        guard hi - lo >= m else { return [] }

        var results: [Int] = []
        let chunk = 1 << 20
        var pos = lo

        while pos < hi {
            // Overlap by m-1 bytes so matches spanning a chunk boundary are found.
            let windowEnd = min(hi, pos + chunk + m - 1)
            let buffer = document.bytes(in: pos..<windowEnd)
            let isLastWindow = windowEnd >= hi

            if buffer.count >= m {
                var i = 0
                while i <= buffer.count - m {
                    if pattern.matches(buffer, at: i) {
                        let absolute = pos + i
                        // In non-final windows only accept matches starting inside
                        // this window's own chunk, so boundary matches are not
                        // reported twice.
                        if absolute < pos + chunk || isLastWindow {
                            results.append(absolute)
                            if results.count >= limit { return results }
                        }
                    }
                    i += 1
                }
            }

            if isLastWindow { break }
            pos += chunk
        }
        return results
    }
}