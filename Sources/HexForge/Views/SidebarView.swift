import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L.t("File"))
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 4) {
                infoRow("Name", state.fileName)
                infoRow("Format", state.detectedFormat ?? "Unknown")
                infoRow("Size", "\(state.byteCountString(state.size))")
                infoRow("Bytes", "\(state.size)")
                infoRow("Edited", "\(state.document.editedByteCount) byte(s)")
                infoRow("Mode", state.isReadOnly ? "Read-only" : "Read/Write")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            Divider()

            HStack {
                Text(L.t("Bookmarks"))
                    .font(.headline)
                Spacer()
                Button {
                    state.addBookmarkAtCursor()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help(L.t("Add bookmark at cursor"))
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            if state.bookmarks.isEmpty {
                Text(L.t("No bookmarks. Press ⌘D to add one."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                Spacer()
            } else {
                List {
                    ForEach(state.bookmarks) { bookmark in
                        Button {
                            state.goto(offset: bookmark.offset)
                        } label: {
                            HStack {
                                Image(systemName: "bookmark.fill").foregroundColor(.accentColor)
                                Text(bookmark.name).font(.system(.body, design: .monospaced))
                                Spacer()
                                Text("\(bookmark.offset)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(L.t("Delete")) {
                                state.bookmarks.removeAll { $0.id == bookmark.id }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundColor(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11))
    }
}