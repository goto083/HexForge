import SwiftUI

/// Pick list of attached disks and partitions. Reused by "Open Raw Device",
/// "Disk Clone" and "Disk Image" so no tool needs a hand-typed /dev path.
struct DiskListView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selection: String?

    private var selectedDisk: DiskInfo? {
        state.disks.first { $0.bsdName == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L.t("Disk List")).font(.headline)
                Spacer()
                Button { state.refreshDisks() } label: {
                    Label(L.t("Refresh"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }

            Text(L.t("Pick a whole disk or one of its partitions. Raw devices are opened read-only."))
                .font(.caption)
                .foregroundColor(.secondary)

            if !DiskService.isPrivileged {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("Reading a raw device needs administrator rights."))
                            .font(.caption).bold()
                        Text(L.t("Restart HexForge as administrator to open devices."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(L.t("Restart as Administrator")) { state.restartAsAdministrator() }
                }
                .padding(8)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(6)
            }

            if state.disks.isEmpty {
                Spacer()
                Text(L.t("No disks found."))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                List(selection: $selection) {
                    ForEach(state.disks) { disk in
                        DiskRow(disk: disk).tag(disk.bsdName)
                    }
                }
                .frame(minHeight: 220)
            }

            HStack(spacing: 8) {
                Text(L.t("Path") + ": " + (selectedDisk?.rawPath ?? "—"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let disk = selectedDisk {
                    Button(L.t("Copy Path")) { state.copyPath(disk.rawPath) }
                        .controlSize(.small)
                }
                Spacer()
                Button(L.t("Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L.t("Open")) { openSelected() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedDisk == nil)
            }
        }
        .padding(20)
        .frame(width: 620, height: 470)
        .onAppear { state.refreshDisks() }
    }

    private func openSelected() {
        guard let disk = selectedDisk else { return }
        if state.applyDiskSelection(disk) { dismiss() }
    }
}

// MARK: - Row

private struct DiskRow: View {
    @EnvironmentObject var state: AppState

    let disk: DiskInfo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(disk.isExternal ? .accentColor : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(disk.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if disk.isRemovable { badge(L.t("Removable")) }
                    if disk.isEjectable { badge(L.t("Ejectable")) }
                    if !disk.isWhole { badge(L.t("Partition")) }
                }
                Text(subtitle)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(disk.rawPath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
        .padding(.leading, CGFloat(disk.depth) * 14)
    }

    private var subtitle: String {
        var parts = [state.byteCountString(Int(disk.size))]
        if !disk.busName.isEmpty { parts.append(disk.busName) }
        parts.append(disk.bsdName)
        return parts.joined(separator: "  ·  ")
    }

    private var icon: String {
        if disk.isWhole { return disk.isExternal ? "externaldrive.fill" : "internaldrive.fill" }
        return "rectangle.stack"
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.gray.opacity(0.18))
            .cornerRadius(3)
    }
}
