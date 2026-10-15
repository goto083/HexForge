import SwiftUI

struct TransformView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.t("Encrypt / Convert")).font(.headline)
            Text(L.t("Applies a byte transform to the selection or the whole file. Every operation is a single undoable edit."))
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Text(L.t("Scope")).frame(width: 80, alignment: .leading)
                if state.hasSelection {
                    Picker(L.t(""), selection: $state.transformScopeIsSelection) {
                        Text(L.f("Selection (%d byte(s))", state.selectionLength)).tag(true)
                        Text(L.f("Whole file (%d byte(s))", state.size)).tag(false)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 320)
                } else {
                    Text(L.f("Whole file (%d byte(s))", state.size))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            HStack {
                Text(L.t("Operation")).frame(width: 80, alignment: .leading)
                Picker(L.t(""), selection: $state.transformOperation) {
                    ForEach(TransformOperation.allCases) { op in
                        Text(op.rawValue).tag(op)
                    }
                }
                .labelsHidden()
                .frame(width: 260)
            }

            Text(state.transformOperation.description)
                .font(.caption)
                .foregroundColor(.secondary)

            if state.transformOperation.usesKey {
                HStack {
                    Text(L.t("Key")).frame(width: 80, alignment: .leading)
                    TextField(state.transformKeyIsHex ? "hex, e.g. DE AD BE EF" : "text key",
                              text: $state.transformKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Toggle(L.t("Hex"), isOn: $state.transformKeyIsHex)
                        .toggleStyle(.checkbox)
                }
            }

            if state.transformOperation.usesConstant {
                HStack {
                    Text(L.t("Constant")).frame(width: 80, alignment: .leading)
                    TextField(L.t("0x00–0xFF"), text: $state.transformConstant)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 120)
                    Spacer()
                }
            }

            if state.transformOperation.usesWordSize {
                HStack {
                    Text(L.t("Word")).frame(width: 80, alignment: .leading)
                    Picker(L.t(""), selection: $state.transformWordSize) {
                        Text(L.t("16-bit")).tag(2)
                        Text(L.t("32-bit")).tag(4)
                        Text(L.t("64-bit")).tag(8)
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    Spacer()
                }
            }

            if state.transformOperation.isCipher {
                HStack {
                    Text(L.t("Mode")).frame(width: 80, alignment: .leading)
                    Picker(L.t(""), selection: $state.transformECBMode) {
                        Text(L.t("ECB")).tag(true)
                        Text(L.t("CBC")).tag(false)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    Spacer()
                }
                if !state.transformECBMode {
                    HStack {
                        Text(L.t("IV")).frame(width: 80, alignment: .leading)
                        TextField(L.t("hex IV (16 bytes for AES, 8 for DES)"), text: $state.transformIV)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                Text(L.t("Keys are normalised to the nearest valid length (AES 16/24/32, DES 8); PKCS#7 padding is added/removed."))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if !state.transformStatus.isEmpty {
                Text(state.transformStatus)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(L.t("Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L.t("Apply")) { state.applyTransform() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.size == 0 || state.isReadOnly)
            }
        }
        .padding(20)
        .frame(width: 640, height: 420)
        .onAppear {
            if !state.hasSelection { state.transformScopeIsSelection = false }
        }
    }
}