import SwiftUI
import AppKit

/// WinHex-style hit list, docked in the main window above the hex view.
///
/// Appears after a successful "Find All" (the dialog closes itself). Clicking
/// a row selects the match in the hex view and scrolls to it — same gesture as
/// clicking a row in WinHex's search-result window.
struct SearchResultsView: View {
    @EnvironmentObject var state: AppState

    private let mono = Font.system(.body, design: .monospaced)

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.indent")
                    .foregroundColor(.secondary)
                Text(L.f("Results (%d)", state.searchTotalFound))
                    .font(.subheadline).bold()
                if !state.searchStatus.isEmpty {
                    Text(state.searchStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    state.showHitList = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help(L.t("Close"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Column headers
            HStack(spacing: 0) {
                Text("#")
                    .frame(width: 56, alignment: .trailing)
                Text(L.t("Offset"))
                    .frame(width: 110, alignment: .leading)
                    .padding(.leading, 12)
                Text(L.t("Decimal"))
                    .frame(width: 110, alignment: .leading)
                Text(L.t("Matched bytes"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            Divider()

            // Rows
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(state.searchResults.indices, id: \.self) { index in
                        let hit = state.searchResults[index]
                        let selected = state.selectedHitOffset == hit.offset
                        Button {
                            state.jumpToSearchHit(hit)
                        } label: {
                            HStack(spacing: 0) {
                                Text("\(index + 1)")
                                    .frame(width: 56, alignment: .trailing)
                                Text("0x" + String(hit.offset, radix: 16).uppercased())
                                    .frame(width: 110, alignment: .leading)
                                    .padding(.leading, 12)
                                Text("\(hit.offset)")
                                    .frame(width: 110, alignment: .leading)
                                Text(state.searchHitPreview(hit))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .font(mono)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity)
                            .background(selected ? Color.accentColor.opacity(0.25) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.primary)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}
