import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The browser's only window. The helper app is `.regular` from its Info.plist,
/// so the window takes part in Dock, ⌘Tab and MakiDesk's AX window inventory
/// exactly like Terminal and Docker.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let store: BrowserStore
    var onClose: (() -> Void)?
    private var keyMonitor: Any?
    private var activityMonitor: Any?

    init(store: BrowserStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = store.windowTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 600)
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("MakiDeskBrowserWindow")
        window.center()
        super.init(window: window)
        window.delegate = self
        let hosting = NSHostingView(rootView: BrowserRootView(store: store))
        hosting.safeAreaRegions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        installKeyMonitor()
        installActivityMonitor()
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        removeMonitors()
        store.stop()
        onClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        store.tick(now: Date())
    }

    private func removeMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let activityMonitor {
            NSEvent.removeMonitor(activityMonitor)
            self.activityMonitor = nil
        }
    }

    /// Any click, key or scroll in the browser window is use of its selected
    /// tab. The store throttles the actual timestamp write to once a minute.
    private func installActivityMonitor() {
        activityMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        ) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  let id = self.store.selectedTabID else { return event }
            self.store.touch(id)
            return event
        }
    }

    /// Browser-local commands. They are key equivalents of this window, not
    /// global Carbon hot keys: they must work while typing in the page without
    /// leaking into other apps.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = self.window,
                  window.isKeyWindow else {
                return event
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""

            if self.store.isAddressVisible, flags.isEmpty,
               !self.store.addressSuggestions.isEmpty {
                switch event.keyCode {
                case UInt16(kVK_DownArrow):
                    self.store.moveAddressSelection(by: 1)
                    return nil
                case UInt16(kVK_UpArrow):
                    self.store.moveAddressSelection(by: -1)
                    return nil
                case UInt16(kVK_Return):
                    if self.store.acceptAddressSelection() { return nil }
                default:
                    break
                }
            }

            if flags == .command {
                switch characters {
                case "l":
                    if self.store.isAddressVisible {
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    } else {
                        self.store.showAddress()
                        DispatchQueue.main.async {
                            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                        }
                    }
                    return nil
                case "t":
                    self.store.newTab()
                    return nil
                case "w":
                    if self.store.tabs.count <= 1 {
                        window.performClose(nil)
                    } else {
                        self.store.closeSelected()
                    }
                    return nil
                case "r":
                    self.store.reload()
                    return nil
                case ".":
                    self.store.stopLoading()
                    return nil
                case "[":
                    self.store.goBack()
                    return nil
                case "]":
                    self.store.goForward()
                    return nil
                case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                    if let index = Int(characters), index >= 1,
                       index <= self.store.orderedTabs.count {
                        self.store.select(self.store.orderedTabs[index - 1].id)
                    }
                    return nil
                default:
                    break
                }
            }

            if flags == [.command, .shift] {
                switch characters {
                case "p":
                    if let id = self.store.selectedTabID { self.store.togglePin(id) }
                    return nil
                case "s":
                    self.store.requestSummary()
                    return nil
                case "w":
                    window.performClose(nil)
                    return nil
                default:
                    break
                }
            }

            if flags == .control, event.keyCode == kVK_Tab {
                let ordered = self.store.orderedTabs
                guard ordered.count > 1,
                      let selected = self.store.selectedTabID,
                      let index = ordered.firstIndex(where: { $0.id == selected }) else {
                    return nil
                }
                self.store.select(ordered[(index + 1) % ordered.count].id)
                return nil
            }
            if flags == [.control, .shift], event.keyCode == kVK_Tab {
                let ordered = self.store.orderedTabs
                guard ordered.count > 1,
                      let selected = self.store.selectedTabID,
                      let index = ordered.firstIndex(where: { $0.id == selected }) else {
                    return nil
                }
                self.store.select(ordered[(index - 1 + ordered.count) % ordered.count].id)
                return nil
            }

            return event
        }
    }
}

/// Owns the browser window for the helper process. There is one window in the
/// first version; the app terminates after it closes.
@MainActor
public final class BrowserAppController {
    private var window: BrowserWindowController?

    public init() {}

    public func show() {
        if let window {
            window.showWindow(nil)
            window.window?.makeKeyAndOrderFront(nil)
            window.store.tick(now: Date())
            return
        }

        let store = BrowserStore()
        let controller = BrowserWindowController(store: store)
        controller.onClose = { [weak self] in self?.window = nil }
        window = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        Task { @MainActor [weak store] in
            await store?.start()
        }
    }

    public func open(url: URL) {
        show()
        guard let store = window?.store else { return }
        if store.isStarted {
            store.navigate(to: url)
        } else {
            Task { @MainActor in
                await store.start()
                store.navigate(to: url)
            }
        }
    }

    public func shutdown() {
        window?.store.stop()
        window = nil
    }
}
