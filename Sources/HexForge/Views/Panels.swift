import SwiftUI
import AppKit

// MARK: - Find / Replace

struct FindView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Find & Replace").font(.headline)

            Picker("Mode", selection: $state.findMode) {
                ForEach(FindMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Find")
                    .frame(width: 70, alignment: .leading)
                TextField(state.findMode == .hex ? "e.g. 4D 5A ?? 00" : "text to search",
                          text: state.findMode == .hex ? $state.findHex : $state.findText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            if state.findMode == .text {
                Toggle("Case sensitive", isOn: $state.caseSensitive)
            }

            HStack {
                Text("Replace")
                    .frame(width: 70, alignment: .leading)
                TextField(state.findMode == .hex ? "hex bytes, same length" : "replacement text, same length",
                          text: $state.replaceWith)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            Text("Note: replacement is fixed-length (overwrite). Use Edit ▸ Insert Bytes… or Delete Selection to change the file length.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Button("Find Previous") { state.findPrevious() }
                Button("Find Next") { state.findNext() }
                Spacer()
                Button("Replace All") { state.replaceAll() }
                    .disabled(state.isReadOnly)
                Button("Close") { dismiss() }
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
            Text("Goto Offset").font(.headline)

            TextField("Offset — hex by default, or 0d for decimal", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(go)

            Text("Examples: 1F40  ·  0x1F40  ·  0d8000")
                .font(.caption)
                .foregroundColor(.secondary)

            if let error {
                Text(error).font(.caption).foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Go", action: go).keyboardShortcut(.defaultAction)
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
            Text("Fill Selection").font(.headline)

            Text("Target: \(state.hasSelection ? "\(state.selectionLength) selected byte(s)" : "current byte only")")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Text("Value")
                    .frame(width: 70, alignment: .leading)
                TextField("hex byte (e.g. 00, FF) or single char", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            if let error {
                Text(error).font(.caption).foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Fill", action: fill).keyboardShortcut(.defaultAction)
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
            Text("Insert Bytes").font(.headline)

            Text("Inserted at offset \(state.cursor) (0x\(String(state.cursor, radix: 16).uppercased())), growing the file.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Text("Hex")
                    .frame(width: 70, alignment: .leading)
                TextField("e.g. DE AD BE EF", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(insert)
            }

            if let error {
                Text(error).font(.caption).foregroundColor(.red)
            }

            HStack {
                Button("From Clipboard") {
                    if let s = NSPasteboard.general.string(forType: .string) {
                        text = s
                        error = nil
                    } else {
                        error = "Clipboard does not contain text."
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Insert", action: insert).keyboardShortcut(.defaultAction)
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
            Text("Hash / Checksum").font(.headline)

            Picker("Scope", selection: $scopeSelection) {
                Text("Whole file").tag(false)
                Text("Selection").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(!state.hasSelection)

            HStack {
                Button {
                    state.computeHashes(overSelection: scopeSelection)
                } label: {
                    Label("Compute", systemImage: "play.fill")
                }
                .disabled(!state.hasContent || state.isHashing)

                if state.isHashing {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Copy All") { copyAll() }
                    .disabled(state.hashResults.isEmpty)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
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