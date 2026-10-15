import SwiftUI

struct TemplatesView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTemplateID: UUID?
    @State private var fields: [ResolvedField] = []
    @State private var detectionInfo: String?

    private var selectedTemplate: StructureTemplate? {
        state.allTemplates.first { $0.id == selectedTemplateID } ?? state.allTemplates.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L.t("Structure Templates")).font(.headline)
                Spacer()
                Button(L.t("Load…")) { state.loadTemplates() }
                Button(L.t("Clear External")) { state.clearCustomTemplates() }
                    .disabled(state.customTemplates.isEmpty)
                Button(L.t("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }

            // Detected format banner
            HStack(spacing: 8) {
                Image(systemName: detectionInfo == nil ? "questionmark.circle" : "checkmark.seal.fill")
                    .foregroundColor(detectionInfo == nil ? .secondary : .accentColor)
                Text(detectionInfo ?? "No known file signature detected.")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Spacer()
                Button(L.t("Detect")) { autoDetect() }
                    .disabled(!state.hasContent)
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)

            Picker(L.t("Template"), selection: Binding(
                get: { selectedTemplate?.id ?? state.allTemplates[0].id },
                set: { selectedTemplateID = $0 }
            )) {
                ForEach(state.allTemplates) { template in
                    Text(template.name).tag(template.id)
                }
            }

            HStack {
                Button {
                    evaluate(base: state.cursor)
                } label: {
                    Label(L.t("Evaluate at cursor"), systemImage: "wand.and.stars")
                }
                .disabled(!state.hasContent)

                Button {
                    evaluate(base: state.detectedParseOffset)
                } label: {
                    Label(L.f("Evaluate at 0x%@", String(state.detectedParseOffset, radix: 16).uppercased()),
                          systemImage: "scope")
                }
                .disabled(!state.hasContent)

                Spacer()
            }

            Divider()

            if fields.isEmpty {
                Text(state.hasContent
                     ? L.t("Choose a template and evaluate. Auto-detect parses the recognised format at its header offset.")
                     : L.t("Open a file first."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(fields) { field in
                            Button {
                                state.goto(offset: field.offset)
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Text(L.t("0x") + String(field.offset, radix: 16).uppercased())
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .frame(width: 80, alignment: .leading)
                                    Text(field.name)
                                        .font(.system(size: 11))
                                        .frame(width: 200, alignment: .leading)
                                    Text(field.value)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(20)
        .frame(width: 640, height: fields.isEmpty ? 300 : 520)
        .onAppear { autoDetect() }
    }

    /// Detects the file format and, when a template is known, selects it and
    /// evaluates the header automatically.
    private func autoDetect() {
        let signature = state.detectFormat()
        guard let signature else {
            detectionInfo = nil
            fields = []
            return
        }
        detectionInfo = "\(signature.name)  ·  \(signature.magicHex) @ 0x\(String(signature.magicOffset, radix: 16).uppercased())"

        if let name = signature.templateName,
           let template = state.allTemplates.first(where: { $0.name == name }) {
            selectedTemplateID = template.id
            evaluate(base: signature.parseOffset)
        } else {
            fields = []
        }
    }

    private func evaluate(base: Int) {
        guard let template = selectedTemplate else { return }
        fields = StructureTemplate.evaluate(template, in: state.document, base: base)
        state.statusMessage = "Evaluated \(template.name): \(fields.count) field(s)"
    }
}