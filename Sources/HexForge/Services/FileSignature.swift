import Foundation

/// A file format recognised by its magic bytes.
///
/// `magic` uses `nil` for wildcard bytes. `magicOffset` is where the signature
/// lives inside the file (0 for most formats, 512 for the GPT header, …).
/// `parseOffset` is the base offset a structure template should be evaluated
/// from; it usually equals `magicOffset`.
struct FileSignature {
    let name: String
    let magic: [UInt8?]
    let magicOffset: Int
    let parseOffset: Int
    /// Name of the matching built-in `StructureTemplate`, if the format has one.
    let templateName: String?

    init(name: String,
         magic: [UInt8?],
         magicOffset: Int = 0,
         parseOffset: Int = 0,
         templateName: String? = nil) {
        self.name = name
        self.magic = magic
        self.magicOffset = magicOffset
        self.parseOffset = parseOffset
        self.templateName = templateName
    }

    var magicHex: String {
        magic.map { $0.map { String(format: "%02X", $0) } ?? "??" }.joined(separator: " ")
    }

    func matches(_ document: HexDocument) -> Bool {
        let base = magicOffset
        guard base >= 0, base + magic.count <= document.size else { return false }
        for (index, byte) in magic.enumerated() {
            if let byte, document.byte(at: base + index) != byte { return false }
        }
        return true
    }
}

/// Identifies a file format from its leading (or embedded) signature bytes.
enum SignatureDetector {

    /// Returns the first (most specific) signature that matches the data.
    static func detect(_ document: HexDocument) -> FileSignature? {
        guard document.size > 0 else { return nil }
        return signatures.first { $0.matches(document) }
    }

    private static func bytes(_ string: String) -> [UInt8?] {
        string.utf8.map { Optional($0) }
    }

    /// Ordered most-specific first; the first match wins.
    static let signatures: [FileSignature] = [
        // ---- signatures at offset 0 ----
        FileSignature(name: "PNG image",
                      magic: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
                      templateName: "PNG Image"),
        FileSignature(name: "JPEG image",
                      magic: [0xFF, 0xD8, 0xFF],
                      templateName: "JPEG Image"),
        FileSignature(name: "GIF image",
                      magic: [0x47, 0x49, 0x46, 0x38, nil, 0x61],
                      templateName: "GIF Image"),
        FileSignature(name: "BMP image",
                      magic: [0x42, 0x4D],
                      templateName: "BMP Image"),
        FileSignature(name: "PDF document",
                      magic: bytes("%PDF-"),
                      templateName: "PDF Document"),
        FileSignature(name: "PE / DOS executable",
                      magic: [0x4D, 0x5A],
                      templateName: "PE Executable (DOS header)"),
        FileSignature(name: "ZIP archive",
                      magic: [0x50, 0x4B, 0x03, 0x04],
                      templateName: "ZIP Local Header"),
        FileSignature(name: "GZIP stream",
                      magic: [0x1F, 0x8B],
                      templateName: "GZIP Stream"),
        FileSignature(name: "7-Zip archive",
                      magic: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C],
                      templateName: "7-Zip Header"),
        FileSignature(name: "RAR5 archive",
                      magic: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00],
                      templateName: "RAR Archive"),
        FileSignature(name: "RAR archive",
                      magic: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00],
                      templateName: "RAR Archive"),
        FileSignature(name: "ELF binary",
                      magic: [0x7F, 0x45, 0x4C, 0x46],
                      templateName: "ELF Header"),
        FileSignature(name: "Mach-O 64-bit (little-endian)",
                      magic: [0xCF, 0xFA, 0xED, 0xFE],
                      templateName: "Mach-O Header"),
        FileSignature(name: "Mach-O 64-bit (big-endian)",
                      magic: [0xFE, 0xED, 0xFA, 0xCF],
                      templateName: "Mach-O Header"),
        FileSignature(name: "Mach-O 32-bit (little-endian)",
                      magic: [0xCE, 0xFA, 0xED, 0xFE],
                      templateName: "Mach-O Header"),
        // 0xCAFEBABE is shared by Java class files and Mach-O fat binaries.
        FileSignature(name: "Java class / Mach-O fat binary",
                      magic: [0xCA, 0xFE, 0xBA, 0xBE]),
        FileSignature(name: "SQLite database",
                      magic: bytes("SQLite format 3"),
                      templateName: "SQLite Database"),
        FileSignature(name: "RIFF container",
                      magic: bytes("RIFF"),
                      templateName: "RIFF Container"),

        // ---- signatures not at offset 0 ----
        FileSignature(name: "ISO 9660 volume",
                      magic: bytes("CD001"),
                      magicOffset: 0x8001,
                      parseOffset: 0x8000,
                      templateName: "ISO 9660 Volume Descriptor"),
        FileSignature(name: "GPT partition table",
                      magic: bytes("EFI PART"),
                      magicOffset: 512,
                      parseOffset: 512,
                      templateName: "GPT Header"),
        FileSignature(name: "NTFS volume",
                      magic: bytes("NTFS"),
                      magicOffset: 3,
                      templateName: "NTFS Boot Sector"),
        FileSignature(name: "FAT32 volume",
                      magic: bytes("FAT32"),
                      magicOffset: 0x52,
                      templateName: "FAT32 Boot Sector"),
        FileSignature(name: "FAT16 volume",
                      magic: bytes("FAT16"),
                      magicOffset: 0x36),
        FileSignature(name: "FAT12 volume",
                      magic: bytes("FAT12"),
                      magicOffset: 0x36),
        FileSignature(name: "MBR / boot sector",
                      magic: [0x55, 0xAA],
                      magicOffset: 510,
                      templateName: "MBR / Boot Sector")
    ]
}