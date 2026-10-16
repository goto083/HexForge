import SwiftUI
import AppKit

/// File system browser, docked above the hex view (WinHex directory-browser style).
///
/// Columns: name / extension / size / created / modified / accessed / attributes,
/// with a volume summary line (file system, label, free space, FAT geometry).
/// Right-click offers Open, Recover/Copy and Navigate (List Clusters / Go to
/// Directory Entry).
struct FileSystemView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var browser: FileSystemBrowser

    private static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm:ss.S"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            if let volume = browser.volume {
                summary(volume.info)
                Divider()
                columnHeader
                Divider()
                entryList
            } else {
                Spacer()
                Text(browser.status.isEmpty ? L.t("Unsupported or unknown file system.") : browser.status)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { browser.open(using: state) }
        .sheet(isPresented: Binding(
            get: { browser.clusterListEntry != nil },
            set: { if !$0 { browser.clusterListEntry = nil } })) {
            ClusterListView(browser: browser)
                .environmentObject(state)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                browser.goUp(using: state)
            } label: {
                Image(systemName: "arrow.uturn.upward")
            }
            .buttonStyle(.borderless)
            .disabled(browser.pathNames.isEmpty)
            .help(L.t("Up"))

            Image(systemName: "folder")
                .foregroundColor(.secondary)
            breadcrumb
            if !browser.status.isEmpty {
                Text(browser.status)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(L.f("Results (%d)", browser.entries.count))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Clickable path: every segment jumps straight to that ancestor directory.
    private var breadcrumb: some View {
        HStack(spacing: 2) {
            Button {
                browser.go(toLevel: 0, using: state)
            } label: {
                Text(browser.label.isEmpty ? L.t("Root directory") : browser.label)
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)

            ForEach(browser.pathNames.indices, id: \.self) { idx in
                Text("/")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Button {
                    browser.go(toLevel: idx + 1, using: state)
                } label: {
                    Text(browser.pathNames[idx])
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
            }
        }
        .lineLimit(1)
    }

    // MARK: Volume summary

    private func summary(_ info: FSVolumeInfo) -> some View {
        let totalBytes = UInt64(info.totalClusters) * UInt64(info.clusterSize)
        let freeBytes = browser.freeClusters.map { UInt64($0) * UInt64(info.clusterSize) }
        let percent: Int? = {
            guard let free = browser.freeClusters, info.totalClusters > 0 else { return nil }
            return Int(Double(free) * 100.0 / Double(info.totalClusters))
        }()
        return HStack(spacing: 16) {
            Text(info.kind.rawValue).bold()
            if !browser.label.isEmpty {
                Text(L.f("Label: %@", browser.label))
            }
            Text(L.f("Total: %@", state.byteCountString(Int(totalBytes))))
            if let freeBytes {
                Text(L.f("Free: %@", state.byteCountString(Int(freeBytes))))
                    .foregroundColor(.secondary)
            }
            if let percent {
                Text(L.f("%d%% free", percent))
                    .foregroundColor(percent < 10 ? .red : .secondary)
            }
            Text(L.f("Cluster: %@", state.byteCountString(info.clusterSize)))
                .foregroundColor(.secondary)
            Text(L.f("FAT at sector %d (%@)",
                     info.fatStartSector, state.byteCountString(info.fatLength)))
                .foregroundColor(.secondary)
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: Columns

    private let colName: CGFloat = 210
    private let colExt: CGFloat = 56
    private let colSize: CGFloat = 80
    private let colDate: CGFloat = 165
    private let colAttr: CGFloat = 44

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text(L.t("Name"))
                .frame(width: colName, alignment: .leading)
            Text(L.t("Ext."))
                .frame(width: colExt, alignment: .leading)
            Text(L.t("Size"))
                .frame(width: colSize, alignment: .trailing)
            Text(L.t("Created"))
                .frame(width: colDate, alignment: .leading)
            Text(L.t("Modified"))
                .frame(width: colDate, alignment: .leading)
            Text(L.t("Accessed"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(L.t("Attrs"))
                .frame(width: colAttr, alignment: .leading)
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    private var entryList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(browser.entries) { entry in
                    row(entry)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func row(_ entry: FSEntry) -> some View {
        let selected = browser.selectedEntryID == entry.id
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: iconName(entry))
                    .foregroundColor(iconColor(entry))
                    .frame(width: 14)
                Text(entry.displayNameOverride ?? entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(entry.isSystem ? .orange : .primary)
            }
            .frame(width: colName, alignment: .leading)

            Text(entry.ext)
                .frame(width: colExt, alignment: .leading)
            Text(entry.isDirectory && entry.parentCluster == nil
                 ? ""
                 : state.byteCountString(Int(entry.size)))
                .frame(width: colSize, alignment: .trailing)
            Text(entry.created.map { Self.dateTime.string(from: $0) } ?? "")
                .frame(width: colDate, alignment: .leading)
            Text(entry.modified.map { Self.dateTime.string(from: $0) } ?? "")
                .frame(width: colDate, alignment: .leading)
            Text(entry.accessed.map { Self.dateTime.string(from: $0) } ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.attributes)
                .frame(width: colAttr, alignment: .leading)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 2.5)
        .background(selected ? Color.accentColor.opacity(0.25) : Color.clear)
        .opacity(entry.isDeleted ? 0.55 : 1)
        .contentShape(Rectangle())
        // Double-click opens; a single click selects, and the ".." row goes up.
        .onTapGesture(count: 2) { browser.openEntry(entry, using: state) }
        .simultaneousGesture(TapGesture(count: 1).onEnded {
            if entry.parentCluster != nil {
                browser.openEntry(entry, using: state)
            } else {
                browser.reveal(entry, using: state)
            }
        })
        .contextMenu {
            Button(L.t("Open")) { browser.openEntry(entry, using: state) }
            Button(L.t("Recover / Copy…")) { browser.recover(entry, using: state) }
                .disabled(entry.isDirectory || entry.isSystem || entry.firstCluster < 2)
            Divider()
            Menu(L.t("Navigate")) {
                Button(L.t("List Clusters")) { browser.listClusters(entry) }
                    .disabled(entry.isSystem || entry.firstCluster < 2)
                Button(L.t("Go to Directory Entry")) { browser.gotoDirectoryEntry(entry, using: state) }
                    .disabled(entry.isSystem || entry.entryOffset <= 0)
            }
        }
    }

    private func iconName(_ entry: FSEntry) -> String {
        if entry.isSystem { return "gearshape.fill" }
        if entry.parentCluster != nil { return "arrow.uturn.upward" }
        if entry.isDirectory { return "folder.fill" }
        return "doc"
    }

    private func iconColor(_ entry: FSEntry) -> Color {
        if entry.isSystem { return .orange }
        if entry.parentCluster != nil { return .blue }
        return entry.isDirectory ? .accentColor : .secondary
    }
}

// MARK: - Cluster chain sheet

/// Navigate → List Clusters. Shows the file's FAT chain; contiguous runs are
/// collapsed to their first and last cluster with an "omitted" line between
/// (WinHex's shortened cluster list), plus the fragmentation count.
/// Click a cluster to jump to it in the hex view.
struct ClusterListView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var browser: FileSystemBrowser
    @Environment(\.dismiss) private var dismiss

    @State private var shorten = true

    private enum Row {
        case cluster(UInt32)
        case omitted(Int)
    }

    /// Display rows: per contiguous run, first cluster … omitted … last cluster.
    private var rows: [Row] {
        if !shorten || browser.clusterSpans.isEmpty {
            return browser.clusterList.map { .cluster($0) }
        }
        var rows: [Row] = []
        for span in browser.clusterSpans {
            if span.count <= 2 {
                for k in 0..<Int(span.count) { rows.append(.cluster(span.start + UInt32(k))) }
            } else {
                rows.append(.cluster(span.start))
                rows.append(.omitted(Int(span.count) - 2))
                rows.append(.cluster(span.start + span.count - 1))
            }
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(browser.clusterListEntry?.name ?? L.t("Clusters"))
                    .font(.headline)
                Spacer()
                Text(L.f("%d of %d cluster(s)", browser.clusterList.count, browser.clusterListTotal))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            Divider()
            if browser.clusterList.isEmpty && browser.clusterSpans.isEmpty {
                Spacer()
                Text(L.t("No cluster chain available (entry may be deleted)."))
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding()
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            switch row {
                            case .cluster(let cluster):
                                Button {
                                    browser.jumpToCluster(cluster, using: state)
                                } label: {
                                    HStack {
                                        Text(L.t("Cluster"))
                                            .foregroundColor(.secondary)
                                        Text("\(cluster)")
                                            .font(.system(.body, design: .monospaced))
                                            .frame(width: 110, alignment: .leading)
                                        if let volume = browser.volume {
                                            let offset = volume.info.clusterOffset(cluster)
                                            Text("0x" + String(offset, radix: 16).uppercased())
                                                .font(.system(.body, design: .monospaced))
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 3)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.primary)
                                Divider().padding(.leading, 12)
                            case .omitted(let count):
                                HStack {
                                    Text(L.f("… %d contiguous cluster(s) omitted", count))
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .frame(width: 110, alignment: .trailing)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Text(L.f("Fragments: %d", browser.clusterSpans.count))
                    .foregroundColor(.secondary)
                Toggle(L.t("Shorten contiguous clusters"), isOn: $shorten)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
                Button(L.t("Copy list to text file…"), action: copyList)
                Button(L.t("Close")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .font(.system(size: 11))
            .padding(10)
        }
        .frame(width: 460, height: 400)
    }

    /// Writes the chain exactly as displayed (shortening respected) to a text file.
    private func copyList() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (browser.clusterListEntry?.name ?? "clusters") + " clusters.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var lines: [String] = []
        if let name = browser.clusterListEntry?.name {
            lines.append(name)
        }
        for row in rows {
            switch row {
            case .cluster(let cluster):
                lines.append("\(L.t("Cluster")) \(cluster)")
            case .omitted(let count):
                lines.append(L.f("… %d contiguous cluster(s) omitted", count))
            }
        }
        lines.append(L.f("Fragments: %d", browser.clusterSpans.count))
        lines.append(L.f("%d of %d cluster(s)", browser.clusterList.count, browser.clusterListTotal))
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        state.statusMessage = L.t("Cluster list saved.")
    }
}
