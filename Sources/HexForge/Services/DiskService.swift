import Foundation
import Darwin
import IOKit
import DiskArbitration

/// One raw block device attached to the machine: either a whole physical disk
/// (`disk4`) or something below it (`disk4s2`, including the APFS volumes the
/// system synthesizes).
struct DiskInfo: Identifiable, Hashable {

    /// BSD node name without the `/dev/` prefix, e.g. `disk4` or `disk4s2`.
    let bsdName: String
    /// BSD name of the nearest enclosing whole disk; `nil` for the disk itself.
    var parentBSDName: String?
    /// Nesting level used purely for indentation in the list.
    var depth = 0
    /// True when this node is a whole disk rather than a partition.
    let isWhole: Bool

    let volumeName: String
    let modelName: String
    let busName: String
    let size: Int64
    let isRemovable: Bool
    let isEjectable: Bool
    let isInternal: Bool

    var id: String { bsdName }

    /// Raw (unbuffered) node — noticeably faster to read than the buffered one.
    var rawPath: String { "/dev/r\(bsdName)" }
    var bufferedPath: String { "/dev/\(bsdName)" }

    var isExternal: Bool { !isInternal }

    /// Best human label available for this entry.
    var displayName: String {
        if !volumeName.isEmpty { return volumeName }
        if !modelName.isEmpty { return modelName }
        return bsdName
    }
}

/// Enumerates attached block devices so the UI can offer a pick list instead of
/// asking the user to type a `/dev/rdiskN` path from memory.
///
/// Device identity comes from IOKit (`IOMedia`), while names, sizes and the
/// removable/internal flags come from DiskArbitration.
enum DiskService {

    /// Reading a raw device is root-only on macOS; everything else can be done
    /// as the normal user.
    static var isPrivileged: Bool { getuid() == 0 }

    /// Every attached block device, external hardware first, with each whole
    /// disk immediately followed by its partitions.
    static func list() -> [DiskInfo] {
        var entries = scan()
        guard !entries.isEmpty else { return [] }

        // A parent that isn't in the list would hide its children; promote them.
        let known = Set(entries.map(\.bsdName))
        for index in entries.indices {
            if let parent = entries[index].parentBSDName, !known.contains(parent) {
                entries[index].parentBSDName = nil
            }
        }

        let children = Dictionary(grouping: entries) { $0.parentBSDName ?? "" }
        var ordered: [DiskInfo] = []

        func appendChildren(of parent: String, depth: Int) {
            for child in (children[parent] ?? []).sorted(by: isOrderedBefore) {
                var entry = child
                entry.depth = depth
                ordered.append(entry)
                appendChildren(of: child.bsdName, depth: depth + 1)
            }
        }

        appendChildren(of: "", depth: 0)
        return ordered
    }

    /// Size in bytes of a device node such as `/dev/rdisk4`, or 0 when unknown.
    static func deviceSize(ofPath path: String) -> Int64 {
        var name = (path as NSString).lastPathComponent
        if name.hasPrefix("r") { name = String(name.dropFirst()) }
        guard name.hasPrefix("disk") else { return 0 }
        return size(ofBSDName: name)
    }

    /// Size in bytes reported for a BSD name such as `disk4`.
    static func size(ofBSDName bsd: String) -> Int64 {
        let description = describe(bsdName: bsd)
        return (description["DAMediaSize"] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Ordering

    /// Removable hardware first, then external, then whole disks, then name.
    private static func isOrderedBefore(_ a: DiskInfo, _ b: DiskInfo) -> Bool {
        if a.isRemovable != b.isRemovable { return a.isRemovable }
        if a.isInternal != b.isInternal { return !a.isInternal }
        if a.isWhole != b.isWhole { return a.isWhole }
        return a.bsdName.localizedStandardCompare(b.bsdName) == .orderedAscending
    }

    // MARK: - Enumeration

    private static func scan() -> [DiskInfo] {
        var entries: [DiskInfo] = []
        guard let matching = IOServiceMatching("IOMedia") else { return entries }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return entries
        }
        defer { IOObjectRelease(iterator) }

        guard let session = DASessionCreate(kCFAllocatorDefault) else { return entries }

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            guard let bsdName = stringProperty(service, "BSD Name") else { continue }
            guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else { continue }
            let description = (DADiskCopyDescription(disk) as? [String: Any]) ?? [:]

            let whole = isWholeBSDName(bsdName)
            var parent = whole ? nil : wholeAncestorBSDName(of: service)
            if parent == bsdName { parent = nil }

            entries.append(DiskInfo(
                bsdName: bsdName,
                parentBSDName: parent,
                isWhole: whole,
                volumeName: description["DAVolumeName"] as? String ?? "",
                modelName: description["DADeviceModel"] as? String ?? "",
                busName: description["DABusName"] as? String ?? "",
                size: (description["DAMediaSize"] as? NSNumber)?.int64Value ?? 0,
                isRemovable: description["DAMediaRemovable"] as? Bool ?? false,
                isEjectable: description["DAMediaEjectable"] as? Bool ?? false,
                isInternal: description["DADeviceInternal"] as? Bool ?? true
            ))
        }
        return entries
    }

    /// DiskArbitration description for one BSD name, or an empty dictionary.
    private static func describe(bsdName: String) -> [String: Any] {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else { return [:] }
        return (DADiskCopyDescription(disk) as? [String: Any]) ?? [:]
    }

    /// True for `disk4` but not for `disk4s1`.
    private static func isWholeBSDName(_ name: String) -> Bool {
        guard name.hasPrefix("disk") else { return false }
        let suffix = name.dropFirst("disk".count)
        return !suffix.isEmpty && suffix.allSatisfy { $0.isNumber }
    }

    /// Walks up the IOService plane to the nearest whole disk, so partitions and
    /// synthetic APFS media nest under their real hardware. Returns nil when the
    /// walk leaves the storage stack without finding one.
    private static func wholeAncestorBSDName(of service: io_object_t) -> String? {
        var current = service
        IOObjectRetain(current)

        var found: String?
        for _ in 0..<16 {
            var parent: io_object_t = 0
            guard IORegistryEntryGetParentEntry(current, "IOService", &parent) == KERN_SUCCESS,
                  parent != 0 else { break }
            IOObjectRelease(current)
            current = parent
            if let name = stringProperty(current, "BSD Name"), isWholeBSDName(name) {
                found = name
                break
            }
        }

        IOObjectRelease(current)
        return found
    }

    private static func stringProperty(_ service: io_object_t, _ key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return value.takeRetainedValue() as? String
    }
}
