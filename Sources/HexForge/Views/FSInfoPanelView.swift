import SwiftUI

/// Left-hand readout shown while a file system is parsed (WinHex's info panel).
///
/// As the pointer moves over the hex view it reports the cluster under the
/// cursor, the file that cluster belongs to and that file's full parent chain.
struct FSInfoPanelView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var browser: FileSystemBrowser

    private var probeOffset: Int { state.hoverOffset ?? state.cursor }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                if let volume = browser.volume {
                    content(volume)
                } else {
                    Text(browser.status.isEmpty ? L.t("Unsupported or unknown file system.") : browser.status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func content(_ volume: FSVolume) -> some View {
        let info = volume.info
        let cluster = volume.clusterNumber(atOffset: probeOffset)
        let systemArea = cluster == nil ? volume.systemAreaName(atOffset: probeOffset) : nil
        let owner = browser.owner(atOffset: probeOffset)

        line(L.t("File system"),
             info.kind.rawValue + (browser.label.isEmpty ? "" : "  ·  " + browser.label),
             accent: .accentColor)

        if let free = browser.freeClusters, info.totalClusters > 0 {
            let percent = Int(Double(free) * 100.0 / Double(info.totalClusters))
            line(L.t("Free space"), L.f("%@  (%d%%)",
                                        state.byteCountString(Int(UInt64(free) * UInt64(info.clusterSize))),
                                        percent),
                 accent: percent < 10 ? .red : .secondary)
        }

        Divider().padding(.vertical, 1)

        line(L.t("Offset"), "0x" + String(probeOffset, radix: 16).uppercased() + "  ·  \(probeOffset)", mono: true)
        line(L.t("Logical sector"), "\(probeOffset / max(1, info.bytesPerSector))", mono: true)

        if let cluster {
            line(L.t("Cluster"), "\(cluster)", mono: true, accent: .primary)
        } else {
            line(L.t("Cluster"), systemArea ?? L.t("Outside volume"))
        }

        line(L.t("Owned by"), owner?.name ?? (browser.scanning ? L.t("Scanning…") : L.t("Free space")))
        line(L.t("Parent chain"), owner?.directoryPath ?? "—", mono: true)
        if let owner, owner.isDirectory {
            Text(L.t("Directory"))
                .font(.caption2)
                .foregroundColor(.secondary)
        }

        Divider().padding(.vertical, 1)

        line(L.t("Bytes per sector"), "\(info.bytesPerSector)", mono: true)
        line(L.t("Bytes per cluster"), "\(info.clusterSize)", mono: true)
        line(L.t("Total clusters"), "\(info.totalClusters)", mono: true)
        if let free = browser.freeClusters {
            line(L.t("Free clusters"), "\(free)", mono: true)
        }
        line(L.t("FAT"), L.f("sector %d, %@", info.fatStartSector,
                             state.byteCountString(info.fatLength)), mono: true)

        Divider().padding(.vertical, 1)

        let total = UInt64(info.totalClusters) * UInt64(info.clusterSize)
        line(L.t("Volume size"), state.byteCountString(Int(total)))
        if let free = browser.freeClusters {
            let freeBytes = UInt64(free) * UInt64(info.clusterSize)
            line(L.t("Used space"), state.byteCountString(Int(total - min(total, freeBytes))))
            line(L.t("Free space (bytes)"), state.byteCountString(Int(freeBytes)))
        }
    }

    private func line(_ title: String,
                      _ value: String,
                      mono: Bool = false,
                      accent: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 11, design: mono ? .monospaced : .default))
                .foregroundColor(accent)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
