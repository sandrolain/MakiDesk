import AppKit
import MakiShared
import MakiTerminalCore

final class TerminalAppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: TerminalAppDelegate?

    private var runtime: GhosttyRuntime?
    private var terminal: TerminalWindowController?
    private var server: TerminalIPCServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self

        // A stable, space-free path for `MAKIDESK_CLI`; recreated every launch
        // so a moved app bundle cannot leave a dangling link.
        _ = TerminalCLI.install()
        // Old pasted images are only worth keeping for a while; the scan is
        // small but does not belong on the launch path.
        DispatchQueue.global(qos: .utility).async {
            TerminalImagePaste.prune()
        }
        let settings = TerminalSettingsStore().load()
        let theme = TerminalThemeStore().load()
        do {
            runtime = try GhosttyRuntime(settings: settings, theme: theme)
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

        let controller = TerminalWindowController(runtime: runtime, settings: settings)
        terminal = controller
        runtime.liveSurfaces = { [weak controller] in controller?.allSurfaces ?? [] }
        runtime.onSurfaceClosed = { [weak controller] view in
            controller?.paneDidExit(view)
        }
        runtime.onTitle = { [weak controller] view, title in
            controller?.updateTitle(for: view, title: title)
        }
        runtime.onDirectory = { [weak controller] view, path in
            controller?.updateDirectory(for: view, path: path)
        }
        runtime.onNotification = { [weak self] view, title, body in
            self?.server?.sendAttention(title: title, detail: body)
            self?.terminal?.markAttention(for: view)
        }
        runtime.onCommandFinished = { [weak self] view, code, duration in
            guard CommandAttention.deservesAttention(exitCode: code,
                                                     durationNanos: duration) else { return }
            self?.terminal?.markAttention(for: view)
        }
        runtime.onStartSearch = { [weak controller] view, needle in
            controller?.searchDidStart(for: view, needle: needle)
        }
        runtime.onEndSearch = { [weak controller] view in
            controller?.searchDidEnd(for: view)
        }
        runtime.onSearchTotal = { [weak controller] view, total in
            controller?.searchTotalDidChange(for: view, total: total)
        }
        runtime.onSearchSelected = { [weak controller] view, selected in
            controller?.searchSelectedDidChange(for: view, selected: selected)
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
        server.onToggleQuake = { [weak self] in self?.terminal?.toggleQuake() }
        server.onSettingsChanged = { [weak self] in self?.terminal?.applyTerminalSettings() }
        server.onThemeChanged = { [weak self] in self?.terminal?.applyTerminalSettings() }
        server.onAgentStatus = { [weak self] id, state, label in
            self?.terminal?.setAgentState(state, forWorkspaceID: id, label: label)
        }
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
        terminal?.hideQuakeIfVisible()
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
        editMenu.addItem(.separator())
        menu(editMenu, "Find…",
             #selector(TerminalWindowController.showFindAction(_:)),
             "f", [], target)
        menu(editMenu, "Find Next",
             #selector(TerminalWindowController.findNextAction(_:)),
             "g", [], target)
        menu(editMenu, "Find Previous",
             #selector(TerminalWindowController.findPreviousAction(_:)),
             "g", [.shift], target)
        editItem.submenu = editMenu

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        menu(viewMenu, "Show Quake", #selector(TerminalWindowController.toggleQuake),
             "", [], target)
        viewItem.submenu = viewMenu

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
