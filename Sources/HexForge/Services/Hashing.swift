import Foundation
import CryptoKit

enum HashAlgorithm: String, CaseIterable, Identifiable {
    case crc32  = "CRC-32"
    case md5    = "MD5"
    case sha1   = "SHA-1"
    case sha256 = "SHA-256"

    var id: String { rawValue }
}

enum HashService {

    /// Streams `size` bytes starting at `base` through the chosen algorithm.
    /// `reader` receives absolute ranges and returns the corresponding bytes.
    static func compute(_ algorithm: HashAlgorithm,
                        size: Int,
                        base: Int,
                        reader: (Range<Int>) -> [UInt8]) -> String {
        guard size > 0 else { return emptyResult(algorithm) }

        let chunk = 1 << 20
        var offset = base
        let end = base + size

        switch algorithm {
        case .crc32:
            var crc: UInt32 = 0xFFFF_FFFF
            while offset < end {
                let n = min(chunk, end - offset)
                crc = CRC32.update(crc, reader(offset..<(offset + n)))
                offset += n
            }
            return String(format: "%08X", crc ^ 0xFFFF_FFFF)

        case .md5:
            var hasher = Insecure.MD5()
            while offset < end {
                let n = min(chunk, end - offset)
                hasher.update(data: Data(reader(offset..<(offset + n))))
                offset += n
            }
            return hex(hasher.finalize())

        case .sha1:
            var hasher = Insecure.SHA1()
            while offset < end {
                let n = min(chunk, end - offset)
                hasher.update(data: Data(reader(offset..<(offset + n))))
                offset += n
            }
            return hex(hasher.finalize())

        case .sha256:
            var hasher = SHA256()
            while offset < end {
                let n = min(chunk, end - offset)
                hasher.update(data: Data(reader(offset..<(offset + n))))
                offset += n
            }
            return hex(hasher.finalize())
        }
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func emptyResult(_ algorithm: HashAlgorithm) -> String {
        switch algorithm {
        case .crc32:  return "00000000"
        case .md5:    return String(repeating: "0", count: 32)
        case .sha1:   return String(repeating: "0", count: 40)
        case .sha256: return String(repeating: "0", count: 64)
        }
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func update(_ crc: UInt32, _ bytes: [UInt8]) -> UInt32 {
        var c = crc
        for b in bytes {
            c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
        }
        return c
    }
}