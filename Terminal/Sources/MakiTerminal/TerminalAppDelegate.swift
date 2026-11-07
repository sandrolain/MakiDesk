import AppKit

final class TerminalAppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: TerminalAppDelegate?

    private var runtime: GhosttyRuntime?
    private var terminal: TerminalWindowController?
    private var server: TerminalIPCServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self

        do {
            runtime = try GhosttyRuntime()
        } catch {
            let alert = NSAlert()
            alert.messageText = "MakiDesk Terminal could not start"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        guard let runtime else { return }

        let controller = TerminalWindowController(runtime: runtime)
        terminal = controller
        runtime.onSurfaceClosed = { [weak controller] view in
            controller?.paneDidExit(view)
        }
        runtime.onTitle = { [weak controller] view, title in
            controller?.updateTitle(for: view, title: title)
        }
        runtime.onDirectory = { [weak controller] view, path in
            controller?.updateDirectory(for: view, path: path)
        }

        installMenu(target: controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        startServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        terminal?.saveNow()
        terminal?.detachAllPanes()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - IPC

    private func startServer() {
        let server = TerminalIPCServer()
        server.onShowMain = { [weak self] in self?.showMain() }
        server.onHideMain = { [weak self] in self?.hideMain() }
        // The quake panel is F1b; until it exists, the command brings the main
        // window forward instead of silently doing nothing.
        server.onToggleQuake = { [weak self] in self?.showMain() }
        server.onQuit = { NSApp.terminate(nil) }
        server.start { started in
            guard started == false else { return }
            // Another helper owns the socket; this launch is a duplicate.
            NSApp.terminate(nil)
        }
        self.server = server
    }

    func showMain() {
        guard let window = terminal?.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        terminal?.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func hideMain() {
        terminal?.window?.orderOut(nil)
    }

    // MARK: - Menu

    private func installMenu(target: TerminalWindowController) {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About MakiDesk Terminal",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MakiDesk Terminal",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        menu(fileMenu, "New Workspace",
             #selector(TerminalWindowController.newWorkspaceAction(_:)),
             "t", [], target)
        menu(fileMenu, "New Split Right",
             #selector(TerminalWindowController.splitRightAction(_:)),
             "d", [], target)
        menu(fileMenu, "New Split Down",
             #selector(TerminalWindowController.splitDownAction(_:)),
             "d", [.shift], target)
        fileMenu.addItem(.separator())
        menu(fileMenu, "Close Pane",
             #selector(TerminalWindowController.closePaneAction(_:)),
             "w", [], target)
        menu(fileMenu, "Close Workspace",
             #selector(TerminalWindowController.closeWorkspaceAction(_:)),
             "w", [.shift], target)
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(TerminalSurfaceView.copy(_:)),
                         keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(TerminalSurfaceView.paste(_:)),
                         keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(TerminalSurfaceView.selectAll(_:)),
                         keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    private func menu(_ menu: NSMenu,
                      _ title: String,
                      _ action: Selector,
                      _ key: String,
                      _ modifiers: NSEvent.ModifierFlags,
                      _ target: AnyObject) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = NSEvent.ModifierFlags.command.union(modifiers)
        item.target = target
        menu.addItem(item)
    }
}
