import SwiftUI

struct SectorView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var sectorField = ""
    @State private var clusterField = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L.t("Sector / Cluster View")).font(.headline)
                Spacer()
                Button(L.t("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }

            HStack {
                Text(L.t("Address column"))
                    .frame(width: 110, alignment: .leading)
                Picker(L.t(""), selection: $state.addressMode) {
                    ForEach(AddressMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                Spacer()
            }

            HStack(spacing: 20) {
                HStack {
                    Text(L.t("Sector size"))
                        .frame(width: 80, alignment: .leading)
                    Picker(L.t(""), selection: $state.sectorSize) {
                        Text(L.t("512")).tag(512)
                        Text(L.t("1024")).tag(1024)
                        Text(L.t("2048")).tag(2048)
                        Text(L.t("4096")).tag(4096)
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
                HStack {
                    Text(L.t("Sectors / cluster"))
                        .frame(width: 120, alignment: .leading)
                    Picker(L.t(""), selection: $state.sectorsPerCluster) {
                        Text(L.t("1")).tag(1)
                        Text(L.t("2")).tag(2)
                        Text(L.t("4")).tag(4)
                        Text(L.t("8")).tag(8)
                        Text(L.t("16")).tag(16)
                        Text(L.t("32")).tag(32)
                        Text(L.t("64")).tag(64)
                        Text(L.t("128")).tag(128)
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                row("Cursor offset", "0x" + hex(state.cursor))
                row("Sector", "\(state.cursorSector)  ·  start 0x\(hex(state.sectorStart(state.cursorSector)))")
                row("Offset in sector", "\(state.cursorOffsetInSector)")
                row("Cluster", "\(state.cursorCluster)  ·  start sector \(state.cursorClusterStartSector)")
                row("Offset in cluster", "\(state.cursorOffsetInCluster)  ·  sector \(state.cursorSectorWithinCluster) of \(state.sectorsPerCluster)")
                row("Totals", "\(state.totalSectors) sector(s)  ·  \(state.totalClusters) cluster(s)  ·  cluster size \(state.clusterSize) B")
            }

            Divider()

            HStack {
                Text(L.t("Goto sector"))
                    .frame(width: 110, alignment: .leading)
                TextField(L.t("decimal or 0x…"), text: $sectorField)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onSubmit(goSector)
                Button(L.t("Go"), action: goSector)
                Spacer()
            }

            HStack {
                Text(L.t("Goto cluster"))
                    .frame(width: 110, alignment: .leading)
                TextField(L.t("decimal or 0x…"), text: $clusterField)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onSubmit(goCluster)
                Button(L.t("Go"), action: goCluster)
                Spacer()
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 600, height: 430)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func hex(_ value: Int) -> String {
        String(value, radix: 16, uppercase: true)
    }

    private func parseNumber(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("0x") {
            return Int(trimmed.dropFirst(2), radix: 16)
        }
        return Int(trimmed)
    }

    private func goSector() {
        guard let index = parseNumber(sectorField), index >= 0 else {
            state.statusMessage = "Enter a sector number (decimal or 0x…)"
            return
        }
        state.goto(sector: index)
        state.statusMessage = "Sector \(index)  ·  offset 0x\(hex(state.cursor))"
        dismiss()
    }

    private func goCluster() {
        guard let index = parseNumber(clusterField), index >= 0 else {
            state.statusMessage = "Enter a cluster number (decimal or 0x…)"
            return
        }
        state.goto(cluster: index)
        state.statusMessage = "Cluster \(index)  ·  offset 0x\(hex(state.cursor))"
        dismiss()
    }
}