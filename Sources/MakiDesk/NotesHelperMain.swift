import AppKit

@MainActor
enum MakiDeskNotesApp {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = MakiDeskNotesAppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class MakiDeskNotesAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        NotesHelperRequestService.shared.start()
        NotesController.shared.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { NotesController.shared.show() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            NotesHelperRequestService.shared.shutdown()
            NotesStore.shared.flushIfNeeded(cleanClose: true)
        }
    }

    private func makeMainMenu() -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About MakiDesk Notes",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide MakiDesk Notes", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit MakiDesk Notes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        menu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        add(fileMenu, "New Note", action: #selector(NotesController.newNoteFromMenu(_:)), key: "t")
        add(fileMenu, "Open…", action: #selector(NotesController.openDocumentFromMenu(_:)), key: "o")
        fileMenu.addItem(.separator())
        add(fileMenu, "Save", action: #selector(NotesController.saveFromMenu(_:)), key: "s")
        add(fileMenu, "Save As…", action: #selector(NotesController.saveAsFromMenu(_:)), key: "s", modifiers: [.command, .shift])
        fileMenu.addItem(.separator())
        add(fileMenu, "Close Note", action: #selector(NotesController.closeNoteFromMenu(_:)), key: "w")

        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = NSMenuItem()
        menu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")

        let helpItem = NSMenuItem()
        menu.addItem(helpItem)
        helpItem.submenu = NSMenu(title: "Help")
        return menu
    }

    private func add(_ menu: NSMenu, _ title: String, action: Selector,
                     key: String, modifiers: NSEvent.ModifierFlags = [.command]) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = NotesController.shared
        item.keyEquivalentModifierMask = modifiers
    }
}
