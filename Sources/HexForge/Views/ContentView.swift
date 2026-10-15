import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 230)
            Divider()
            VStack(spacing: 0) {
                TopBarView()
                Divider()
                HStack(spacing: 0) {
                    HexEditorView()
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    if state.showInspector {
                        Divider()
                        InspectorView()
                            .frame(width: 320)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StatusBarView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 520)
        .sheet(isPresented: $state.showFind) { FindView() }
        .sheet(isPresented: $state.showSearch) { SearchView() }
        .sheet(isPresented: $state.showGoto) { GotoView() }
        .sheet(isPresented: $state.showFill) { FillView() }
        .sheet(isPresented: $state.showInsert) { InsertView() }
        .sheet(isPresented: $state.showHash) { HashView() }
        .sheet(isPresented: $state.showTemplates) { TemplatesView() }
        .sheet(isPresented: $state.showClone) { CloneView() }
        .sheet(isPresented: $state.showSector) { SectorView() }
        .sheet(isPresented: $state.showCompare) { CompareView() }
        .sheet(isPresented: $state.showImage) { ImageView() }
        .sheet(isPresented: $state.showTransform) { TransformView() }
        .sheet(isPresented: $state.showStatistics) { StatisticsView() }
        .sheet(isPresented: $state.showFileTools) { FileToolsView() }
        .sheet(isPresented: $state.showDiskList) { DiskListView() }
    }
}

// MARK: - Toolbar

struct TopBarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            Button(action: state.openFile) {
                Label(L.t("Open"), systemImage: "folder")
            }
            Button(action: state.save) {
                Label(L.t("Save"), systemImage: "square.and.arrow.down")
            }
            Button(action: { state.presentDiskList(for: .open) }) {
                Label(L.t("Disks"), systemImage: "externaldrive")
            }
            .help(L.t("Open a disk or partition"))

            Divider().frame(height: 18)

            Button(action: { state.showGoto = true }) {
                Label(L.t("Goto"), systemImage: "arrow.right.to.line")
            }
            Button(action: state.openSearch) {
                Label(L.t("Search"), systemImage: "magnifyingglass")
            }
            .help(L.t("Search with wildcards, offset conditions and a result list"))
            Button(action: { state.showFind = true }) {
                Label(L.t("Find & Replace"), systemImage: "text.magnifyingglass")
            }

            Menu {
                Button(L.t("Compute Hash / Checksum…")) { state.showHash = true }
                Button(L.t("Structure Templates…")) { state.showTemplates = true }
                Button(L.t("Load Template File…")) { state.loadTemplates() }
                Divider()
                Button(L.t("Disk Clone…")) { state.showClone = true }
                Button(L.t("Disk Image & Backup…")) { state.showImage = true }
                Button(L.t("Compare With File…")) { state.showCompare = true }
                Button(L.t("Sector / Cluster View…")) { state.showSector = true }
                Divider()
                Button(L.t("Encrypt / Convert…")) { state.showTransform = true }
                Button(L.t("Byte Statistics…")) { state.showStatistics = true }
                Button(L.t("File Tools…")) { state.showFileTools = true }
            } label: {
                Label(L.t("Tools"), systemImage: "wrench.and.screwdriver")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Divider().frame(height: 18)

            Picker(L.t("Cols"), selection: $state.bytesPerRow) {
                Text(L.t("8")).tag(8)
                Text(L.t("16")).tag(16)
                Text(L.t("24")).tag(24)
                Text(L.t("32")).tag(32)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .help(L.t("Bytes per row"))

            Toggle(L.t("ASCII"), isOn: $state.showAscii)
                .toggleStyle(.switch)

            Toggle(isOn: $state.showInspector) {
                Image(systemName: "sidebar.right")
            }
            .toggleStyle(.button)
            .help(L.t("Toggle data inspector"))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Status bar

struct StatusBarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 16) {
            Text(L.f("Offset: 0x%@", String(state.cursor, radix: 16).uppercased()))
                .font(.system(.body, design: .monospaced))
            Text(L.f("Cursor: %d", state.cursor))
                .font(.system(.body, design: .monospaced))
            if state.addressMode != .fileOffset {
                Text(L.f("Sector: %d  ·  Cluster: %d", state.cursorSector, state.cursorCluster))
                    .font(.system(.body, design: .monospaced))
            }
            if state.hasSelection {
                Text(L.f("Sel: %d byte(s)", state.selectionLength))
                    .font(.system(.body, design: .monospaced))
            }
            Text(L.f("Size: %@ (%d bytes)", state.byteCountString(state.size), state.size))
                .font(.system(.body, design: .monospaced))
            Text(L.f("Pane: %@", L.t(state.activePane == .hex ? "Hex" : "ASCII")))
                .font(.system(.body, design: .monospaced))
            if state.isReadOnly {
                Text(L.t("READ-ONLY")).foregroundColor(.orange).bold()
            }
            if state.isDirty {
                Text(L.t("MODIFIED")).foregroundColor(.red).bold()
            }
            Spacer()
            Text(state.statusMessage)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}