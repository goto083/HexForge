import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            // Left column: file summary, and (when a file system is parsed) the
            // WinHex-style cluster / owner readout where the bookmarks used to be.
            VStack(spacing: 0) {
                SidebarView()
                if state.showFileSystem {
                    Divider()
                    FSInfoPanelView(browser: state.fsBrowser)
                        .frame(maxHeight: .infinity)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(width: 230)
            Divider()
            VStack(spacing: 0) {
                TopBarView()
                Divider()
                // The docked pane above the hex view shows either the file
                // system browser or the search hits — never both. Ctrl+M
                // flips between the two, like WinHex's position manager.
                if state.showHitList && !state.searchResults.isEmpty {
                    SearchResultsView()
                        .frame(height: 200)
                    Divider()
                } else if state.showFileSystem {
                    FileSystemView(browser: state.fsBrowser)
                        .frame(height: 260)
                    Divider()
                }
                HexEditorView()
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StatusBarView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 520)
        .sheet(isPresented: $state.showFind) { FindView() }
        .sheet(isPresented: $state.showGotoSector) { GotoSectorView() }
        .sheet(isPresented: $state.showGotoOffset) { GotoOffsetView() }
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

            Menu {
                Button(L.t("Goto Sector…")) { state.showGotoSector = true }
                Button(L.t("Goto Offset…")) { state.showGotoOffset = true }
            } label: {
                Label(L.t("Goto"), systemImage: "arrow.right.to.line")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
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

    /// Sector size from the parsed file system wins over the manual setting.
    private var sectorSize: Int {
        state.fsSectorSize > 0 ? state.fsSectorSize : max(1, state.sectorSize)
    }
    private var totalSectors: Int {
        if state.showFileSystem, let volume = state.fsBrowser.volume {
            let n = volume.info.volumeLength / sectorSize
            if n > 0 { return n }
        }
        return (state.size + sectorSize - 1) / sectorSize
    }
    /// Logical (volume-relative) sector of the last clicked byte; nil before
    /// the DBR or before anything was clicked.
    private var clickedSector: Int? {
        state.selectedOffset.flatMap { offset -> Int? in
            let relative = offset - state.displayBase
            return relative >= 0 ? relative / sectorSize : nil
        }
    }

    private func grouped(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    var body: some View {
        HStack(spacing: 16) {
            // Sector of the last *clicked* byte — keyboard caret moves do not
            // update it (WinHex-style readout), decimal with thousands separators.
            Text(L.f("Sector: %@ / %@",
                     clickedSector.map(grouped) ?? "—",
                     grouped(totalSectors)))
                .font(.system(.body, design: .monospaced))
            if state.hasSelection {
                let lo = min(state.cursor, state.anchor)
                let hi = max(state.cursor, state.anchor)
                Text(L.f("Block: %@ - %@", grouped(lo), grouped(hi + 1)))
                    .font(.system(.body, design: .monospaced))
                Text(L.f("Block size: %d", state.selectionLength))
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