import SwiftUI

/// Floating data-interpreter palette (hosted in an NSPanel by AppDelegate).
///
/// WinHex-style minimal set: unsigned 16/32/64-bit at the cursor, with a
/// little/big-endian toggle. Updates live as the cursor moves.
struct InterpreterPanelView: View {
    @EnvironmentObject var state: AppState

    private static let grouped: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        return nf
    }()

    private var buffer: [UInt8] {
        guard state.size > 0, state.cursor < state.size else { return [] }
        return state.document.bytes(in: state.cursor..<min(state.size, state.cursor + 8))
    }

    private func value(_ width: Int) -> String {
        let b = buffer
        guard b.count >= width else { return "—" }
        let raw = state.inspectorBigEndian ? DataInterpreter.be(b, width) : DataInterpreter.le(b, width)
        return Self.grouped.string(from: NSNumber(value: raw)) ?? String(raw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L.f("Offset 0x%@", String(state.cursor, radix: 16).uppercased()))
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            row(L.t("16 Bit Unsigned"), value(2))
            Divider().padding(.leading, 12)
            row(L.t("32 Bit Unsigned"), value(4))
            Divider().padding(.leading, 12)
            row(L.t("64 Bit Unsigned"), value(8))

            Divider().padding(.vertical, 8)

            HStack {
                Text(L.t("Endianness"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Picker("", selection: $state.inspectorBigEndian) {
                    Text(L.t("Little-endian")).tag(false)
                    Text(L.t("Big-endian")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .frame(minWidth: 280)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
