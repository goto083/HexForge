import SwiftUI
import AppKit

/// File system browser (hosted in an NSPanel by AppDelegate).
///
/// Parses FAT32 / exFAT boot sectors and lists directories. Single-clicking an
/// entry reveals its data in the hex view (centred); double-clicking a folder
/// navigates into it.
struct FileSystemView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var browser: FileSystemBrowser

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let volume = browser.volume {
                volumeBar(volume.info)
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
        .frame(minWidth: 460, minHeight: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { browser.open(using: state) }
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
            Text("/" + browser.pathNames.joined(separator: "/"))
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Text(L.f("Results (%d)", browser.entries.count))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func volumeBar(_ info: FSVolumeInfo) -> some View {
        HStack(spacing: 14) {
            Text(info.kind.rawValue).bold()
            Text(L.f("%d bytes/sector", info.bytesPerSector))
            Text(L.f("Cluster size %@", state.byteCountString(info.clusterSize)))
            Spacer()
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    // MARK: Entries

    private var entryList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(browser.entries) { entry in
                    let selected = browser.selectedEntryID == entry.id
                    row(entry, selected)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            if entry.isDirectory { browser.enter(entry, using: state) }
                            else { browser.reveal(entry, using: state) }
                        }
                        .onTapGesture(count: 1) {
                            browser.reveal(entry, using: state)
                        }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func row(_ entry: FSEntry, _ selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundColor(entry.isDeleted ? .secondary : (entry.isDirectory ? .accentColor : .secondary))
                .frame(width: 16)
            Text(entry.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if entry.isDeleted {
                Text(L.t("Deleted"))
                    .font(.caption2)
                    .foregroundColor(.red)
            }
            Text(entry.isDirectory ? "" : state.byteCountString(Int(entry.size)))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text("0x" + String(entry.dataOffset, radix: 16).uppercased())
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.25) : Color.clear)
        .opacity(entry.isDeleted ? 0.6 : 1)
    }
}
