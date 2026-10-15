import SwiftUI

struct ImageView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    private struct SplitChoice: Identifiable {
        let id: String
        let bytes: Int64
    }

    private struct IntervalChoice: Identifiable {
        let id: String
        let minutes: Int
    }

    /// Split-size choices in bytes (0 = single volume).
    private static let splitChoices: [SplitChoice] = [
        SplitChoice(id: "None", bytes: 0),
        SplitChoice(id: "700 MB (CD)", bytes: 700 * 1024 * 1024),
        SplitChoice(id: "2 GB", bytes: 2 * 1024 * 1024 * 1024),
        SplitChoice(id: "4 GB (FAT32)", bytes: 4 * 1024 * 1024 * 1024),
        SplitChoice(id: "8 GB", bytes: 8 * 1024 * 1024 * 1024)
    ]

    /// Auto-run interval choices in minutes (0 = manual).
    private static let intervalChoices: [IntervalChoice] = [
        IntervalChoice(id: "Manual", minutes: 0),
        IntervalChoice(id: "Every 15 min", minutes: 15),
        IntervalChoice(id: "Hourly", minutes: 60),
        IntervalChoice(id: "Every 6 h", minutes: 360),
        IntervalChoice(id: "Daily", minutes: 1440)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.t("Disk Image & Backup")).font(.headline)
            Text(L.t("Create a disk image from a file or raw device, verify it later, and keep reusable backup jobs."))
                .font(.caption)
                .foregroundColor(.secondary)

            Group {
                row(L.t("Source")) {
                    TextField(L.t("path, or /dev/rdisk2"), text: $state.imageSource)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .disabled(state.isImaging)
                    Button(L.t("File…")) { state.chooseImageSource() }.disabled(state.isImaging)
                    Button(L.t("Device…")) { state.chooseImageDevice() }.disabled(state.isImaging)
                }

                row(L.t("Destination")) {
                    TextField(L.t("folder for the image files"), text: $state.imageDestinationFolder)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .disabled(state.isImaging)
                    Button(L.t("Folder…")) { state.chooseImageDestination() }.disabled(state.isImaging)
                }

                row(L.t("Image name")) {
                    TextField(L.t("derived from source when empty"), text: $state.imageName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .disabled(state.isImaging)
                }
            }

            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Text(L.t("Block")).frame(width: 46, alignment: .leading)
                    Picker(L.t(""), selection: $state.imageBlockSize) {
                        Text(L.t("512 B")).tag(512)
                        Text(L.t("64 KiB")).tag(65536)
                        Text(L.t("1 MiB")).tag(1 << 20)
                        Text(L.t("4 MiB")).tag(4 << 20)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                HStack(spacing: 6) {
                    Text(L.t("Split")).frame(width: 40, alignment: .leading)
                    Picker(L.t(""), selection: $state.imageSplitSize) {
                        ForEach(Self.splitChoices) { choice in
                            Text(L.t(choice.id)).tag(choice.bytes)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .disabled(state.imageCompress)
                }
                Spacer()
            }

            HStack(spacing: 18) {
                Toggle(L.t("Compress (LZFSE)"), isOn: $state.imageCompress)
                    .disabled(state.isImaging)
                Toggle(L.t("Verify after write"), isOn: $state.imageVerify)
                    .disabled(state.isImaging)
                Toggle(L.t("Block checksums"), isOn: $state.imageChecksum)
                    .disabled(state.isImaging)
            }
            .toggleStyle(.checkbox)

            if state.imageCompress {
                Text(L.t("Compressed images are a single volume and cannot be split."))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if state.isImaging || !state.imageStatus.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if state.imageTotalBytes > 0 {
                        ProgressView(value: state.imageProgress)
                    } else {
                        ProgressView()
                    }
                    Text(state.imageStatus)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            if !state.imageVerifyResult.isEmpty {
                Text(state.imageVerifyResult)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if state.isImaging {
                    Button(L.t("Cancel")) { state.cancelImage() }
                }
                Button(L.t("Verify Image…")) { state.verifyImageFile() }
                    .disabled(state.isImaging)
                Button(L.t("Save as Backup Job")) { state.addBackupJob() }
                    .disabled(state.isImaging)
                Spacer()
                Button(L.t("Create Image")) { state.startImage() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.isImaging)
            }

            Divider()

            HStack {
                Text(L.t("Backup jobs")).font(.subheadline).bold()
                Spacer()
                Text("\(state.backupJobs.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if state.backupJobs.isEmpty {
                Text(L.t("No saved jobs. Configure a source/destination above and press “Save as Backup Job”."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(state.backupJobs) { job in
                            jobRow(job)
                            Divider()
                        }
                    }
                }
                .frame(minHeight: 90)
            }

            HStack {
                Spacer()
                Button(L.t("Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 620)
        .sheet(isPresented: $state.showDiskList) { DiskListView() }
    }

    @ViewBuilder
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 90, alignment: .leading)
            content()
        }
    }

    @ViewBuilder
    private func jobRow(_ job: BackupJob) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).font(.system(size: 12, weight: .semibold))
                Text(job.source)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(lastRunText(job))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Picker(L.t(""), selection: intervalBinding(job)) {
                ForEach(Self.intervalChoices) { choice in
                    Text(L.t(choice.id)).tag(choice.minutes)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            Button(L.t("Run")) { state.runBackupJob(job) }
                .disabled(state.isImaging)
            Button(L.t("Delete")) { state.removeBackupJob(job) }
                .disabled(state.isImaging)
        }
        .padding(.vertical, 4)
    }

    private func intervalBinding(_ job: BackupJob) -> Binding<Int> {
        Binding(
            get: { job.intervalMinutes },
            set: { newValue in
                var updated = job
                updated.intervalMinutes = newValue
                state.updateBackupJob(updated)
            }
        )
    }

    private func lastRunText(_ job: BackupJob) -> String {
        guard let last = job.lastRun else { return "Never run" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Last run: " + formatter.string(from: last)
    }
}