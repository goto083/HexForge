import SwiftUI

struct CloneView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Disk Clone").font(.headline)

            Text("Copies a source file or raw device to a destination image/device, byte for byte.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Text("Source")
                    .frame(width: 90, alignment: .leading)
                TextField("path, or /dev/rdisk2", text: $state.cloneSource)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(state.isCloning)
                Button("File…") { state.chooseCloneSource() }
                    .disabled(state.isCloning)
                Button("Device…") { state.chooseCloneDevice() }
                    .disabled(state.isCloning)
            }

            HStack {
                Text("Destination")
                    .frame(width: 90, alignment: .leading)
                TextField("output image path", text: $state.cloneDestination)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(state.isCloning)
                Button("File…") { state.chooseCloneDestination() }
                    .disabled(state.isCloning)
            }

            HStack {
                Text("Block size")
                    .frame(width: 90, alignment: .leading)
                Picker("", selection: $state.cloneBlockSize) {
                    Text("512 B").tag(512)
                    Text("4 KiB").tag(4096)
                    Text("64 KiB").tag(65536)
                    Text("1 MiB").tag(1 << 20)
                    Text("4 MiB").tag(4 << 20)
                }
                .labelsHidden()
                .frame(width: 140)

                Toggle("Verify after write", isOn: $state.cloneVerify)
                    .disabled(state.isCloning)
                Spacer()
            }

            if state.isCloning || !state.cloneStatus.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if state.cloneTotalBytes > 0 {
                        ProgressView(value: state.cloneProgress)
                    } else {
                        ProgressView()
                    }
                    Text(state.cloneStatus)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 0)

            HStack {
                if state.isCloning {
                    Button("Cancel Clone") { state.cancelClone() }
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(state.isCloning)
                Button("Start Clone") { state.startClone() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.isCloning)
            }
        }
        .padding(20)
        .frame(width: 640, height: 330)
        .onAppear {
            if state.cloneSource.isEmpty, let url = state.document.url {
                state.cloneSource = url.path
            }
        }
    }
}