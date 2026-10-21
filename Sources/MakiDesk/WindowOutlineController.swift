import AppKit
import ApplicationServices

/// Draws a thin border around the focused window (T36).
///
/// The border is a non-activating, click-through panel that sits just above
/// the target's window level. Other apps' windows arrive through
/// `WindowIndex`; MakiDesk's own windows through the key/main window and the
/// matching `NSWindow` notifications. Both paths are event-driven, so the
/// border follows a window while it is dragged or resized without polling.
/// The panel never becomes key and never takes a click.
final class WindowOutlineController {
    static let shared = WindowOutlineController()

    private var panel: OutlinePanel?
    private var outlineView: OutlineView?
    private var targetElement: AXUIElement?
    private weak var targetWindow: NSWindow?
    private var targetWindowID: CGWindowID?
    private var targetLevel: NSWindow.Level = .floating
    private var observers: [NSObjectProtocol] = []
    private var refreshAfterSwitch: DispatchWorkItem?
    private var settleRefreshWork: DispatchWorkItem?
    private var settleChecksLeft = 0
    private var pressMonitor: Any?
    private var followTimer: Timer?
    private enum FollowTarget { case ownWindow; case externalWindow(CGWindowID) }
    private var followTarget: FollowTarget?
    private var followLastFrame = CGRect.zero
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        observeSystem()
        updatePressMonitor()
        applySettings()
        // At launch the activation notifications can arrive before the app's
        // focused window is readable; the border then has no target to follow.
        scheduleRefresh(after: 0.5)
    }

    /// Reads the focused window and moves or hides the border.
    func refresh(frontmost: WindowController.Frontmost? = nil) {
        refresh(frontmost: frontmost, settle: false)
    }

    /// `settle` marks a delayed re-read: it must not schedule another one.
    private func refresh(frontmost: WindowController.Frontmost?, settle: Bool) {
        // A new track supersedes any drag-follow for the previous target.
        endFollow()
        let store = WorkspaceStore.shared
        guard store.focusBorderEnabled, AXIsProcessTrusted() else {
            hide()
            return
        }

        // MakiDesk's own windows are not in WindowIndex (it deliberately
        // ignores this process), so they are resolved from the key window.
        if NSApplication.shared.isActive {
            guard let window = focusedOwnWindow() else {
                hide()
                return
            }
            targetElement = nil
            targetWindow = window
            targetWindowID = CGWindowID(exactly: window.windowNumber)
            targetLevel = borderLevel(for: window)
            present(windowFrame: window.frame, level: targetLevel)
            return
        }

        targetWindow = nil
        switch frontmost ?? store.recentFocusSnapshot() ?? WindowController.frontmost() {
        case let .window(info):
            guard !WindowController.isFullScreen(info.element),
                  !WindowController.isMinimized(info.element) else {
                hide()
                return
            }
            guard info.frame.width > 1, info.frame.height > 1 else {
                hide()
                return
            }
            targetElement = info.element
            targetWindowID = info.windowID
            targetLevel = windowLevel(for: info.windowID)
            present(windowFrame: WindowController.flip(info.frame), level: targetLevel)
            if !settle { scheduleSettleRefresh() }
        case .desktop, .none:
            hide()
        }
    }

    /// Follows the tracked window through a move or a live resize.
    func refreshGeometry() {
        guard WorkspaceStore.shared.focusBorderEnabled, AXIsProcessTrusted() else {
            hide()
            return
        }
        // The follower presents its frames on its own timer; geometry events
        // must add nothing to it.
        if followTimer != nil { return }
        // A geometry event while the pointer is down is a live drag or resize.
        // AX move notifications are coalesced, so the border appears late and
        // in jumps; switch to the polling follower, which reads live
        // window-server bounds and stops when the button is released.
        if NSEvent.pressedMouseButtons & 1 != 0, beginDragFollow() { return }
        if let window = targetWindow {
            guard NSApplication.shared.isActive,
                  window.isVisible,
                  !window.isMiniaturized,
                  !window.styleMask.contains(.fullScreen),
                  NSApplication.shared.keyWindow === window
                    || NSApplication.shared.mainWindow === window else {
                refresh()
                return
            }
            targetLevel = borderLevel(for: window)
            present(windowFrame: window.frame, level: targetLevel)
            return
        }
        guard let element = targetElement else {
            refresh()
            return
        }
        guard !WindowController.isFullScreen(element),
              !WindowController.isMinimized(element) else {
            hide()
            return
        }
        guard let frame = WindowController.frame(of: element) else {
            targetElement = nil
            refresh()
            return
        }
        present(windowFrame: WindowController.flip(frame), level: targetLevel)
    }

    /// A click can focus another window of the same app without any
    /// activation notification, and the AX focus change can arrive late or not
    /// at all. A global mouse-up check is an event-driven safety net that does
    /// not depend on the app posting anything.
    private func updatePressMonitor() {
        let shouldObserve = WorkspaceStore.shared.focusBorderEnabled && AXIsProcessTrusted()
        if shouldObserve {
            guard pressMonitor == nil else { return }
            pressMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
                DispatchQueue.main.async { self?.scheduleSettleRefresh() }
            }
        } else if let monitor = pressMonitor {
            NSEvent.removeMonitor(monitor)
            pressMonitor = nil
        }
    }

    // MARK: - Focus settle

    /// Some apps publish their AX focus a beat after posting the change (Finder
    /// among them). The first read can still name the previous window, which is
    /// why the ring sometimes stayed behind after switching windows inside one
    /// app. Two cheap re-reads land on the window the user actually picked;
    /// any newer event cancels and restarts them.
    private func scheduleSettleRefresh() {
        guard WorkspaceStore.shared.focusBorderEnabled, AXIsProcessTrusted() else { return }
        settleChecksLeft = 2
        scheduleSettleTick(after: 0.12)
    }

    private func scheduleSettleTick(after delay: TimeInterval) {
        guard settleChecksLeft > 0,
              WorkspaceStore.shared.focusBorderEnabled,
              AXIsProcessTrusted() else { return }
        settleChecksLeft -= 1
        settleRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.settleRefreshWork = nil
            self.refresh(frontmost: nil, settle: true)
            if self.settleChecksLeft > 0 { self.scheduleSettleTick(after: 0.2) }
        }
        settleRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Live drag follow

    /// Rounds the drag out: the ring then resyncs from the authoritative frame
    /// path once the pointer has been released.
    private func beginDragFollow() -> Bool {
        let target: FollowTarget
        if targetWindow != nil {
            target = .ownWindow
        } else if let element = targetElement, let windowID = targetWindowID {
            guard !WindowController.isFullScreen(element),
                  !WindowController.isMinimized(element) else { return false }
            target = .externalWindow(windowID)
        } else {
            return false
        }
        followTarget = target
        followLastFrame = .zero
        // `.common` so it keeps running inside a native drag's tracking loop.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.followTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
        return true
    }

    /// While the pointer drags the tracked window, the ring reads cheap live
    /// window-server bounds every tick — no AX read, no event-lag chase. Ended
    /// when the button is released or the target goes away.
    private func followTick() {
        guard let target = followTarget,
              WorkspaceStore.shared.focusBorderEnabled,
              AXIsProcessTrusted() else {
            endFollow()
            return
        }
        // The press owns the gesture: when the button is up, the pointer is no
        // longer dragging (or already released without a mouseUp we could see).
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            endFollow()
            refreshGeometry()
            return
        }
        let frame: CGRect
        switch target {
        case .ownWindow:
            guard let window = targetWindow,
                  window.isVisible,
                  !window.isMiniaturized else {
                endFollow()
                refresh()
                return
            }
            frame = window.frame
        case let .externalWindow(windowID):
            guard let bounds = WindowController.cgFrame(windowNumber: windowID),
                  bounds.width > 1, bounds.height > 1 else {
                endFollow()
                refresh()
                return
            }
            frame = WindowController.flip(bounds)
        }
        guard frame != followLastFrame else { return }
        // Ignore sub-point jitter so the ring does not shimmer between ticks.
        let previous = followLastFrame
        guard previous == .zero
            || abs(frame.minX - previous.minX) > 0.5
            || abs(frame.minY - previous.minY) > 0.5
            || abs(frame.width - previous.width) > 0.5
            || abs(frame.height - previous.height) > 0.5 else { return }
        followLastFrame = frame
        present(windowFrame: frame, level: targetLevel)
    }

    private func endFollow() {
        followTimer?.invalidate()
        followTimer = nil
        followTarget = nil
        followLastFrame = .zero
    }

    /// Applies the current settings, then redraws the border.
    func applySettings() {
        updatePressMonitor()
        let store = WorkspaceStore.shared
        guard store.focusBorderEnabled, AXIsProcessTrusted() else {
            hide()
            return
        }
        outlineView?.borderWidth = CGFloat(FocusBorder.clampedWidth(store.focusBorderWidth))
        outlineView?.borderColor = NSColor(store.theme.accent)
        refresh()
    }

    // MARK: - Own windows

    /// The key window is the focused one. `mainWindow` only fills in while the
    /// app is becoming active and the key window has not been set yet.
    private func focusedOwnWindow() -> NSWindow? {
        if let key = NSApplication.shared.keyWindow {
            return canOutline(key) ? key : nil
        }
        if let main = NSApplication.shared.mainWindow, canOutline(main) {
            return main
        }
        return nil
    }

    private func canOutline(_ window: NSWindow) -> Bool {
        guard window !== panel,
              window.isVisible,
              !window.isMiniaturized,
              window.canBecomeKey,
              window.isOnActiveSpace,
              !window.styleMask.contains(.fullScreen),
              window.frame.width > 1,
              window.frame.height > 1 else {
            return false
        }
        let level = window.level
        guard level != .mainMenu, level != .popUpMenu, level != .statusBar else {
            return false
        }
        // The switcher, HUD, peek and drag preview are transient overlays at
        // screen-saver level; they already carry their own focus treatment.
        return level.rawValue < Int(CGWindowLevelForKey(.screenSaverWindow))
    }

    private func borderLevel(for window: NSWindow) -> NSWindow.Level {
        NSWindow.Level(rawValue: max(1, window.level.rawValue + 1))
    }

    // MARK: - Panel

    /// `windowFrame` is in Cocoa coordinates for both paths; the AX frame is
    /// flipped by the caller.
    private func present(windowFrame: CGRect, level: NSWindow.Level) {
        let width = FocusBorder.clampedWidth(WorkspaceStore.shared.focusBorderWidth)
        let target = FocusBorder.panelFrame(for: windowFrame, width: width)
        guard target.width > 0, target.height > 0 else {
            hide()
            return
        }

        let panel = self.panel ?? makePanel()
        self.panel = panel
        outlineView?.borderWidth = CGFloat(width)
        outlineView?.borderColor = NSColor(WorkspaceStore.shared.theme.accent)

        let levelChanged = panel.level != level
        if levelChanged {
            panel.level = level
        }
        if panel.frame != target {
            panel.setFrame(target, display: true)
            outlineView?.frame = panel.contentView?.bounds ?? .zero
        }
        if !panel.isVisible || levelChanged {
            panel.orderFrontRegardless()
        }
    }

    private func makePanel() -> OutlinePanel {
        let panel = OutlinePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let view = OutlineView(frame: .zero)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        outlineView = view
        return panel
    }

    /// Keeps the panel just above an external target's window layer.
    private func windowLevel(for windowNumber: CGWindowID?) -> NSWindow.Level {
        guard let windowNumber,
              let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowNumber) as? [[String: Any]],
              let layer = info.first?[kCGWindowLayer as String] as? Int else {
            return .floating
        }
        return NSWindow.Level(rawValue: max(1, layer + 1))
    }

    private func hide() {
        targetElement = nil
        targetWindow = nil
        targetWindowID = nil
        endFollow()
        panel?.orderOut(nil)
    }

    // MARK: - System events

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.willSleepNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.screensDidWakeNotification
        ]
        for name in names {
            observers.append(workspace.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                self?.handle(name)
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleScreenChange()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .makiDeskThemeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applySettings()
        })

        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didResignMainNotification,
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification
        ] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] note in
                self?.handleOwnWindowEvent(named: name, note: note)
            })
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleRefresh(after: 0.05)
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The other app's activation may arrive before or after this one;
            // refresh instead of hiding so the border can hand over cleanly.
            self?.scheduleRefresh(after: 0.05)
        })
    }

    private func handleOwnWindowEvent(named name: Notification.Name, note: Notification) {
        guard let window = note.object as? NSWindow, window !== panel else { return }
        switch name {
        case NSWindow.didMoveNotification,
             NSWindow.didResizeNotification,
             NSWindow.didChangeScreenNotification:
            if window === targetWindow { refreshGeometry() }
        case NSWindow.didBecomeKeyNotification,
             NSWindow.didBecomeMainNotification,
             NSWindow.didDeminiaturizeNotification,
             NSWindow.didExitFullScreenNotification:
            refresh()
        case NSWindow.didResignKeyNotification,
             NSWindow.didResignMainNotification,
             NSWindow.didChangeOcclusionStateNotification,
             NSWindow.willCloseNotification,
             NSWindow.didMiniaturizeNotification,
             NSWindow.didEnterFullScreenNotification:
            scheduleRefresh(after: 0.02)
        default:
            break
        }
    }

    private func handle(_ name: Notification.Name) {
        switch name {
        case NSWorkspace.willSleepNotification,
             NSWorkspace.screensDidSleepNotification:
            hide()
        case NSWorkspace.activeSpaceDidChangeNotification:
            hide()
            scheduleRefresh(after: 0.2)
        case NSWorkspace.didWakeNotification,
             NSWorkspace.screensDidWakeNotification:
            scheduleRefresh(after: 0.15)
        case NSWorkspace.didActivateApplicationNotification:
            refresh()
            scheduleRefresh(after: 0.15)
        default:
            refresh()
        }
    }

    private func handleScreenChange() {
        hide()
        scheduleRefresh(after: 0.2)
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        refreshAfterSwitch?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshAfterSwitch = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

/// A panel that may sit off-screen or under the menu bar; a plain `NSPanel`
/// clamps its frame and would leave a border detached from a window at an edge.
private final class OutlinePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// The stroke itself. The view stays transparent, so only the ring takes
/// pixels; the window underneath is never dimmed or covered.
private final class OutlineView: NSView {
    var borderColor: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }
    var borderWidth: CGFloat = 3 {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let width = max(1, borderWidth)
        let inset = width / 2 + 1
        let rect = bounds.insetBy(dx: inset, dy: inset)
        guard rect.width > 0, rect.height > 0 else { return }

        let radius = FocusBorder.cornerRadius(for: rect, width: Double(width))
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: radius,
            yRadius: radius
        )
        path.lineWidth = width
        borderColor.setStroke()
        path.stroke()
    }
}
