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
    }
}

// MARK: - Toolbar

struct TopBarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            Button(action: state.openFile) {
                Label("Open", systemImage: "folder")
            }
            Button(action: state.save) {
                Label("Save", systemImage: "square.and.arrow.down")
            }

            Divider().frame(height: 18)

            Button(action: { state.showGoto = true }) {
                Label("Goto", systemImage: "arrow.right.to.line")
            }
            Button(action: { state.showFind = true }) {
                Label("Find", systemImage: "magnifyingglass")
            }

            Menu {
                Button("Compute Hash / Checksum…") { state.showHash = true }
                Button("Structure Templates…") { state.showTemplates = true }
                Button("Load Template File…") { state.loadTemplates() }
                Divider()
                Button("Disk Clone…") { state.showClone = true }
                Button("Disk Image & Backup…") { state.showImage = true }
                Button("Compare With File…") { state.showCompare = true }
                Button("Sector / Cluster View…") { state.showSector = true }
                Divider()
                Button("Encrypt / Convert…") { state.showTransform = true }
                Button("Byte Statistics…") { state.showStatistics = true }
                Button("File Tools…") { state.showFileTools = true }
            } label: {
                Label("Tools", systemImage: "wrench.and.screwdriver")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Divider().frame(height: 18)

            Picker("Cols", selection: $state.bytesPerRow) {
                Text("8").tag(8)
                Text("16").tag(16)
                Text("24").tag(24)
                Text("32").tag(32)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .help("Bytes per row")

            Toggle("ASCII", isOn: $state.showAscii)
                .toggleStyle(.switch)

            Toggle(isOn: $state.showInspector) {
                Image(systemName: "sidebar.right")
            }
            .toggleStyle(.button)
            .help("Toggle data inspector")

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
            Text("Offset: 0x\(String(state.cursor, radix: 16).uppercased())")
                .monospaced()
            Text("Cursor: \(state.cursor)")
                .monospaced()
            if state.addressMode != .fileOffset {
                Text("Sector: \(state.cursorSector)  ·  Cluster: \(state.cursorCluster)")
                    .monospaced()
            }
            if state.hasSelection {
                Text("Sel: \(state.selectionLength) byte(s)")
                    .monospaced()
            }
            Text("Size: \(state.byteCountString(state.size)) (\(state.size) bytes)")
                .monospaced()
            Text("Pane: \(state.activePane == .hex ? "Hex" : "ASCII")")
                .monospaced()
            if state.isReadOnly {
                Text("READ-ONLY").foregroundColor(.orange).bold()
            }
            if state.isDirty {
                Text("MODIFIED").foregroundColor(.red).bold()
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