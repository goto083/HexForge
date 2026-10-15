import SwiftUI

struct FileToolsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    private struct SizeChoice: Identifiable {
        let id: String
        let bytes: Int64
    }

    private struct GenPreset: Identifiable {
        let id: String
        let value: String
    }

    private static let sizeChoices: [SizeChoice] = [
        SizeChoice(id: "10 MB", bytes: 10 * 1_000_000),
        SizeChoice(id: "20 MB", bytes: 20 * 1_000_000),
        SizeChoice(id: "100 MB", bytes: 100 * 1_000_000),
        SizeChoice(id: "700 MB (CD)", bytes: 700 * 1024 * 1024),
        SizeChoice(id: "2 GB", bytes: 2 * 1024 * 1024 * 1024),
        SizeChoice(id: "4 GB (FAT32)", bytes: 4 * 1024 * 1024 * 1024)
    ]

    private static let generatePresets: [GenPreset] = [
        GenPreset(id: "16", value: "16"),
        GenPreset(id: "256", value: "256"),
        GenPreset(id: "1 KiB", value: "1k"),
        GenPreset(id: "4 KiB", value: "4k"),
        GenPreset(id: "64 KiB", value: "64k"),
        GenPreset(id: "1 MiB", value: "1M"),
        GenPreset(id: "16 MiB", value: "16M")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("File Tools").font(.headline)
                Spacer()
                Picker("", selection: $state.fileToolTab) {
                    ForEach(FileToolTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)
            }

            Divider()

            switch state.fileToolTab {
            case .generate: generateForm
            case .split:    splitForm
            case .join:     joinForm
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 560)
        .onAppear {
            if state.splitSource.isEmpty, let url = state.document.url {
                state.splitSource = url.path
                if state.splitBaseName.isEmpty { state.splitBaseName = url.lastPathComponent }
            }
        }
    }

    // MARK: - Random data

    private var generateForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generate cryptographically-secure random bytes directly into the open document.")
                .font(.caption)
                .foregroundColor(.secondary)

            row("Mode") {
                Picker("", selection: $state.randomGenerateMode) {
                    ForEach(RandomGenerateMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 240)
                .disabled(state.isGenerating)
                Spacer()
            }

            row("Count") {
                TextField("256, 4k, 1M…", text: $state.randomGenerateCountText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 140)
                    .disabled(state.isGenerating)
                ForEach(Self.generatePresets) { preset in
                    Button(preset.id) { state.randomGenerateCountText = preset.value }
                        .disabled(state.isGenerating)
                }
                Spacer()
            }

            Text("Up to \(state.byteCountString(FileTools.maxGenerateBytes)) can be generated into the editor per edit.")
                .font(.caption2)
                .foregroundColor(.secondary)

            progressBlock(progress: state.generateProgress,
                          status: state.randomGenerateStatus,
                          visible: state.isGenerating || !state.randomGenerateStatus.isEmpty)

            HStack {
                if state.isGenerating {
                    Button("Cancel") { state.cancelGenerate() }
                }
                Spacer()
                Button("Generate") { state.generateRandomData() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.isGenerating)
            }
        }
    }

    // MARK: - Split

    private var splitForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Split a file into ordered parts named name.001, name.002, …")
                .font(.caption)
                .foregroundColor(.secondary)

            row("Source") {
                TextField("source file", text: $state.splitSource)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(state.isSplitting)
                Button("File…") { state.chooseSplitSource() }.disabled(state.isSplitting)
            }

            row("Destination") {
                TextField("folder for the parts", text: $state.splitFolder)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(state.isSplitting)
                Button("Folder…") { state.chooseSplitFolder() }.disabled(state.isSplitting)
            }

            row("Base name") {
                TextField("derived from source when empty", text: $state.splitBaseName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(state.isSplitting)
            }

            row("Split by") {
                Picker("", selection: $state.splitMode) {
                    ForEach(FileSplitMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                .disabled(state.isSplitting)

                if state.splitMode == .bySize {
                    Picker("", selection: $state.splitPartSize) {
                        ForEach(Self.sizeChoices) { choice in
                            Text(choice.id).tag(choice.bytes)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    .disabled(state.isSplitting)
                } else {
                    TextField("parts", text: $state.splitPartCountText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 90)
                        .disabled(state.isSplitting)
                }
                Spacer()
            }

            progressBlock(progress: state.splitProgress,
                          status: state.splitStatus,
                          visible: state.isSplitting || !state.splitStatus.isEmpty)

            HStack {
                if state.isSplitting {
                    Button("Cancel") { state.cancelSplit() }
                }
                Spacer()
                Button("Start Split") { state.startSplit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.isSplitting)
            }
        }
    }

    // MARK: - Join

    private var joinForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Join ordered parts back into a single output file.")
                .font(.caption)
                .foregroundColor(.secondary)

            row("Parts folder") {
                TextField("folder containing the parts", text: $state.joinInputFolder)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(state.isJoining)
                Button("Folder…") { state.chooseJoinFolder() }.disabled(state.isJoining)
                Button("Scan") { state.scanJoinFolder() }.disabled(state.isJoining)
            }

            row("Parts") {
                Button("Add Parts…") { state.chooseJoinParts() }.disabled(state.isJoining)
                Button("Clear") { state.clearJoinParts() }.disabled(state.isJoining)
                Spacer()
                Text("\(state.joinFilePaths.count) queued")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            row("Output") {
                TextField("output file", text: $state.joinDestination)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(state.isJoining)
                Button("File…") { state.chooseJoinDestination() }.disabled(state.isJoining)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(state.joinFilePaths.enumerated()), id: \.offset) { index, path in
                        HStack(spacing: 8) {
                            Text(String(format: "%03d", index + 1))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 34, alignment: .leading)
                            Text((path as NSString).lastPathComponent)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            Text(state.byteCountString(state.fileSize(atPath: path)))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))

            progressBlock(progress: state.joinProgress,
                          status: state.joinStatus,
                          visible: state.isJoining || !state.joinStatus.isEmpty)

            HStack {
                if state.isJoining {
                    Button("Cancel") { state.cancelJoin() }
                }
                Spacer()
                Button("Start Join") { state.startJoin() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.isJoining)
            }
        }
    }

    // MARK: - Shared pieces

    @ViewBuilder
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 96, alignment: .leading)
            content()
        }
    }

    @ViewBuilder
    private func progressBlock(progress: Double, status: String, visible: Bool) -> some View {
        if visible {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: min(1, max(0, progress)))
                Text(status)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
