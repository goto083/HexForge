import Foundation
import CommonCrypto

/// Operations offered by the Encrypt / Convert panel.
enum TransformOperation: String, CaseIterable, Identifiable {
    case xorKey            = "XOR with key"
    case bitwiseAnd        = "AND with constant"
    case bitwiseOr         = "OR with constant"
    case bitwiseNot        = "NOT (invert bytes)"
    case addConstant       = "Add constant"
    case subtractConstant  = "Subtract constant"
    case reverseBytes      = "Reverse byte order"
    case swapWords         = "Byte-swap words"
    case base64Encode      = "Base64 encode"
    case base64Decode      = "Base64 decode"
    case rot13             = "ROT13 (text)"
    case aesECBEncrypt     = "AES encrypt"
    case aesECBDecrypt     = "AES decrypt"
    case desECBEncrypt     = "DES encrypt"
    case desECBDecrypt     = "DES decrypt"

    var id: String { rawValue }

    var usesKey: Bool {
        switch self {
        case .xorKey, .aesECBEncrypt, .aesECBDecrypt, .desECBEncrypt, .desECBDecrypt: return true
        default: return false
        }
    }

    var usesConstant: Bool {
        switch self {
        case .bitwiseAnd, .bitwiseOr, .addConstant, .subtractConstant: return true
        default: return false
        }
    }

    var usesWordSize: Bool { self == .swapWords }

    var isCipher: Bool {
        switch self {
        case .aesECBEncrypt, .aesECBDecrypt, .desECBEncrypt, .desECBDecrypt: return true
        default: return false
        }
    }

    var description: String {
        switch self {
        case .xorKey:           return "XORs every byte with a repeating key (hex or text)."
        case .bitwiseAnd:       return "ANDs every byte with the constant."
        case .bitwiseOr:        return "ORs every byte with the constant."
        case .bitwiseNot:       return "Inverts every bit of every selected byte."
        case .addConstant:      return "Adds the constant to every byte (mod 256)."
        case .subtractConstant: return "Subtracts the constant from every byte (mod 256)."
        case .reverseBytes:     return "Reverses the byte order of the whole range."
        case .swapWords:        return "Reverses the bytes inside each word (endianness swap)."
        case .base64Encode:     return "Encodes the bytes as Base64 text (length grows)."
        case .base64Decode:     return "Decodes Base64 text back to bytes (length shrinks)."
        case .rot13:            return "Rotates ASCII letters by 13 positions."
        case .aesECBEncrypt:    return "AES encrypt with PKCS#7 padding (ECB or CBC)."
        case .aesECBDecrypt:    return "AES decrypt; PKCS#7 padding is removed."
        case .desECBEncrypt:    return "DES encrypt with PKCS#7 padding (ECB or CBC)."
        case .desECBDecrypt:    return "DES decrypt; PKCS#7 padding is removed."
        }
    }
}

struct TransformRequest {
    var operation: TransformOperation
    var keyText: String = ""
    var keyIsHex: Bool = true
    var constantText: String = "FF"
    var wordSize: Int = 4
    /// true = ECB, false = CBC (uses `ivText`).
    var ecbMode: Bool = true
    var ivText: String = ""
}

struct TransformOutcome {
    let bytes: [UInt8]
    let message: String
}

enum TransformError: LocalizedError {
    case invalidKey(String)
    case invalidIV(String)
    case invalidConstant(String)
    case invalidBase64
    case cipherFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidKey(let detail):      return detail
        case .invalidIV(let detail):       return detail
        case .invalidConstant(let detail): return "Constant: \(detail)"
        case .invalidBase64:               return "Input is not valid Base64."
        case .cipherFailed(let status):    return "Cipher failed (status \(status))."
        }
    }
}

/// Pure byte transforms used by the Encrypt / Convert panel.
enum CryptoTransform {

    static func apply(_ request: TransformRequest, to input: [UInt8]) throws -> TransformOutcome {
        switch request.operation {
        case .xorKey:
            let key = try parseBytes(request.keyText, isHex: request.keyIsHex, what: "key")
            var out = input
            for i in out.indices { out[i] ^= key[i % key.count] }
            return TransformOutcome(bytes: out, message: "XORed \(input.count) byte(s) with a \(key.count)-byte key")

        case .bitwiseAnd, .bitwiseOr, .addConstant, .subtractConstant:
            let c = try parseConstant(request.constantText)
            var out = input
            for i in out.indices {
                switch request.operation {
                case .bitwiseAnd:       out[i] &= c
                case .bitwiseOr:        out[i] |= c
                case .addConstant:      out[i] = out[i] &+ c
                case .subtractConstant: out[i] = out[i] &- c
                default: break
                }
            }
            return TransformOutcome(bytes: out, message: "\(request.operation.rawValue) applied to \(input.count) byte(s)")

        case .bitwiseNot:
            return TransformOutcome(bytes: input.map { ~$0 }, message: "Inverted \(input.count) byte(s)")

        case .reverseBytes:
            return TransformOutcome(bytes: Array(input.reversed()), message: "Reversed \(input.count) byte(s)")

        case .swapWords:
            let word = max(1, request.wordSize)
            var out = input
            var start = 0
            while start + word <= out.count {
                let reversed = Array(out[start..<(start + word)].reversed())
                out.replaceSubrange(start..<(start + word), with: reversed)
                start += word
            }
            return TransformOutcome(bytes: out, message: "Byte-swapped \(word)-byte words")

        case .base64Encode:
            let text = Data(input).base64EncodedString()
            return TransformOutcome(bytes: Array(text.utf8), message: "Base64 encoded \(input.count) byte(s) → \(text.count) chars")

        case .base64Decode:
            let text = String(decoding: input, as: UTF8.self)
                .filter { !$0.isWhitespace }
            guard let data = Data(base64Encoded: text) else { throw TransformError.invalidBase64 }
            return TransformOutcome(bytes: [UInt8](data), message: "Base64 decoded \(input.count) char(s) → \(data.count) byte(s)")

        case .rot13:
            var out = input
            for i in out.indices {
                let b = out[i]
                if b >= 0x41, b <= 0x5A { out[i] = 0x41 + (b - 0x41 + 13) % 26 }
                else if b >= 0x61, b <= 0x7A { out[i] = 0x61 + (b - 0x61 + 13) % 26 }
            }
            return TransformOutcome(bytes: out, message: "ROT13 applied to \(input.count) byte(s)")

        case .aesECBEncrypt, .aesECBDecrypt, .desECBEncrypt, .desECBDecrypt:
            return try runCipher(request, input: input)
        }
    }

    // MARK: - Cipher

    private static func runCipher(_ request: TransformRequest, input: [UInt8]) throws -> TransformOutcome {
        let isAES = request.operation == .aesECBEncrypt || request.operation == .aesECBDecrypt
        let encrypt = request.operation == .aesECBEncrypt || request.operation == .desECBEncrypt

        let rawKey = try parseBytes(request.keyText, isHex: request.keyIsHex, what: "key")
        let key = normalize(rawKey, targets: isAES ? [16, 24, 32] : [8])

        var iv: [UInt8] = []
        if !request.ecbMode {
            let blockSize = isAES ? 16 : 8
            let rawIV = try parseBytes(request.ivText, isHex: true, what: "IV")
            iv = normalize(rawIV, targets: [blockSize])
        }

        let algorithm = CCAlgorithm(isAES ? kCCAlgorithmAES : kCCAlgorithmDES)
        let options = CCOptions(request.ecbMode ? kCCOptionECBMode | kCCOptionPKCS7Padding
                                                : kCCOptionPKCS7Padding)
        let op = CCOperation(encrypt ? kCCEncrypt : kCCDecrypt)
        let out = try crypt(op, algorithm: algorithm, options: options, key: key, iv: iv, input: input)
        let name = isAES ? "AES" : "DES"
        let mode = request.ecbMode ? "ECB" : "CBC"
        return TransformOutcome(bytes: out, message: "\(name)-\(mode) \(encrypt ? "encrypted" : "decrypted") \(input.count) → \(out.count) byte(s)")
    }

    private static func crypt(_ op: CCOperation,
                              algorithm: CCAlgorithm,
                              options: CCOptions,
                              key: [UInt8],
                              iv: [UInt8],
                              input: [UInt8]) throws -> [UInt8] {
        let outCapacity = input.count + kCCBlockSizeAES128
        var out = [UInt8](repeating: 0, count: outCapacity)
        var moved = 0
        var status: CCCryptorStatus = kCCParamError

        key.withUnsafeBytes { keyPtr in
            input.withUnsafeBytes { inPtr in
                iv.withUnsafeBytes { ivPtr in
                    out.withUnsafeMutableBufferPointer { outPtr in
                        status = CCCrypt(op,
                                         algorithm,
                                         options,
                                         keyPtr.baseAddress, key.count,
                                         iv.isEmpty ? nil : ivPtr.baseAddress,
                                         inPtr.baseAddress, input.count,
                                         outPtr.baseAddress, outCapacity,
                                         &moved)
                    }
                }
            }
        }

        guard status == kCCSuccess else { throw TransformError.cipherFailed(status) }
        return Array(out[0..<moved])
    }

    // MARK: - Parsing helpers

    private static func parseBytes(_ text: String, isHex: Bool, what: String) throws -> [UInt8] {
        if isHex {
            let cleaned = text.filter { !$0.isWhitespace && $0 != "," && $0 != "-" }
            guard !cleaned.isEmpty else { throw TransformError.invalidKey("\(what) is empty") }
            guard cleaned.count % 2 == 0 else {
                throw TransformError.invalidKey("\(what) hex needs an even number of digits")
            }
            var out: [UInt8] = []
            var index = cleaned.startIndex
            while index < cleaned.endIndex {
                let next = cleaned.index(index, offsetBy: 2)
                guard let byte = UInt8(cleaned[index..<next], radix: 16) else {
                    throw TransformError.invalidKey("\(what) contains non-hex characters")
                }
                out.append(byte)
                index = next
            }
            return out
        }
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { throw TransformError.invalidKey("\(what) is empty") }
        return bytes
    }

    private static func parseConstant(_ text: String) throws -> UInt8 {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        let hex = cleaned.hasPrefix("0x") || cleaned.hasPrefix("0X")
            ? String(cleaned.dropFirst(2)) : cleaned
        if let value = UInt8(hex, radix: 16) { return value }
        if let value = UInt8(cleaned) { return value }
        throw TransformError.invalidConstant("must be a byte value (0x00–0xFF)")
    }

    private static func normalize(_ bytes: [UInt8], targets: [Int]) -> [UInt8] {
        if targets.contains(bytes.count) { return bytes }
        let target = targets.first { bytes.count <= $0 } ?? targets[targets.count - 1]
        if bytes.count > target { return Array(bytes[0..<target]) }
        return bytes + [UInt8](repeating: 0, count: target - bytes.count)
    }
}