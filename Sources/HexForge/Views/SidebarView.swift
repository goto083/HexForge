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

        }
        .frame(maxWidth: .infinity, alignment: .leading)
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