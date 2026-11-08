import AppKit
import MakiShared
import MakiTerminalCore

final class TerminalAppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: TerminalAppDelegate?

    private var runtime: GhosttyRuntime?
    private var terminal: TerminalWindowController?
    private var server: TerminalIPCServer?
    /// Set only for a launch that must exit immediately (another helper owns
    /// the socket); the normal quit path always confirms.
    private var suppressQuitConfirmation = false

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
        runtime.onBell = { [weak self] view in
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

    /// Closing the window keeps the sessions alive: the helper stays running as
    /// an accessory app and MakiDesk's ⌃⌥O brings the same window back. Quitting
    /// the app is the only action that ends the shells, so it asks first.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard suppressQuitConfirmation == false else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit MakiDesk Terminal?"
        alert.informativeText = "Every open terminal and its running command will be closed. The workspaces reopen next time, but running work is lost."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit")
        if #available(macOS 11.0, *) {
            alert.buttons.last?.hasDestructiveAction = true
        }
        let reply = alert.runModal()
        if reply != .alertSecondButtonReturn {
            terminal?.restoreFocusAfterAlert()
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if flag == false { showMain() }
        return true
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
            self.suppressQuitConfirmation = true
            NSApp.terminate(nil)
        }
        self.server = server
    }

    func showMain() {
        guard let window = terminal?.window else { return }
        terminal?.hideQuakeIfVisible()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        terminal?.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func hideMain() {
        terminal?.window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Menu

    /// The MakiDesk.app that contains this helper, when the bundle is nested:
    /// `MakiDesk.app/Contents/Applications/MakiDeskTerminal.app`.
    private var containingMakiDesk: URL? {
        let url = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard url.lastPathComponent == "MakiDesk.app",
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    @objc private func openMakiDesk(_ sender: Any?) {
        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.makidesk.app").first {
            running.activate(options: [.activateAllWindows])
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        if let url = containingMakiDesk
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.makidesk.app") {
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        }
    }

    @objc private func openMakiDeskSettings(_ sender: Any?) {
        if let server, server.hasClient {
            server.sendOpenSettings()
            return
        }
        let alert = NSAlert()
        alert.messageText = "MakiDesk is not running"
        alert.informativeText = "Open MakiDesk once, then choose Terminal Settings again."
        alert.addButton(withTitle: "Open MakiDesk")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            openMakiDesk(nil)
        }
    }

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

        let makiItem = NSMenuItem()
        mainMenu.addItem(makiItem)
        let makiMenu = NSMenu(title: "MakiDesk")
        menu(makiMenu, "Open MakiDesk", #selector(openMakiDesk(_:)), "", [], self)
        menu(makiMenu, "Terminal Settings…",
             #selector(openMakiDeskSettings(_:)), ",", [], self)
        makiItem.submenu = makiMenu

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
        menu(fileMenu, "Close Pane or Workspace",
             #selector(TerminalWindowController.closePaneAction(_:)),
             "w", [], target)
        menu(fileMenu, "Close Workspace",
             #selector(TerminalWindowController.closeWorkspaceAction(_:)),
             "w", [.shift], target)
        fileItem.submenu = fileMenu

        let workspaceItem = NSMenuItem()
        mainMenu.addItem(workspaceItem)
        let workspaceMenu = NSMenu(title: "Workspace")
        for index in 0..<9 {
            let item = menu(workspaceMenu, "Workspace \(index + 1)",
                            #selector(TerminalWindowController.selectWorkspaceAction(_:)),
                            String(index + 1), [], target)
            item.tag = index
        }
        workspaceMenu.addItem(.separator())
        menu(workspaceMenu, "Previous Workspace",
             #selector(TerminalWindowController.previousWorkspaceAction(_:)),
             "\u{F702}", [.control], target)
        menu(workspaceMenu, "Next Workspace",
             #selector(TerminalWindowController.nextWorkspaceAction(_:)),
             "\u{F703}", [.control], target)
        workspaceMenu.addItem(.separator())
        menu(workspaceMenu, "Move Workspace Up",
             #selector(TerminalWindowController.moveWorkspaceUpAction(_:)),
             "\u{F700}", [.control], target)
        menu(workspaceMenu, "Move Workspace Down",
             #selector(TerminalWindowController.moveWorkspaceDownAction(_:)),
             "\u{F701}", [.control], target)
        workspaceItem.submenu = workspaceMenu

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
        menu(viewMenu, "Focus Pane Left",
             #selector(TerminalWindowController.focusPaneLeftAction(_:)),
             "\u{F702}", [.option], target)
        menu(viewMenu, "Focus Pane Right",
             #selector(TerminalWindowController.focusPaneRightAction(_:)),
             "\u{F703}", [.option], target)
        menu(viewMenu, "Focus Pane Up",
             #selector(TerminalWindowController.focusPaneUpAction(_:)),
             "\u{F700}", [.option], target)
        menu(viewMenu, "Focus Pane Down",
             #selector(TerminalWindowController.focusPaneDownAction(_:)),
             "\u{F701}", [.option], target)
        viewMenu.addItem(.separator())
        menu(viewMenu, "Zoom Pane",
             #selector(TerminalWindowController.toggleZoomAction(_:)),
             "\r", [.shift], target)
        menu(viewMenu, "Equalize Splits",
             #selector(TerminalWindowController.equalizeSplitsAction(_:)),
             "e", [.control], target)
        viewMenu.addItem(.separator())
        menu(viewMenu, "Show Quake", #selector(TerminalWindowController.toggleQuake),
             "", [], target)
        viewItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }

    @discardableResult
    private func menu(_ menu: NSMenu,
                      _ title: String,
                      _ action: Selector,
                      _ key: String,
                      _ modifiers: NSEvent.ModifierFlags,
                      _ target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = NSEvent.ModifierFlags.command.union(modifiers)
        item.target = target
        menu.addItem(item)
        return item
    }
}
