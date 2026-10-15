import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    let state = AppState()
    private var window: NSWindow!
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        // Menu titles are AppKit strings, so they need a rebuild whenever the
        // language changes.
        state.$language
            .dropFirst()
            .sink { [weak self] _ in self?.buildMenu() }
            .store(in: &cancellables)

        let root = ContentView().environmentObject(state)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "HexForge"
        window.minSize = NSSize(width: 860, height: 520)
        window.contentView = NSHostingView(rootView: root)
        _ = window.setFrameAutosaveName("HexForge.MainWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)

        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu construction

    private func buildMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(sysItem(L.t("About HexForge"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", []))
        appMenu.addItem(.separator())

        // Language submenu — titles stay in their own script so the choice is
        // readable no matter which language is active.
        let languageItem = NSMenuItem(title: L.t("Language"), action: nil, keyEquivalent: "")
        let languageMenu = NSMenu(title: L.t("Language"))
        for language in AppLanguage.allCases {
            let entry = NSMenuItem(title: language.endonym, action: #selector(changeLanguage(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = language.rawValue
            entry.state = (state.language == language) ? .on : .off
            languageMenu.addItem(entry)
        }
        languageItem.submenu = languageMenu
        appMenu.addItem(languageItem)
        appMenu.addItem(.separator())

        appMenu.addItem(sysItem(L.t("Hide HexForge"), #selector(NSApplication.hide(_:)), "h", [.command]))
        appMenu.addItem(sysItem(L.t("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(sysItem(L.t("Show All"), #selector(NSApplication.unhideAllApplications(_:)), "", []))
        appMenu.addItem(.separator())
        appMenu.addItem(sysItem(L.t("Quit HexForge"), #selector(NSApplication.terminate(_:)), "q", [.command]))

        // File
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: L.t("File"))
        fileItem.submenu = fileMenu
        fileMenu.addItem(item(L.t("Open…"), #selector(openDocument(_:)), "o", [.command]))
        fileMenu.addItem(item(L.t("Open Raw Device…"), #selector(openDevice(_:)), "", []))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item(L.t("Save"), #selector(saveDocument(_:)), "s", [.command]))
        fileMenu.addItem(item(L.t("Save As…"), #selector(saveDocumentAs(_:)), "s", [.command, .shift]))
        fileMenu.addItem(.separator())
        fileMenu.addItem(sysItem(L.t("Close Window"), #selector(NSWindow.performClose(_:)), "w", [.command]))

        // Edit
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: L.t("Edit"))
        editItem.submenu = editMenu
        editMenu.addItem(item(L.t("Undo byte edit"), #selector(undoEdit(_:)), "z", [.command]))
        editMenu.addItem(item(L.t("Redo byte edit"), #selector(redoEdit(_:)), "z", [.command, .shift]))
        editMenu.addItem(.separator())
        // Standard selectors so text fields in the sheets keep working.
        editMenu.addItem(sysItem(L.t("Cut"), Selector(("cut:")), "x", [.command]))
        editMenu.addItem(sysItem(L.t("Copy"), Selector(("copy:")), "c", [.command]))
        editMenu.addItem(sysItem(L.t("Paste"), Selector(("paste:")), "v", [.command]))
        editMenu.addItem(sysItem(L.t("Select All"), Selector(("selectAll:")), "a", [.command]))
        editMenu.addItem(.separator())
        editMenu.addItem(item(L.t("Find…"), #selector(showFind(_:)), "f", [.command]))
        editMenu.addItem(item(L.t("Goto Offset…"), #selector(showGoto(_:)), "l", [.command]))
        editMenu.addItem(item(L.t("Fill Selection…"), #selector(showFill(_:)), "f", [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(item(L.t("Insert Bytes…"), #selector(showInsert(_:)), "i", [.command, .option]))
        editMenu.addItem(item(L.t("Delete Selection"), #selector(deleteSelectedBytes(_:)), "", []))

        // Tools
        let toolsItem = NSMenuItem()
        mainMenu.addItem(toolsItem)
        let toolsMenu = NSMenu(title: L.t("Tools"))
        toolsItem.submenu = toolsMenu
        toolsMenu.addItem(item(L.t("Compute Hash / Checksum…"), #selector(showHash(_:)), "k", [.command]))
        toolsMenu.addItem(item(L.t("Structure Templates…"), #selector(showTemplates(_:)), "t", [.command]))
        toolsMenu.addItem(item(L.t("Load Template File…"), #selector(loadTemplateFile(_:)), "", []))
        toolsMenu.addItem(item(L.t("Disk Clone…"), #selector(showClone(_:)), "c", [.command, .option]))
        toolsMenu.addItem(item(L.t("Sector / Cluster View…"), #selector(showSectorView(_:)), "", []))
        toolsMenu.addItem(item(L.t("Compare With File…"), #selector(showCompare(_:)), "e", [.command, .option]))
        toolsMenu.addItem(item(L.t("Disk Image & Backup…"), #selector(showImage(_:)), "m", [.command, .option]))
        toolsMenu.addItem(item(L.t("Encrypt / Convert…"), #selector(showTransform(_:)), "y", [.command, .option]))
        toolsMenu.addItem(item(L.t("Byte Statistics…"), #selector(showStatistics(_:)), "b", [.command, .option]))
        toolsMenu.addItem(item(L.t("File Tools…"), #selector(showFileTools(_:)), "f", [.command, .option]))
        toolsMenu.addItem(.separator())
        toolsMenu.addItem(item(L.t("Toggle Data Inspector"), #selector(toggleInspector(_:)), "i", [.command]))

        // Bookmarks
        let bmItem = NSMenuItem()
        mainMenu.addItem(bmItem)
        let bmMenu = NSMenu(title: L.t("Bookmarks"))
        bmItem.submenu = bmMenu
        bmMenu.addItem(item(L.t("Add bookmark at cursor"), #selector(addBookmark(_:)), "d", [.command]))
        bmMenu.addItem(item(L.t("Remove All Bookmarks"), #selector(clearBookmarks(_:)), "", []))

        // Window
        let winItem = NSMenuItem()
        mainMenu.addItem(winItem)
        let winMenu = NSMenu(title: L.t("Window"))
        winItem.submenu = winMenu
        winMenu.addItem(sysItem(L.t("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m", [.command]))
        winMenu.addItem(sysItem(L.t("Zoom"), #selector(NSWindow.performZoom(_:)), "", []))
        NSApp.windowsMenu = winMenu

        NSApp.mainMenu = mainMenu
    }

    /// Menu item routed through the responder chain (system / window actions).
    private func sysItem(_ title: String,
                         _ action: Selector,
                         _ key: String,
                         _ mods: NSEvent.ModifierFlags) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        it.target = nil
        return it
    }

    private func item(_ title: String,
                      _ action: Selector,
                      _ key: String,
                      _ mods: NSEvent.ModifierFlags) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        it.target = self
        return it
    }

    // MARK: - Actions

    @objc private func changeLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = AppLanguage(rawValue: raw) else { return }
        state.language = language
    }

    @objc private func openDocument(_ sender: Any?) { state.openFile() }
    @objc private func openDevice(_ sender: Any?) { state.openDevice() }
    @objc private func saveDocument(_ sender: Any?) { state.save() }
    @objc private func saveDocumentAs(_ sender: Any?) { state.saveAs() }

    @objc private func undoEdit(_ sender: Any?) { state.undo() }
    @objc private func redoEdit(_ sender: Any?) { state.redo() }

    @objc private func showFind(_ sender: Any?) { state.showFind = true }
    @objc private func showGoto(_ sender: Any?) { state.showGoto = true }
    @objc private func showFill(_ sender: Any?) { state.showFill = true }
    @objc private func showInsert(_ sender: Any?) { state.showInsert = true }
    @objc private func deleteSelectedBytes(_ sender: Any?) { state.deleteSelection() }
    @objc private func showHash(_ sender: Any?) { state.showHash = true }
    @objc private func showTemplates(_ sender: Any?) { state.showTemplates = true }
    @objc private func loadTemplateFile(_ sender: Any?) { state.loadTemplates() }
    @objc private func showClone(_ sender: Any?) { state.showClone = true }
    @objc private func showSectorView(_ sender: Any?) { state.showSector = true }
    @objc private func showCompare(_ sender: Any?) { state.showCompare = true }
    @objc private func showImage(_ sender: Any?) { state.showImage = true }
    @objc private func showTransform(_ sender: Any?) { state.showTransform = true }
    @objc private func showStatistics(_ sender: Any?) { state.showStatistics = true }
    @objc private func showFileTools(_ sender: Any?) { state.showFileTools = true }
    @objc private func toggleInspector(_ sender: Any?) { state.showInspector.toggle() }

    @objc private func addBookmark(_ sender: Any?) { state.addBookmarkAtCursor() }
    @objc private func clearBookmarks(_ sender: Any?) { state.bookmarks.removeAll() }
}
