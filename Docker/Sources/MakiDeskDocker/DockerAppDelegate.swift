import AppKit
import Foundation
import MakiDockerCore

@MainActor
final class DockerAppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: DockerAppDelegate?

    private let store = DockerStore()
    private var window: DockerWindowController?
    private var server: DockerIPCServer?
    private var activationObservers: [NSObjectProtocol] = []
    private var suppressQuitConfirmation = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.regular)

        let window = DockerWindowController(store: store)
        self.window = window
        let server = DockerIPCServer()
        self.server = server
        store.server = server
        store.start()

        server.onShowMain = { [weak self] in self?.window?.show() }
        server.onHideMain = { [weak self] in self?.window?.hide() }
        server.onThemeChanged = { [weak self] in self?.store.reloadTheme() }
        server.onQuit = { NSApp.terminate(nil) }
        server.start { [weak self] started in
            guard let self else { return }
            guard started else {
                self.suppressQuitConfirmation = true
                NSApp.terminate(nil)
                return
            }
            window.show()
        }

        installMenu()
        observeActivation()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        store.stop()
        for observer in activationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        activationObservers.removeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard suppressQuitConfirmation == false else { return .terminateNow }
        if store.isActionRunning {
            guard DockerConfirm.ask(
                title: "Quit while Docker is working?",
                message: "A Docker command is still running. Quitting the window does not cancel the command on the daemon, but you will lose its result.",
                confirm: "Quit"
            ) else {
                return .terminateCancel
            }
        }
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if flag == false { window?.show() }
        return true
    }

    private func observeActivation() {
        let center = NotificationCenter.default
        activationObservers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.setAppActive(true) }
        })
        activationObservers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.setAppActive(false) }
        })
    }

    // MARK: - Menu

    private func installMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "MakiDesk Docker")
        appMenu.addItem(withTitle: "About MakiDesk Docker",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        _ = menu(appMenu, "Settings…", #selector(openSettings(_:)), ",", [.command])
        appMenu.addItem(.separator())
        _ = menu(appMenu, "Quit MakiDesk Docker", #selector(NSApplication.terminate(_:)), "q", [.command])
        appItem.submenu = appMenu

        let makiItem = NSMenuItem()
        mainMenu.addItem(makiItem)
        let makiMenu = NSMenu(title: "MakiDesk")
        _ = menu(makiMenu, "Open MakiDesk", #selector(openMakiDesk(_:)), "", [])
        makiItem.submenu = makiMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        _ = menu(fileMenu, "Refresh", #selector(refresh(_:)), "r", [.command])
        fileMenu.addItem(.separator())
        _ = menu(fileMenu, "Close Window", #selector(closeWindow(_:)), "w", [.command])
        fileItem.submenu = fileMenu

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        for (index, section) in DockerSection.allCases.enumerated() {
            let item = menu(viewMenu, section.title, #selector(showSection(_:)),
                            "\(index + 1)", [.command])
            item.tag = index
        }
        viewItem.submenu = viewMenu

        let containerItem = NSMenuItem()
        mainMenu.addItem(containerItem)
        let containerMenu = NSMenu(title: "Container")
        addContainerAction(containerMenu, .start)
        addContainerAction(containerMenu, .stop)
        addContainerAction(containerMenu, .restart)
        addContainerAction(containerMenu, .pause)
        addContainerAction(containerMenu, .unpause)
        containerMenu.addItem(.separator())
        _ = menu(containerMenu, "Terminal", #selector(openTerminal(_:)), "t", [.command])
        containerMenu.addItem(.separator())
        addContainerAction(containerMenu, .kill)
        addContainerAction(containerMenu, .remove)
        containerItem.submenu = containerMenu
    }

    private func menu(_ menu: NSMenu, _ title: String, _ action: Selector,
                      _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
        return item
    }

    private func addContainerAction(_ targetMenu: NSMenu, _ action: DockerContainerAction) {
        let item = menu(targetMenu, action.title, #selector(containerAction(_:)), "", [])
        item.representedObject = action.rawValue
    }

    @objc private func openSettings(_ sender: Any?) {
        window?.show()
        store.isSettingsPresented = true
    }

    @objc private func refresh(_ sender: Any?) {
        store.refreshNow()
    }

    @objc private func closeWindow(_ sender: Any?) {
        window?.closeWindow()
    }

    @objc private func showSection(_ sender: NSMenuItem) {
        guard DockerSection.allCases.indices.contains(sender.tag) else { return }
        store.section = DockerSection.allCases[sender.tag]
    }

    @objc private func containerAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = DockerContainerAction(rawValue: raw),
              let container = store.selectedContainer else { return }
        store.perform(action, on: container)
    }

    @objc private func openTerminal(_ sender: Any?) {
        guard let container = store.selectedContainer else { return }
        store.openTerminal(for: container)
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

    private var containingMakiDesk: URL? {
        let url = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard url.lastPathComponent == "MakiDesk.app",
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
