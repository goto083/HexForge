import Foundation

/// Declarative description of a binary structure field.
struct TemplateField {
    let name: String
    let offset: Int
    let kind: FieldKind

    enum FieldKind {
        case uint8
        case uint16LE
        case uint16BE
        case uint32LE
        case uint32BE
        case uint64LE
        case uint64BE
        case int32LE
        case ascii(Int)
        case hexBytes(Int)
        case guid
        case unixTime32LE
        case fileTime64LE
    }
}

struct StructureTemplate: Identifiable {
    let id = UUID()
    let name: String
    let fields: [TemplateField]
}

struct ResolvedField: Identifiable {
    let id = UUID()
    let name: String
    let offset: Int
    let raw: String
    let value: String
}

extension StructureTemplate {

    static func evaluate(_ template: StructureTemplate, in document: HexDocument, base: Int = 0) -> [ResolvedField] {
        template.fields.compactMap { field in
            let offset = base + field.offset
            guard let (byteCount, decode) = spec(for: field.kind) else { return nil }
            guard offset + byteCount <= document.size else { return nil }
            let bytes = document.bytes(in: offset..<(offset + byteCount))
            guard bytes.count == byteCount else { return nil }
            return ResolvedField(
                name: field.name,
                offset: offset,
                raw: bytes.map { String(format: "%02X", $0) }.joined(separator: " "),
                value: decode(bytes)
            )
        }
    }

    private static func spec(for kind: TemplateField.FieldKind) -> (Int, ([UInt8]) -> String)? {
        switch kind {
        case .uint8:
            return (1, { "\($0[0])  (0x\(String(format: "%02X", $0[0])))" })

        case .uint16LE:
            return (2, { "\(UInt16(truncatingIfNeeded: DataInterpreter.le($0, 2)))" })
        case .uint16BE:
            return (2, { "\(UInt16(truncatingIfNeeded: DataInterpreter.be($0, 2)))" })
        case .uint32LE:
            return (4, { "\(UInt32(truncatingIfNeeded: DataInterpreter.le($0, 4)))" })
        case .uint32BE:
            return (4, { "\(UInt32(truncatingIfNeeded: DataInterpreter.be($0, 4)))" })
        case .uint64LE:
            return (8, { "\(DataInterpreter.le($0, 8))" })
        case .uint64BE:
            return (8, { "\(DataInterpreter.be($0, 8))" })
        case .int32LE:
            return (4, { "\(Int32(bitPattern: UInt32(truncatingIfNeeded: DataInterpreter.le($0, 4))))" })

        case .ascii(let n):
            return (n, { bytes in
                let s = bytes.map { byte -> Character in
                    (byte >= 0x20 && byte < 0x7F) ? Character(UnicodeScalar(byte)) : Character(".")
                }
                return String(s)
            })

        case .hexBytes(let n):
            return (n, { $0.map { String(format: "%02X", $0) }.joined(separator: " ") })

        case .guid:
            return (16, { bytes in
                let d1 = DataInterpreter.le(bytes, 4)
                let d2 = DataInterpreter.le(Array(bytes[4..<6]), 2)
                let d3 = DataInterpreter.le(Array(bytes[6..<8]), 2)
                let tail = bytes[8..<10].map { String(format: "%02X", $0) }.joined()
                let tail2 = bytes[10..<16].map { String(format: "%02X", $0) }.joined()
                return String(format: "%08X-%04X-%04X-%@-%@",
                              UInt32(truncatingIfNeeded: d1),
                              UInt16(truncatingIfNeeded: d2),
                              UInt16(truncatingIfNeeded: d3),
                              tail, tail2)
            })

        case .unixTime32LE:
            return (4, { bytes in
                let secs = UInt32(truncatingIfNeeded: DataInterpreter.le(bytes, 4))
                guard secs > 0, secs < 4_102_444_800 else { return "—" }
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd HH:mm:ss"
                df.timeZone = TimeZone(identifier: "UTC")
                return df.string(from: Date(timeIntervalSince1970: TimeInterval(secs))) + " UTC"
            })

        case .fileTime64LE:
            return (8, { bytes in
                let v = DataInterpreter.le(bytes, 8)
                guard v > 0, v < 2_000_000_000_000_000_000 else { return "—" }
                let secs = TimeInterval(v) / 10_000_000.0 - 11_644_473_600.0
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd HH:mm:ss"
                df.timeZone = TimeZone(identifier: "UTC")
                return df.string(from: Date(timeIntervalSince1970: secs)) + " UTC"
            })
        }
    }
}

enum BuiltinTemplates {

    static let all: [StructureTemplate] = [
        png, jpeg, gif, bmp, pdf,
        peDosHeader, zipLocalHeader, gzipStream, sevenZip, rar,
        elf, machO, javaClass, sqlite, riff, iso9660,
        mbr, gptHeader, fat32BootSector, ntfsBootSector
    ]

    static let png = StructureTemplate(name: "PNG Image", fields: [
        .init(name: "Signature", offset: 0, kind: .hexBytes(8)),
        .init(name: "IHDR length", offset: 8, kind: .uint32BE),
        .init(name: "IHDR type", offset: 12, kind: .ascii(4)),
        .init(name: "Width", offset: 16, kind: .uint32BE),
        .init(name: "Height", offset: 20, kind: .uint32BE),
        .init(name: "Bit depth", offset: 24, kind: .uint8),
        .init(name: "Colour type", offset: 25, kind: .uint8),
        .init(name: "Compression", offset: 26, kind: .uint8),
        .init(name: "Filter", offset: 27, kind: .uint8),
        .init(name: "Interlace", offset: 28, kind: .uint8)
    ])

    static let jpeg = StructureTemplate(name: "JPEG Image", fields: [
        .init(name: "SOI marker", offset: 0, kind: .hexBytes(2)),
        .init(name: "Marker", offset: 2, kind: .hexBytes(2)),
        .init(name: "Segment length", offset: 4, kind: .uint16BE),
        .init(name: "Identifier", offset: 6, kind: .ascii(5))
    ])

    static let gif = StructureTemplate(name: "GIF Image", fields: [
        .init(name: "Signature", offset: 0, kind: .ascii(6)),
        .init(name: "Width", offset: 6, kind: .uint16LE),
        .init(name: "Height", offset: 8, kind: .uint16LE),
        .init(name: "Packed fields", offset: 10, kind: .uint8),
        .init(name: "Background colour index", offset: 11, kind: .uint8),
        .init(name: "Pixel aspect ratio", offset: 12, kind: .uint8)
    ])

    static let bmp = StructureTemplate(name: "BMP Image", fields: [
        .init(name: "Signature", offset: 0, kind: .ascii(2)),
        .init(name: "File size", offset: 2, kind: .uint32LE),
        .init(name: "Reserved 1", offset: 6, kind: .uint16LE),
        .init(name: "Reserved 2", offset: 8, kind: .uint16LE),
        .init(name: "Pixel data offset", offset: 10, kind: .uint32LE),
        .init(name: "DIB header size", offset: 14, kind: .uint32LE),
        .init(name: "Width", offset: 18, kind: .int32LE),
        .init(name: "Height", offset: 22, kind: .int32LE),
        .init(name: "Planes", offset: 26, kind: .uint16LE),
        .init(name: "Bits per pixel", offset: 28, kind: .uint16LE),
        .init(name: "Compression", offset: 30, kind: .uint32LE),
        .init(name: "Image size", offset: 34, kind: .uint32LE)
    ])

    static let pdf = StructureTemplate(name: "PDF Document", fields: [
        .init(name: "Header", offset: 0, kind: .ascii(5)),
        .init(name: "Version", offset: 5, kind: .ascii(3)),
        .init(name: "Binary marker", offset: 8, kind: .hexBytes(4))
    ])

    static let peDosHeader = StructureTemplate(name: "PE Executable (DOS header)", fields: [
        .init(name: "Signature", offset: 0, kind: .ascii(2)),
        .init(name: "Bytes on last page", offset: 2, kind: .uint16LE),
        .init(name: "Pages in file", offset: 4, kind: .uint16LE),
        .init(name: "Relocations", offset: 6, kind: .uint16LE),
        .init(name: "Header size (paras)", offset: 8, kind: .uint16LE),
        .init(name: "Min extra paragraphs", offset: 10, kind: .uint16LE),
        .init(name: "Max extra paragraphs", offset: 12, kind: .uint16LE),
        .init(name: "Initial SS", offset: 14, kind: .uint16LE),
        .init(name: "Initial SP", offset: 16, kind: .uint16LE),
        .init(name: "Checksum", offset: 18, kind: .uint16LE),
        .init(name: "Initial IP", offset: 20, kind: .uint16LE),
        .init(name: "Initial CS", offset: 22, kind: .uint16LE),
        .init(name: "Relocation table offset", offset: 24, kind: .uint16LE),
        .init(name: "Overlay number", offset: 26, kind: .uint16LE),
        .init(name: "PE header offset", offset: 0x3C, kind: .uint32LE)
    ])

    static let zipLocalHeader = StructureTemplate(name: "ZIP Local Header", fields: [
        .init(name: "Signature", offset: 0, kind: .hexBytes(4)),
        .init(name: "Version needed", offset: 4, kind: .uint16LE),
        .init(name: "Flags", offset: 6, kind: .uint16LE),
        .init(name: "Compression method", offset: 8, kind: .uint16LE),
        .init(name: "Mod time (DOS)", offset: 10, kind: .uint16LE),
        .init(name: "Mod date (DOS)", offset: 12, kind: .uint16LE),
        .init(name: "CRC-32", offset: 14, kind: .uint32LE),
        .init(name: "Compressed size", offset: 18, kind: .uint32LE),
        .init(name: "Uncompressed size", offset: 22, kind: .uint32LE),
        .init(name: "File name length", offset: 26, kind: .uint16LE),
        .init(name: "Extra field length", offset: 28, kind: .uint16LE)
    ])

    static let gzipStream = StructureTemplate(name: "GZIP Stream", fields: [
        .init(name: "Signature", offset: 0, kind: .hexBytes(2)),
        .init(name: "Compression method", offset: 2, kind: .uint8),
        .init(name: "Flags", offset: 3, kind: .uint8),
        .init(name: "Modification time", offset: 4, kind: .unixTime32LE),
        .init(name: "Extra flags", offset: 8, kind: .uint8),
        .init(name: "OS", offset: 9, kind: .uint8)
    ])

    static let sevenZip = StructureTemplate(name: "7-Zip Header", fields: [
        .init(name: "Signature", offset: 0, kind: .hexBytes(6)),
        .init(name: "Version major", offset: 6, kind: .uint8),
        .init(name: "Version minor", offset: 7, kind: .uint8),
        .init(name: "Start header CRC-32", offset: 8, kind: .uint32LE),
        .init(name: "Next header offset", offset: 12, kind: .uint64LE),
        .init(name: "Next header size", offset: 20, kind: .uint64LE),
        .init(name: "Next header CRC-32", offset: 28, kind: .uint32LE)
    ])

    static let rar = StructureTemplate(name: "RAR Archive", fields: [
        .init(name: "Signature", offset: 0, kind: .hexBytes(7)),
        .init(name: "Header CRC-32", offset: 8, kind: .uint32LE)
    ])

    static let elf = StructureTemplate(name: "ELF Header", fields: [
        .init(name: "Magic", offset: 0, kind: .hexBytes(4)),
        .init(name: "Class (1=32,2=64)", offset: 4, kind: .uint8),
        .init(name: "Data (1=LE,2=BE)", offset: 5, kind: .uint8),
        .init(name: "Version", offset: 6, kind: .uint8),
        .init(name: "OS/ABI", offset: 7, kind: .uint8),
        .init(name: "ABI version", offset: 8, kind: .uint8),
        .init(name: "Type", offset: 16, kind: .uint16LE),
        .init(name: "Machine", offset: 18, kind: .uint16LE),
        .init(name: "Version (32-bit)", offset: 20, kind: .uint32LE)
    ])

    static let machO = StructureTemplate(name: "Mach-O Header", fields: [
        .init(name: "Magic", offset: 0, kind: .hexBytes(4)),
        .init(name: "CPU type", offset: 4, kind: .uint32LE),
        .init(name: "CPU subtype", offset: 8, kind: .uint32LE),
        .init(name: "File type", offset: 12, kind: .uint32LE),
        .init(name: "Load commands", offset: 16, kind: .uint32LE),
        .init(name: "Size of load commands", offset: 20, kind: .uint32LE),
        .init(name: "Flags", offset: 24, kind: .uint32LE)
    ])

    static let javaClass = StructureTemplate(name: "Java Class File", fields: [
        .init(name: "Magic", offset: 0, kind: .hexBytes(4)),
        .init(name: "Minor version", offset: 4, kind: .uint16BE),
        .init(name: "Major version", offset: 6, kind: .uint16BE),
        .init(name: "Constant pool count", offset: 8, kind: .uint16BE)
    ])

    static let sqlite = StructureTemplate(name: "SQLite Database", fields: [
        .init(name: "Header string", offset: 0, kind: .ascii(16)),
        .init(name: "Page size", offset: 16, kind: .uint16BE),
        .init(name: "Write version", offset: 18, kind: .uint8),
        .init(name: "Read version", offset: 19, kind: .uint8),
        .init(name: "Reserved bytes per page", offset: 20, kind: .uint8),
        .init(name: "Max embedded payload", offset: 21, kind: .uint8),
        .init(name: "Min embedded payload", offset: 22, kind: .uint8),
        .init(name: "Leaf payload fraction", offset: 23, kind: .uint8),
        .init(name: "File change counter", offset: 24, kind: .uint32BE),
        .init(name: "Database size (pages)", offset: 28, kind: .uint32BE)
    ])

    static let riff = StructureTemplate(name: "RIFF Container", fields: [
        .init(name: "Signature", offset: 0, kind: .ascii(4)),
        .init(name: "File size", offset: 4, kind: .uint32LE),
        .init(name: "Form type", offset: 8, kind: .ascii(4))
    ])

    /// Fields are relative to the Primary Volume Descriptor (base = 0x8000).
    static let iso9660 = StructureTemplate(name: "ISO 9660 Volume Descriptor", fields: [
        .init(name: "Type", offset: 0, kind: .uint8),
        .init(name: "Identifier", offset: 1, kind: .ascii(5)),
        .init(name: "Version", offset: 6, kind: .uint8),
        .init(name: "Volume identifier", offset: 40, kind: .ascii(32)),
        .init(name: "Volume space size (LE)", offset: 80, kind: .uint32LE),
        .init(name: "Volume space size (BE)", offset: 84, kind: .uint32BE)
    ])

    static let mbr = StructureTemplate(name: "MBR / Boot Sector", fields: [
        .init(name: "Bootstrap (first 16 bytes)", offset: 0, kind: .hexBytes(16)),
        .init(name: "Partition 1 · Boot flag", offset: 446, kind: .uint8),
        .init(name: "Partition 1 · Type", offset: 450, kind: .uint8),
        .init(name: "Partition 1 · Start LBA", offset: 454, kind: .uint32LE),
        .init(name: "Partition 1 · Sectors", offset: 458, kind: .uint32LE),
        .init(name: "Partition 2 · Type", offset: 466, kind: .uint8),
        .init(name: "Partition 2 · Start LBA", offset: 470, kind: .uint32LE),
        .init(name: "Partition 2 · Sectors", offset: 474, kind: .uint32LE),
        .init(name: "Partition 3 · Type", offset: 482, kind: .uint8),
        .init(name: "Partition 3 · Start LBA", offset: 486, kind: .uint32LE),
        .init(name: "Partition 3 · Sectors", offset: 490, kind: .uint32LE),
        .init(name: "Partition 4 · Type", offset: 498, kind: .uint8),
        .init(name: "Partition 4 · Start LBA", offset: 502, kind: .uint32LE),
        .init(name: "Partition 4 · Sectors", offset: 506, kind: .uint32LE),
        .init(name: "Signature (0x55AA)", offset: 510, kind: .uint16LE)
    ])

    static let gptHeader = StructureTemplate(name: "GPT Header", fields: [
        .init(name: "Signature", offset: 0, kind: .ascii(8)),
        .init(name: "Revision", offset: 8, kind: .uint32LE),
        .init(name: "Header size", offset: 12, kind: .uint32LE),
        .init(name: "Header CRC32", offset: 16, kind: .uint32LE),
        .init(name: "Current LBA", offset: 24, kind: .uint64LE),
        .init(name: "Backup LBA", offset: 32, kind: .uint64LE),
        .init(name: "First usable LBA", offset: 40, kind: .uint64LE),
        .init(name: "Last usable LBA", offset: 48, kind: .uint64LE),
        .init(name: "Disk GUID", offset: 56, kind: .guid),
        .init(name: "Partition entry LBA", offset: 72, kind: .uint64LE),
        .init(name: "Number of entries", offset: 80, kind: .uint32LE),
        .init(name: "Size of entry", offset: 84, kind: .uint32LE),
        .init(name: "Partition array CRC32", offset: 88, kind: .uint32LE)
    ])

    static let fat32BootSector = StructureTemplate(name: "FAT32 Boot Sector", fields: [
        .init(name: "OEM name", offset: 3, kind: .ascii(8)),
        .init(name: "Bytes per sector", offset: 11, kind: .uint16LE),
        .init(name: "Sectors per cluster", offset: 13, kind: .uint8),
        .init(name: "Reserved sectors", offset: 14, kind: .uint16LE),
        .init(name: "Number of FATs", offset: 16, kind: .uint8),
        .init(name: "Root entries", offset: 17, kind: .uint16LE),
        .init(name: "Total sectors (16-bit)", offset: 19, kind: .uint16LE),
        .init(name: "Media descriptor", offset: 21, kind: .uint8),
        .init(name: "FAT size (16-bit)", offset: 22, kind: .uint16LE),
        .init(name: "Sectors per track", offset: 24, kind: .uint16LE),
        .init(name: "Heads", offset: 26, kind: .uint16LE),
        .init(name: "Total sectors (32-bit)", offset: 32, kind: .uint32LE),
        .init(name: "FAT size (32-bit)", offset: 36, kind: .uint32LE),
        .init(name: "Volume label", offset: 71, kind: .ascii(11)),
        .init(name: "Filesystem type", offset: 82, kind: .ascii(8)),
        .init(name: "Signature (0x55AA)", offset: 510, kind: .uint16LE)
    ])

    static let ntfsBootSector = StructureTemplate(name: "NTFS Boot Sector", fields: [
        .init(name: "OEM name", offset: 3, kind: .ascii(8)),
        .init(name: "Bytes per sector", offset: 11, kind: .uint16LE),
        .init(name: "Sectors per cluster", offset: 13, kind: .uint8),
        .init(name: "Total sectors", offset: 40, kind: .uint64LE),
        .init(name: "MFT cluster", offset: 48, kind: .uint64LE),
        .init(name: "MFT mirror cluster", offset: 56, kind: .uint64LE),
        .init(name: "Clusters per MFT record", offset: 64, kind: .uint8),
        .init(name: "Volume serial number", offset: 72, kind: .uint64LE),
        .init(name: "Signature (0x55AA)", offset: 510, kind: .uint16LE)
    ])
}

// MARK: - External template files

extension TemplateField.FieldKind {
    /// Parses a template-file kind token, e.g. `u32le`, `ascii`, `hex`, `guid`.
    /// `size` is required for the variable-length kinds (`ascii`, `hex`).
    init?(token: String, size: Int?) {
        switch token.lowercased() {
        case "u8", "uint8", "byte":    self = .uint8
        case "u16le":                  self = .uint16LE
        case "u16be":                  self = .uint16BE
        case "u32le":                  self = .uint32LE
        case "u32be":                  self = .uint32BE
        case "u64le":                  self = .uint64LE
        case "u64be":                  self = .uint64BE
        case "i32le", "int32le":       self = .int32LE
        case "guid":                   self = .guid
        case "time32", "unixtime":     self = .unixTime32LE
        case "filetime", "filetime64": self = .fileTime64LE
        case "ascii", "text":
            guard let size, size > 0 else { return nil }
            self = .ascii(size)
        case "hex", "hexbytes", "bytes":
            guard let size, size > 0 else { return nil }
            self = .hexBytes(size)
        default:
            return nil
        }
    }
}

enum TemplateLoadError: LocalizedError {
    case unreadable(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let message): return L.f("Cannot read template file: %@", message)
        case .invalid(let message):    return L.f("Invalid template file: %@", message)
        }
    }
}

/// Loads user-authored structure templates from a JSON file.
///
/// The file may contain a single template object, an array of templates, or an
/// object with a `"templates"` array. Each template has a `name` and a `fields`
/// array; each field has `name`, `offset` and `kind`, plus `size` for the
/// variable-length `ascii` / `hex` kinds.
enum TemplateLoader {

    static func load(from url: URL) throws -> [StructureTemplate] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TemplateLoadError.unreadable(error.localizedDescription)
        }

        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TemplateLoadError.invalid("not valid JSON (\(error.localizedDescription))")
        }

        let objects: [[String: Any]]
        if let array = root as? [[String: Any]] {
            objects = array
        } else if let object = root as? [String: Any] {
            objects = (object["templates"] as? [[String: Any]]) ?? [object]
        } else {
            throw TemplateLoadError.invalid(L.t("expected a template object or an array of templates"))
        }

        let templates = try objects.map { try template(from: $0) }
        guard !templates.isEmpty else { throw TemplateLoadError.invalid(L.t("no templates found")) }
        return templates
    }

    private static func template(from object: [String: Any]) throws -> StructureTemplate {
        guard let name = object["name"] as? String, !name.isEmpty else {
            throw TemplateLoadError.invalid("a template is missing \"name\"")
        }
        guard let rawFields = object["fields"] as? [[String: Any]], !rawFields.isEmpty else {
            throw TemplateLoadError.invalid(L.f("template \"%@\" has no \"fields\"", name))
        }
        let fields = try rawFields.map { try field(from: $0, template: name) }
        return StructureTemplate(name: name, fields: fields)
    }

    private static func field(from object: [String: Any], template: String) throws -> TemplateField {
        guard let name = object["name"] as? String else {
            throw TemplateLoadError.invalid(L.f("template \"%@\": a field is missing \"name\"", template))
        }
        guard let offset = integer(object["offset"]) else {
            throw TemplateLoadError.invalid(L.f("field \"%@\": missing or invalid \"offset\"", name))
        }
        guard let token = object["kind"] as? String else {
            throw TemplateLoadError.invalid(L.f("field \"%@\": missing \"kind\"", name))
        }
        guard let kind = TemplateField.FieldKind(token: token, size: integer(object["size"])) else {
            throw TemplateLoadError.invalid(L.f("field \"%@\": unknown kind \"%@\"", name, token))
        }
        return TemplateField(name: name, offset: offset, kind: kind)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }
}