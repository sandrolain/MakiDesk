import AppKit
import MakiBrowser

@main
enum MakiDeskBrowserMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = BrowserAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

final class BrowserAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: BrowserAppController?
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        MainActor.assumeIsolated {
            let controller = BrowserAppController()
            self.controller = controller
            controller.show()
            pendingURLs.forEach { controller.open(url: $0) }
            pendingURLs.removeAll()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls where ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                if let controller {
                    controller.open(url: url)
                } else {
                    pendingURLs.append(url)
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                      hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { controller?.show() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            controller?.shutdown()
        }
    }

    @objc private func findInPage(_ sender: Any?) {
        MainActor.assumeIsolated {
            controller?.findInPage()
        }
    }

    @objc private func findNext(_ sender: Any?) {
        MainActor.assumeIsolated {
            controller?.findInPage()
        }
    }

    @objc private func findPrevious(_ sender: Any?) {
        MainActor.assumeIsolated {
            controller?.findInPage(backwards: true)
        }
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About MakiDesk Browser",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide MakiDesk Browser",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MakiDesk Browser",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let findItem = editMenu.addItem(withTitle: "Find in Page",
                                        action: #selector(findInPage(_:)),
                                        keyEquivalent: "f")
        findItem.target = self
        let findNextItem = editMenu.addItem(withTitle: "Find Next",
                                            action: #selector(findNext(_:)),
                                            keyEquivalent: "g")
        findNextItem.target = self
        let findPreviousItem = editMenu.addItem(withTitle: "Find Previous",
                                                action: #selector(findPrevious(_:)),
                                                keyEquivalent: "g")
        findPreviousItem.keyEquivalentModifierMask = [.command, .shift]
        findPreviousItem.target = self

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)),
                           keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front",
                           action: #selector(NSApplication.arrangeInFront(_:)),
                           keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")
        NSApp.windowsMenu = windowMenu

        return main
    }
}
