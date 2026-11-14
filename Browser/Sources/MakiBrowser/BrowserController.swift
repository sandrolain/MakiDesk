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
    private var placementSaveWorkItem: DispatchWorkItem?
    private var isRestoringPlacement = false

    private static let frameAutosaveName = "MakiDeskBrowserWindow"
    private static let placementDefaultsKey = "MakiDeskBrowserWindowPlacement"

    private struct WindowPlacement: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let displayID: UInt32?
        let displayName: String?

    }

    init(store: BrowserStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = store.windowTitle
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 600)
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName(Self.frameAutosaveName)
        let hasSavedFrame = window.setFrameUsingName(Self.frameAutosaveName)
        super.init(window: window)
        window.delegate = self
        isRestoringPlacement = true
        if let placement = Self.loadPlacement() {
            restore(placement, in: window)
        } else if !hasSavedFrame {
            window.center()
        }
        isRestoringPlacement = false
        let hosting = NSHostingView(rootView: BrowserRootView(store: store))
        hosting.safeAreaRegions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = hosting
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])
        installKeyMonitor()
        installActivityMonitor()
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        savePlacement()
        removeMonitors()
        store.stop()
        onClose?()
    }

    func windowDidMove(_ notification: Notification) {
        schedulePlacementSave()
    }

    func windowDidResize(_ notification: Notification) {
        schedulePlacementSave()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        store.tick(now: Date())
    }

    private func removeMonitors() {
        placementSaveWorkItem?.cancel()
        placementSaveWorkItem = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let activityMonitor {
            NSEvent.removeMonitor(activityMonitor)
            self.activityMonitor = nil
        }
    }

    private func schedulePlacementSave() {
        guard !isRestoringPlacement, let window else { return }
        placementSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window else { return }
            self.writePlacement(for: window)
        }
        placementSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func savePlacement() {
        placementSaveWorkItem?.cancel()
        placementSaveWorkItem = nil
        guard let window else { return }
        writePlacement(for: window)
        window.saveFrame(usingName: Self.frameAutosaveName)
    }

    private func writePlacement(for window: NSWindow) {
        let frame = window.frame
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
            ?? window.screen
        let displayID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let placement = WindowPlacement(x: frame.origin.x,
                                        y: frame.origin.y,
                                        width: frame.size.width,
                                        height: frame.size.height,
                                        displayID: displayID?.uint32Value,
                                        displayName: screen?.localizedName)
        guard let data = try? JSONEncoder().encode(placement) else { return }
        UserDefaults.standard.set(data, forKey: Self.placementDefaultsKey)
    }

    private static func loadPlacement() -> WindowPlacement? {
        guard let data = UserDefaults.standard.data(forKey: placementDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(WindowPlacement.self, from: data)
    }

    private func restore(_ placement: WindowPlacement, in window: NSWindow) {
        let screens = NSScreen.screens
        let matchingScreen = screens.first { candidate in
            guard let number = candidate.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return number.uint32Value == placement.displayID
        } ?? screens.first { $0.localizedName == placement.displayName }
        guard let screen = matchingScreen ?? NSScreen.main ?? screens.first else {
            window.center()
            return
        }

        let visible = screen.visibleFrame
        let width = min(max(placement.width, window.minSize.width), visible.width)
        let height = min(max(placement.height, window.minSize.height), visible.height)
        let origin: NSPoint
        if matchingScreen != nil {
            origin = NSPoint(x: min(max(placement.x, visible.minX), visible.maxX - width),
                             y: min(max(placement.y, visible.minY), visible.maxY - height))
        } else {
            origin = NSPoint(x: visible.midX - width / 2, y: visible.midY - height / 2)
        }
        window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
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

            if flags == [.command, .option], characters == "t" {
                self.store.newPrivateTab()
                return nil
            }

            if self.store.isAddressVisible {
                let addressFlags = flags.subtracting([.numericPad, .function])
                let isReturn = event.keyCode == UInt16(kVK_Return)
                    || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)
                if addressFlags == .command, isReturn {
                    if self.store.acceptAddressSelectionInNewTab() == false {
                        self.store.navigateInNewTab(self.store.addressText)
                    }
                    return nil
                }
                if addressFlags.isEmpty, !self.store.addressSuggestions.isEmpty {
                    switch event.keyCode {
                    case UInt16(kVK_DownArrow):
                        self.store.moveAddressSelection(by: 1)
                        return nil
                    case UInt16(kVK_UpArrow):
                        self.store.moveAddressSelection(by: -1)
                        return nil
                    case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
                        if self.store.acceptAddressSelection() { return nil }
                    default:
                        break
                    }
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
        store.receiveExternalURL(url)
    }

    public func shutdown() {
        window?.store.stop()
        window = nil
    }
}
