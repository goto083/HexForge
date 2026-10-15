import SwiftUI
import AppKit

// MARK: - Find / Replace

struct FindView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.t("Find & Replace")).font(.headline)

            Picker(L.t("Mode"), selection: $state.findMode) {
                ForEach(FindMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text(L.t("Find"))
                    .frame(width: 70, alignment: .leading)
                TextField(state.findMode == .hex ? "e.g. 4D 5A ?? 00" : "text to search",
                          text: state.findMode == .hex ? $state.findHex : $state.findText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            if state.findMode == .text {
                Toggle(L.t("Case sensitive"), isOn: $state.caseSensitive)
            }

            HStack {
                Text(L.t("Replace"))
                    .frame(width: 70, alignment: .leading)
                TextField(state.findMode == .hex ? "hex bytes, same length" : "replacement text, same length",
                          text: $state.replaceWith)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            Text(L.t("Note: replacement is fixed-length (overwrite). Use Edit ▸ Insert Bytes… or Delete Selection to change the file length."))
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Button(L.t("Find Previous")) { state.findPrevious() }
                Button(L.t("Find Next")) { state.findNext() }
                Spacer()
                Button(L.t("Replace All")) { state.replaceAll() }
                    .disabled(state.isReadOnly)
                Button(L.t("Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

// MARK: - Goto offset

struct GotoView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.t("Goto Offset")).font(.headline)

            TextField(L.t("Offset — hex by default, or 0d for decimal"), text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(go)

            Text(L.t("Examples: 1F40  ·  0x1F40  ·  0d8000"))
                .font(.caption)
                .foregroundColor(.secondary)

            if let error {
                Text(error).font(.caption).foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button(L.t("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L.t("Go"), action: go).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func go() {
        guard let offset = OffsetParser.parse(text) else {
            error = "Could not parse offset."
            return
        }
        guard offset < state.size else {
            error = "Offset beyond end of data (\(state.size) bytes)."
            return
        }
        state.goto(offset: offset)
        dismiss()
    }
}

enum OffsetParser {
    static func parse(_ raw: String) -> Int? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        var radix = 16
        if s.hasPrefix("0x") { s.removeFirst(2) }
        else if s.hasPrefix("0d") { s.removeFirst(2); radix = 10 }
        else if s.hasPrefix("0b") {
            s.removeFirst(2)
            return Int(s, radix: 2)
        }
        let cleaned = s.replacingOccurrences(of: "_", with: "")
        return Int(cleaned, radix: radix)
    }
}

// MARK: - Fill selection

struct FillView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var text = "00"
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.t("Fill Selection")).font(.headline)

            Text(L.f("Target: %@", state.hasSelection ? L.f("%d selected byte(s)", state.selectionLength) : L.t("current byte only")))
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Text(L.t("Value"))
                    .frame(width: 70, alignment: .leading)
                TextField(L.t("hex byte (e.g. 00, FF) or single char"), text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            if let error {
                Text(error).font(.caption).foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button(L.t("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L.t("Fill"), action: fill).keyboardShortcut(.defaultAction)
                    .disabled(state.isReadOnly || !state.hasContent)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func fill() {
        guard let byte = parseByte(text) else {
            error = "Enter a hex byte like 00/FF, or a single character."
            return
        }
        state.fillSelection(with: byte)
        dismiss()
    }

    private func parseByte(_ raw: String) -> UInt8? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count == 2, let v = UInt8(s, radix: 16) { return v }
        if s.count == 1, let scalar = s.unicodeScalars.first, scalar.value < 256 {
            return UInt8(scalar.value)
        }
        // allow "0x41"
        if s.lowercased().hasPrefix("0x"), let v = UInt8(String(s.dropFirst(2)), radix: 16) { return v }
        return nil
    }
}

// MARK: - Insert bytes

struct InsertView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.t("Insert Bytes")).font(.headline)

            Text(L.f("Inserted at offset %d (0x%@), growing the file.", state.cursor, String(state.cursor, radix: 16).uppercased()))
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Text(L.t("Hex"))
                    .frame(width: 70, alignment: .leading)
                TextField(L.t("e.g. DE AD BE EF"), text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(insert)
            }

            if let error {
                Text(error).font(.caption).foregroundColor(.red)
            }

            HStack {
                Button(L.t("From Clipboard")) {
                    if let s = NSPasteboard.general.string(forType: .string) {
                        text = s
                        error = nil
                    } else {
                        error = "Clipboard does not contain text."
                    }
                }
                Spacer()
                Button(L.t("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L.t("Insert"), action: insert).keyboardShortcut(.defaultAction)
                    .disabled(state.isReadOnly)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func insert() {
        guard let pattern = BytePattern.parseHex(text), !pattern.bytes.isEmpty else {
            error = "Enter hex bytes, e.g. DE AD BE EF."
            return
        }
        state.insertHex(text)
        dismiss()
    }
}

// MARK: - Hash / checksum

struct HashView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var scopeSelection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.t("Hash / Checksum")).font(.headline)

            Picker(L.t("Scope"), selection: $scopeSelection) {
                Text(L.t("Whole file")).tag(false)
                Text(L.t("Selection")).tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(!state.hasSelection)

            HStack {
                Button {
                    state.computeHashes(overSelection: scopeSelection)
                } label: {
                    Label(L.t("Compute"), systemImage: "play.fill")
                }
                .disabled(!state.hasContent || state.isHashing)

                if state.isHashing {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button(L.t("Copy All")) { copyAll() }
                    .disabled(state.hashResults.isEmpty)
                Button(L.t("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }

            if state.hashResults.isEmpty {
                Text(state.hasContent ? "Run Compute to calculate checksums." : "Open a file first.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.hashResults) { item in
                        HStack(alignment: .top) {
                            Text(item.algorithm)
                                .frame(width: 80, alignment: .leading)
                                .foregroundColor(.secondary)
                            Text(item.value)
                                .font(.system(size: 11.5, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func copyAll() {
        let text = state.hashResults.map { "\($0.algorithm): \($0.value)" }.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        state.statusMessage = "Checksums copied"
    }
}