import Foundation

struct InterpretedValue: Identifiable {
    let id = UUID()
    let name: String
    let value: String
    /// Number of bytes actually used for this interpretation.
    let length: Int
}

/// Interprets the leading bytes at a position as common scalar types.
enum DataInterpreter {

    static func interpret(_ buffer: [UInt8]) -> [InterpretedValue] {
        var out: [InterpretedValue] = []

        if buffer.count >= 1 {
            let b = buffer[0]
            out.append(.init(name: "Byte (hex)", value: String(format: "%02X", b), length: 1))
            out.append(.init(name: "Int8", value: String(Int8(bitPattern: b)), length: 1))
            out.append(.init(name: "UInt8", value: String(b), length: 1))
            out.append(.init(name: "Char", value: printable(b), length: 1))
        }
        if buffer.count >= 2 {
            out.append(.init(name: "Int16 LE", value: String(Int16(bitPattern: UInt16(truncatingIfNeeded: le(buffer, 2)))), length: 2))
            out.append(.init(name: "Int16 BE", value: String(Int16(bitPattern: UInt16(truncatingIfNeeded: be(buffer, 2)))), length: 2))
            out.append(.init(name: "UInt16 LE", value: String(UInt16(truncatingIfNeeded: le(buffer, 2))), length: 2))
            out.append(.init(name: "UInt16 BE", value: String(UInt16(truncatingIfNeeded: be(buffer, 2))), length: 2))
        }
        if buffer.count >= 3 {
            let raw24le = UInt32(truncatingIfNeeded: le(buffer, 3))
            let signed24le = (raw24le & 0x800000) != 0 ? (raw24le | 0xFF00_0000) : raw24le
            out.append(.init(name: "Int24 LE", value: String(Int32(bitPattern: signed24le)), length: 3))
            let raw24be = UInt32(truncatingIfNeeded: be(buffer, 3))
            let signed24be = (raw24be & 0x800000) != 0 ? (raw24be | 0xFF00_0000) : raw24be
            out.append(.init(name: "Int24 BE", value: String(Int32(bitPattern: signed24be)), length: 3))
        }
        if buffer.count >= 4 {
            let u32le = UInt32(truncatingIfNeeded: le(buffer, 4))
            let u32be = UInt32(truncatingIfNeeded: be(buffer, 4))
            out.append(.init(name: "Int32 LE", value: String(Int32(bitPattern: u32le)), length: 4))
            out.append(.init(name: "Int32 BE", value: String(Int32(bitPattern: u32be)), length: 4))
            out.append(.init(name: "UInt32 LE", value: String(u32le), length: 4))
            out.append(.init(name: "UInt32 BE", value: String(u32be), length: 4))
            out.append(.init(name: "Float32 LE", value: formatFloat(Float(bitPattern: u32le)), length: 4))
            out.append(.init(name: "Float32 BE", value: formatFloat(Float(bitPattern: u32be)), length: 4))
            out.append(.init(name: "Unix time (32 LE)", value: formatUnix(UInt64(u32le)), length: 4))
        }
        if buffer.count >= 8 {
            let u64le = le(buffer, 8)
            let u64be = be(buffer, 8)
            out.append(.init(name: "Int64 LE", value: String(Int64(bitPattern: u64le)), length: 8))
            out.append(.init(name: "Int64 BE", value: String(Int64(bitPattern: u64be)), length: 8))
            out.append(.init(name: "UInt64 LE", value: String(u64le), length: 8))
            out.append(.init(name: "UInt64 BE", value: String(u64be), length: 8))
            out.append(.init(name: "Double LE", value: formatDouble(Double(bitPattern: u64le)), length: 8))
            out.append(.init(name: "Double BE", value: formatDouble(Double(bitPattern: u64be)), length: 8))
            out.append(.init(name: "Filetime (64 LE)", value: formatFiletime(u64le), length: 8))
        }
        return out
    }

    // MARK: - Byte assembly

    static func le(_ b: [UInt8], _ n: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<min(n, b.count) {
            v |= UInt64(b[i]) << (8 * i)
        }
        return v
    }

    static func be(_ b: [UInt8], _ n: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<min(n, b.count) {
            v = (v << 8) | UInt64(b[i])
        }
        return v
    }

    // MARK: - Formatting

    private static func printable(_ b: UInt8) -> String {
        if b >= 0x20 && b < 0x7F { return "'\(Character(UnicodeScalar(b)))'" }
        return "."
    }

    private static func formatFloat(_ f: Float) -> String {
        f.isFinite ? String(format: "%g", Double(f)) : "\(f)"
    }

    private static func formatDouble(_ d: Double) -> String {
        d.isFinite ? String(format: "%g", d) : "\(d)"
    }

    private static let utcFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.timeZone = TimeZone(identifier: "UTC")
        return df
    }()

    private static func formatUnix(_ seconds: UInt64) -> String {
        guard seconds > 0, seconds < 4_102_444_800 else { return "—" }   // < year 2100
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        return utcFormatter.string(from: date) + " UTC"
    }

    /// Windows FILETIME: 100-ns intervals since 1601-01-01.
    private static func formatFiletime(_ value: UInt64) -> String {
        guard value > 0, value < 2_000_000_000_000_000_000 else { return "—" }
        let seconds = TimeInterval(value) / 10_000_000.0 - 11_644_473_600.0
        let date = Date(timeIntervalSince1970: seconds)
        return utcFormatter.string(from: date) + " UTC"
    }
}