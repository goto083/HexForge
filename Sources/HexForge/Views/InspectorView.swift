import SwiftUI

struct InspectorView: View {
    @EnvironmentObject var state: AppState

    private var interpretedBuffer: [UInt8] {
        guard state.size > 0 else { return [] }
        let start = state.cursor
        let end = min(state.size, start + 32)
        guard start < end else { return [] }
        return state.document.bytes(in: start..<end)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L.t("Data Inspector"))
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)

            Text(L.f("Offset 0x%@  ·  %d byte(s)", String(state.cursor, radix: 16).uppercased(), state.selectionLength))
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Divider()

            let values = DataInterpreter.interpret(interpretedBuffer)
            if values.isEmpty {
                Spacer()
                Text(L.t("No data at cursor.\\nOpen a file to inspect its bytes."))
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(values) { value in
                            HStack(spacing: 8) {
                                Text(value.name)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .frame(width: 130, alignment: .leading)
                                Text(value.value)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .textSelection(.enabled)
                                Spacer()
                                Text("\(value.length)B")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}