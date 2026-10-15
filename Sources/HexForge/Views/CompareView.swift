import SwiftUI

struct CompareView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Compare With File").font(.headline)

            Text("Compares the open document against another file and marks every differing byte.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Text("File")
                    .frame(width: 70, alignment: .leading)
                TextField("path to the file to compare against", text: $state.comparePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(state.isComparing)
                Button("Browse…") { state.chooseCompareFile() }
                    .disabled(state.isComparing)
            }

            HStack(spacing: 8) {
                Text(state.document.fileName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("vs")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(state.comparePath.isEmpty ? "—" : (state.comparePath as NSString).lastPathComponent)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
            }

            if state.isComparing {
                ProgressView().scaleEffect(0.7, anchor: .leading)
            }

            if !state.compareSummary.isEmpty {
                Text(state.compareSummary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Previous Diff") { state.gotoPreviousDifference() }
                    .disabled(state.compareDifferences.isEmpty)
                Button("Next Diff") { state.gotoNextDifference() }
                    .disabled(state.compareDifferences.isEmpty)
                Spacer()
                Button("Clear") { state.clearCompare() }
                    .disabled(state.compareDifferences.isEmpty && state.compareSummary.isEmpty)
            }

            Divider()

            if state.compareDifferences.isEmpty {
                Spacer()
                Text(state.compareSummary.isEmpty
                     ? "Choose a file and press Compare."
                     : "No differences stored.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(state.compareDifferences) { diff in
                            Button {
                                state.goto(offset: diff.offset)
                            } label: {
                                HStack(spacing: 10) {
                                    Text("0x\(String(diff.offset, radix: 16).uppercased())")
                                        .font(.system(size: 11, design: .monospaced))
                                        .frame(width: 110, alignment: .leading)
                                    Text("\(diff.length)B")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .frame(width: 50, alignment: .leading)
                                    Text(hex(diff.aBytes))
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundColor(.green)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(hex(diff.bBytes))
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundColor(.red)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 6)
                        }
                    }
                }
                .frame(minHeight: 120)
            }

            Spacer(minLength: 0)

            HStack {
                if state.isComparing {
                    Button("Cancel") { state.cancelCompare() }
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(state.isComparing)
                Button("Compare") { state.runCompare() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.isComparing || state.comparePath.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 700, height: 480)
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.isEmpty ? "—" : bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}