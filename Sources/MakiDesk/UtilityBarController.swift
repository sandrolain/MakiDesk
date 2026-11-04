import AppKit
import Observation
import SwiftUI

/// The lifecycle of the utility bar (F1/F2).
///
/// Nothing here touches window geometry or Accessibility: the bar is a passive
/// panel that appears when the pointer rests in the strip under the menu bar,
/// retreats when it leaves, and stays when pinned. The commands it runs are the
/// existing shortcuts, so the bar is a second surface for behaviour that
/// already exists.
@Observable
@MainActor
final class UtilityBarController {
    static let shared = UtilityBarController()

    private(set) var isVisible = false
    let model = UtilityBarModel()

    @ObservationIgnored private var panel: UtilityBarPanel?
    @ObservationIgnored private var reveal = BarReveal()
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var pressMonitor: Any?
    @ObservationIgnored private var localPressMonitor: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let focus = PanelFocusReturn()
    @ObservationIgnored private let overflowTarget = OverflowMenuTarget()
    /// The overflow `NSMenu` runs its own event loop; a click on one of its rows
    /// is not "outside the bar" and must not close a pinned bar.
    @ObservationIgnored private var isPoppingMenu = false

    /// The pointer is sampled at this rate while the feature is on. Cheap
    /// enough to be a plain timer, and it stops the moment the bar is turned
    /// off: no hidden polling.
    private static let tick: TimeInterval = 0.1

    private init() {}

    // MARK: - Lifecycle

    func start() {
        applySettings()
    }

    /// Reads the preferences and re-arms or shuts down accordingly. Called at
    /// launch and after every change in Settings.
    func applySettings() {
        model.height = Self.clampedHeight(Settings.int(.utilityBarHeight))
        model.labelMode = BarLabelMode(rawValue: Settings.string(.utilityBarLabels) ?? "") ?? .auto
        model.hiddenItems = BarItemCatalog.hidden(
            from: Settings.string(.utilityBarHiddenItems)
        )

        guard Settings.bool(.utilityBarEnabled) else {
            if isVisible { dismiss() }
            stop()
            return
        }
        scheduleTicker()
        installMonitors()
        installObservers()
        if isVisible, let screen = screen(containing: NSEvent.mouseLocation) {
            position(panel, on: screen)
        }
    }

    private static func clampedHeight(_ stored: Int) -> CGFloat {
        guard stored > 0 else { return UtilityBarModel.defaultHeight }
        let value = CGFloat(stored)
        return min(max(value, UtilityBarModel.heightRange.lowerBound),
                   UtilityBarModel.heightRange.upperBound)
    }

    // MARK: - Opening and closing

    /// The menu item and ⌃⌥B: open with the keyboard, or close what is open.
    func toggle() {
        if isVisible {
            dismiss()
            return
        }
        guard isEnabled else {
            HUDController.shared.show(HUDMessage.utilityBarIsOff())
            return
        }
        showFromKeyboard()
    }

    /// A typed command or the menu: present it without taking the keyboard.
    func show() {
        guard isEnabled else {
            HUDController.shared.show(HUDMessage.utilityBarIsOff())
            return
        }
        guard let screen = UtilityWindowPlacement.focusedScreen()
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        reveal.showNow()
        present(on: screen)
    }

    private var isEnabled: Bool { Settings.bool(.utilityBarEnabled) }

    /// Esc, a click outside, or a command that opened a panel.
    func dismiss() {
        let pointer = NSEvent.mouseLocation
        if let screen = screen(containing: pointer) {
            reveal.dismiss(pointer: pointer, area: screen.visibleFrame,
                           zone: triggerZone(for: screen), barHeight: model.height)
        } else {
            reveal.reset()
        }
        closePanel()
    }

    func togglePin() {
        model.isPinned.toggle()
        reveal.setPinned(model.isPinned)
        if model.isPinned, isVisible == false,
           let screen = UtilityWindowPlacement.focusedScreen() {
            reveal.showNow()
            present(on: screen)
        }
    }

    /// What a command does with the bar: pinned means it stays, otherwise it
    /// gets out of the way of the panel it just opened.
    func activate(_ item: BarItem) {
        switch item.kind {
        case let .shortcut(action):
            dismissForCommand()
            WorkspaceStore.shared.applyShortcut(action)
        case let .info(info):
            dismissForCommand()
            switch info {
            case .disk:
                SystemMonitor.shared.openStorageSettings()
            case .cpu:
                SystemMonitor.shared.openActivityMonitor()
            case .windows:
                WorkspaceStore.shared.applyShortcut(.switchWindows)
            }
        case .pin:
            togglePin()
        case .overflow:
            break
        case .customize:
            dismissForCommand()
            // Open Settings on the page that holds the bar's preferences.
            UserDefaults.standard.set(SettingsView.SettingsTab.panels.rawValue,
                                      forKey: SettingsView.SettingsTab.defaultsKey)
            WorkspaceStore.shared.applyShortcut(.openSettings)
        }
    }

    /// The chevron: an `NSMenu` rather than a popover, because a passive panel
    /// does not become key and a popover would.
    func popOverflow(_ items: [BarItem]) {
        let menu = NSMenu()
        if items.isEmpty {
            let empty = NSMenuItem(title: "Everything fits", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for item in items {
            let entry = NSMenuItem(title: item.title,
                                   action: #selector(OverflowMenuTarget.choose(_:)),
                                   keyEquivalent: "")
            entry.target = overflowTarget
            entry.representedObject = item.id
            entry.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
            menu.addItem(entry)
        }
        overflowTarget.handler = { [weak self] id in
            guard let item = BarItemCatalog.item(id: id) else { return }
            self?.activate(item)
        }
        isPoppingMenu = true
        menu.popUp(positioning: nil,
                   at: panel.map { BarLayout.menuAnchor(in: $0.frame) }
                       ?? NSEvent.mouseLocation,
                   in: nil)
        isPoppingMenu = false
    }

    /// Window numbers to leave out of a screen capture, like the selection
    /// overlays already do. Empty while the bar is closed.
    var excludedWindowNumbers: [CGWindowID] {
        guard isVisible, let panel else { return [] }
        return [CGWindowID(panel.windowNumber)]
    }

    // MARK: - The pointer

    private func scheduleTicker() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func sample() {
        guard Settings.bool(.utilityBarEnabled) else {
            if isVisible { dismiss() }
            stop()
            return
        }
        // A keyboard session closes on Esc, a click outside or a command; the
        // pointer must not snatch the bar away while the user is using arrows.
        guard model.isKeyboardDriven == false else { return }
        let pointer = NSEvent.mouseLocation
        guard let screen = screen(containing: pointer) else { return }
        let pressed = NSEvent.pressedMouseButtons != 0
        switch reveal.update(pointer: pointer, area: screen.visibleFrame,
                             zone: triggerZone(for: screen),
                             barHeight: model.height, pressed: pressed,
                             suppressed: false,
                             now: ProcessInfo.processInfo.systemUptime) {
        case .show:
            present(on: screen)
        case .hide:
            closePanel()
        case .none:
            break
        }
    }

    private func present(on screen: NSScreen) {
        let panel = panel ?? buildPanel()
        position(panel, on: screen)
        if panel.isVisible == false { panel.orderFrontRegardless() }
        isVisible = true
    }

    private func position(_ panel: NSWindow?, on screen: NSScreen) {
        panel?.setFrame(BarReveal.barFrame(in: screen.visibleFrame, height: model.height),
                        display: true)
    }

    private func showFromKeyboard() {
        guard let screen = UtilityWindowPlacement.focusedScreen()
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        focus.capture()
        let panel = panel ?? buildPanel()
        position(panel, on: screen)
        reveal.showNow()
        model.isKeyboardDriven = true
        panel.isKeyboardDriven = true
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        isVisible = true
    }

    private func closePanel() {
        guard let panel else { return }
        let hadKeyboard = model.isKeyboardDriven
        isVisible = false
        panel.orderOut(nil)
        panel.isKeyboardDriven = false
        model.isKeyboardDriven = false
        if hadKeyboard, let restore = focus.takeRestoreAction(ownsKeyboard: true) {
            restore()
        }
    }

    private func dismissForCommand() {
        guard model.isPinned == false else { return }
        dismiss()
    }

    // MARK: - Monitors

    private func installMonitors() {
        if pressMonitor == nil {
            pressMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.closeIfClickWasOutside() }
            }
        }
        if localPressMonitor == nil {
            localPressMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.closeIfClickWasOutside() }
                return event
            }
        }
    }

    /// Never swallows the click: it only notices that it landed elsewhere. A
    /// pinned bar is not dismissed by a click: the pin means "stay".
    private func closeIfClickWasOutside() {
        guard isPoppingMenu == false, isVisible, let panel,
              reveal.closesOnOutsideClick else { return }
        guard panel.frame.contains(NSEvent.mouseLocation) == false else { return }
        dismiss()
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
        ]
        for name in names {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenChanged() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenChanged() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .makiDeskThemeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel?.backgroundColor = NSColor(WorkspaceStore.shared.theme.background)
            }
        })
    }

    private func screenChanged() {
        // A pinned bar has to move, not disappear: the display went away, the
        // user did not ask for the bar to close.
        if reveal.isPinned {
            if isVisible, let panel,
               let screen = screen(containing: NSEvent.mouseLocation)
                   ?? NSScreen.main ?? NSScreen.screens.first {
                position(panel, on: screen)
            }
            return
        }
        reveal.reset()
        closePanel()
    }

    private func stop() {
        ticker?.invalidate()
        ticker = nil
        if let pressMonitor {
            NSEvent.removeMonitor(pressMonitor)
            self.pressMonitor = nil
        }
        if let localPressMonitor {
            NSEvent.removeMonitor(localPressMonitor)
            self.localPressMonitor = nil
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in observers {
            workspace.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    // MARK: - Building

    private func buildPanel() -> UtilityBarPanel {
        let hosting = NSHostingView(rootView: UtilityBarView(
            controller: self,
            model: model,
            store: WorkspaceStore.shared
        ))
        let panel = UtilityBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: model.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.contentView = hosting
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isOpaque = true
        panel.backgroundColor = NSColor(WorkspaceStore.shared.theme.background)
        panel.worksWhenModal = true
        panel.isFloatingPanel = true
        panel.sharingType = .none
        self.panel = panel
        return panel
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    /// The menu bar where the display has one, a small band at the top edge
    /// elsewhere. `visibleFrame` already leaves the menu bar out.
    private func triggerZone(for screen: NSScreen) -> CGRect {
        BarReveal.zone(for: screen.frame, desktop: screen.visibleFrame,
                       minimum: reveal.timings.zoneHeight)
    }
}

/// `NSMenu` needs a target object; the bar's overflow rows are its only use.
private final class OverflowMenuTarget: NSObject {
    var handler: ((String) -> Void)?

    @objc func choose(_ sender: NSMenuItem) {
        handler?(sender.representedObject as? String ?? "")
    }
}
