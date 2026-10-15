import SwiftUI

struct TransformView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Encrypt / Convert").font(.headline)
            Text("Applies a byte transform to the selection or the whole file. Every operation is a single undoable edit.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Text("Scope").frame(width: 80, alignment: .leading)
                if state.hasSelection {
                    Picker("", selection: $state.transformScopeIsSelection) {
                        Text("Selection (\(state.selectionLength) byte(s))").tag(true)
                        Text("Whole file (\(state.size) byte(s))").tag(false)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 320)
                } else {
                    Text("Whole file (\(state.size) byte(s))")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            HStack {
                Text("Operation").frame(width: 80, alignment: .leading)
                Picker("", selection: $state.transformOperation) {
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
                    Text("Key").frame(width: 80, alignment: .leading)
                    TextField(state.transformKeyIsHex ? "hex, e.g. DE AD BE EF" : "text key",
                              text: $state.transformKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Toggle("Hex", isOn: $state.transformKeyIsHex)
                        .toggleStyle(.checkbox)
                }
            }

            if state.transformOperation.usesConstant {
                HStack {
                    Text("Constant").frame(width: 80, alignment: .leading)
                    TextField("0x00–0xFF", text: $state.transformConstant)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 120)
                    Spacer()
                }
            }

            if state.transformOperation.usesWordSize {
                HStack {
                    Text("Word").frame(width: 80, alignment: .leading)
                    Picker("", selection: $state.transformWordSize) {
                        Text("16-bit").tag(2)
                        Text("32-bit").tag(4)
                        Text("64-bit").tag(8)
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    Spacer()
                }
            }

            if state.transformOperation.isCipher {
                HStack {
                    Text("Mode").frame(width: 80, alignment: .leading)
                    Picker("", selection: $state.transformECBMode) {
                        Text("ECB").tag(true)
                        Text("CBC").tag(false)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    Spacer()
                }
                if !state.transformECBMode {
                    HStack {
                        Text("IV").frame(width: 80, alignment: .leading)
                        TextField("hex IV (16 bytes for AES, 8 for DES)", text: $state.transformIV)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                Text("Keys are normalised to the nearest valid length (AES 16/24/32, DES 8); PKCS#7 padding is added/removed.")
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
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { state.applyTransform() }
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