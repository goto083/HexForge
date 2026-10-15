import Foundation

/// One byte value's frequency within the analysed range.
struct ByteFrequency: Identifiable {
    let value: UInt8
    let count: Int
    /// Fraction of the total, 0…1.
    let fraction: Double
    var id: UInt8 { value }
}

/// Result of a byte-frequency analysis over a file range.
struct ByteStatistics {
    /// Occurrence count for each of the 256 byte values (index = byte value).
    let counts: [Int]
    let totalBytes: Int
    /// Shannon entropy in bits per byte (0…8).
    let entropy: Double

    static let empty = ByteStatistics(counts: [Int](repeating: 0, count: 256),
                                      totalBytes: 0,
                                      entropy: 0)

    var distinctValues: Int { counts.reduce(0) { $0 + ($1 > 0 ? 1 : 0) } }
    var maxCount: Int { counts.max() ?? 0 }

    func frequency(of value: UInt8) -> ByteFrequency {
        let c = counts[Int(value)]
        return ByteFrequency(value: value,
                             count: c,
                             fraction: totalBytes > 0 ? Double(c) / Double(totalBytes) : 0)
    }

    /// The `limit` byte values with the highest counts, in descending order.
    func mostFrequent(limit: Int = 10) -> [ByteFrequency] {
        counts.enumerated()
            .sorted { $0.element > $1.element }
            .prefix(limit)
            .map { ByteFrequency(value: UInt8($0.offset),
                                 count: $0.element,
                                 fraction: totalBytes > 0 ? Double($0.element) / Double(totalBytes) : 0) }
    }

    func fraction(for value: Int) -> Double {
        guard totalBytes > 0, counts.indices.contains(value) else { return 0 }
        return Double(counts[value]) / Double(totalBytes)
    }

    /// Relative intensity 0…1, used to shade the histogram cells.
    func intensity(for value: Int) -> Double {
        guard maxCount > 0, counts.indices.contains(value) else { return 0 }
        return Double(counts[value]) / Double(maxCount)
    }
}

enum ByteStatisticsService {

    /// Streams `size` bytes starting at `base` through a frequency counter.
    /// `reader` receives absolute ranges and returns the corresponding bytes, so
    /// multi-GB images are analysed with a constant memory footprint.
    static func compute(size: Int,
                        base: Int,
                        reader: (Range<Int>) -> [UInt8]) -> ByteStatistics {
        var counts = [Int](repeating: 0, count: 256)
        guard size > 0 else { return .empty }

        let chunk = 1 << 20
        var offset = base
        let end = base + size
        while offset < end {
            let n = min(chunk, end - offset)
            for b in reader(offset..<(offset + n)) { counts[Int(b)] += 1 }
            offset += n
        }

        let total = counts.reduce(0, +)
        var entropy = 0.0
        if total > 0 {
            for c in counts where c > 0 {
                let p = Double(c) / Double(total)
                entropy -= p * log2(p)
            }
        }
        return ByteStatistics(counts: counts, totalBytes: total, entropy: entropy)
    }
}
