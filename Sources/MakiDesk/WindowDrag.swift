import AppKit
import ApplicationServices
import Observation
import SwiftUI

/// Dragging a window while holding the **activator keys** (default `⌥`,
/// configurable in Settings) shows an overlay box on the **nearest half /
/// golden position** — the same positions the keyboard can reach — and the
/// window snaps there on release. This is MakiDesk's replacement for the macOS
/// "hold ⌥ to tile" gesture; see `MacOSTiling` and the Settings toggle.
///
/// `Control` is never the activator: `⌃`-click is macOS's secondary click and
/// opens context menus (so `⌃⌥`-drag cannot work cleanly). See `DragActivator`.
///
/// The activator keys are read *live*: you can start a normal drag and press
/// them mid-way (or release them to move freely) and the overlay appears or
/// disappears accordingly. A small movement threshold means a plain click with
/// the keys held does not move the window by accident.
///
/// Why polling instead of `leftMouseDragged` events: a native window drag runs
/// its own tracking loop and can consume the drag / mouse-up events, so a
/// global monitor cannot be relied upon to follow the pointer (B4). A 60 Hz
/// timer reads `NSEvent.mouseLocation` / `modifierFlags` / `pressedMouseButtons`
/// directly, so the overlay tracks the pointer and the release is never missed.
///
/// The zone is computed with `TilingEngine.dragZone` (same fractions and gap
/// inset as the keyboard), so the preview always matches the frame finally
/// applied, which goes through `WorkspaceStore.applyDraggedFrame`.
/// so the model and overlay stay in sync.
@MainActor
@Observable
final class WindowDrag {
    static let shared = WindowDrag()

    /// Movement (in points) needed before a press counts as a drag.
    private static let dragThreshold: CGFloat = 4

    private var monitor: Any?
    private var pollTimer: Timer?
    private var pollingInterval: TimeInterval = 0
    private var nextHitTest = Date.distantPast
    private var element: AXUIElement?
    private var area: CGRect = .zero
    /// Where the left button went down, to tell a drag from a plain click.
    private var downPoint: CGPoint?
    /// A window has been captured and the overlay is live.
    private var active = false
    /// The pointer has moved far enough to count as a drag.
    private var dragging = false
    private var preview: NSPanel?
    private var previewVisible = false
    private var lastRendered: CGRect = .zero
    private var nativeGesture = false
    private var nativeOptionHeld = false
    private var nativePointerPoint: CGPoint?
    private var nativeGestureGeneration: UInt64 = 0
    private var nativeGestureCommandEpoch = 0
    private var inputTap: WindowDragInputTap?
    private var inputTapGeneration: UInt64 = 0
    private var activationObserver: NSObjectProtocol?
    private(set) var dragFromAnywherePermissionGranted = CGPreflightListenEventAccess()
    private(set) var dragFromAnywhereActive = false
    private(set) var dragFromAnywhereListenerUnavailable = false

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .flagsChanged]) { [weak self] event in
            self?.handle(event)
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshDragFromAnywherePermission() }
        }
        refreshDragFromAnywherePermission()
    }

    func shutdown() {
        nativeGestureGeneration &+= 1
        stopInputTap()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        activationObserver = nil
        reset()
    }

    func setDragFromAnywhereEnabled(_ enabled: Bool) {
        guard enabled else {
            nativeGestureGeneration &+= 1
            stopInputTap()
            if nativeGesture { reset() }
            return
        }
        dragFromAnywherePermissionGranted = CGRequestListenEventAccess()
        if dragFromAnywherePermissionGranted {
            startInputTap()
        } else {
            dragFromAnywherePermissionGranted = CGPreflightListenEventAccess()
            if dragFromAnywherePermissionGranted { startInputTap() }
        }
    }

    func refreshDragFromAnywherePermission() {
        dragFromAnywherePermissionGranted = CGPreflightListenEventAccess()
        if WorkspaceStore.shared.dragFromAnywhereEnabled,
           WorkspaceStore.shared.dragEnabled,
           dragFromAnywherePermissionGranted {
            startInputTap()
        } else {
            stopInputTap()
        }
    }

    func dragEnabledDidChange(_ enabled: Bool) {
        if enabled {
            refreshDragFromAnywherePermission()
        } else {
            nativeGestureGeneration &+= 1
            stopInputTap()
            if nativeGesture { reset() }
        }
    }

    func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func startInputTap() {
        guard inputTap == nil, WorkspaceStore.shared.dragEnabled else { return }
        inputTapGeneration &+= 1
        let generation = inputTapGeneration
        dragFromAnywhereListenerUnavailable = false
        let tap = WindowDragInputTap { [weak self] message in
            DispatchQueue.main.async { @MainActor [weak self] in
                self?.receiveInputTapMessage(message, generation: generation)
            }
        }
        inputTap = tap
        tap.start()
    }

    private func stopInputTap() {
        nativeGestureGeneration &+= 1
        inputTapGeneration &+= 1
        inputTap?.stop()
        inputTap = nil
        dragFromAnywhereActive = false
    }

    private func receiveInputTapMessage(_ message: WindowDragTapMessage,
                                        generation: UInt64) {
        guard generation == inputTapGeneration else { return }
        switch message {
        case let .availability(active):
            dragFromAnywhereActive = active
            if !active {
                dragFromAnywhereListenerUnavailable = true
                inputTap = nil
            }
        case let .began(hit, point):
            guard WorkspaceStore.shared.dragEnabled,
                  WorkspaceStore.shared.dragFromAnywhereEnabled else { return }
            nativeGestureGeneration &+= 1
            nativeGesture = true
            nativeOptionHeld = true
            nativeGestureCommandEpoch = WorkspaceStore.shared.frameCommandRevisionForDrag()
            downPoint = point
            nativePointerPoint = point
            active = true
            element = hit.element
            area = area(at: point)
            dragging = false
            lastRendered = .zero
            startPolling()
        case let .modifierChanged(held):
            guard nativeGesture else { return }
            nativeOptionHeld = held
            poll()
        case let .pointerMoved(point):
            guard nativeGesture else { return }
            nativePointerPoint = point
            poll()
        case let .ended(point, shouldSnap, didMove):
            guard nativeGesture else { return }
            nativePointerPoint = point
            area = area(at: point)
            dragging = didMove
            nativeOptionHeld = shouldSnap
            if shouldSnap, didMove, let element {
                let frame = renderFrame(zone(at: point))
                let gestureGeneration = nativeGestureGeneration
                WorkspaceStore.shared.applyDraggedFrameAfterNativeDrag(
                    frame, element: element,
                    expectedCommandEpoch: nativeGestureCommandEpoch,
                    gestureIsCurrent: { [weak self] in
                        self?.nativeGestureGeneration == gestureGeneration
                    })
            }
            nativeGesture = false
            reset()
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            guard WorkspaceStore.shared.dragEnabled, !nativeGesture,
                  !WindowDragInputTap.isSynthesizedMouseEvent(event.cgEvent) else { return }
            if dragFromAnywhereActive,
               WorkspaceStore.shared.dragFromAnywhereEnabled,
               event.modifierFlags.contains(.option) {
                nativeGestureGeneration &+= 1
                return
            }
            nativeGestureGeneration &+= 1
            downPoint = cursorPoint()
            startPolling()
        case .flagsChanged:
            if downPoint != nil { poll() }
        case .leftMouseUp:
            guard !nativeGesture else { return }
            applyIfNeeded()
            reset()
        default:
            break
        }
    }

    // MARK: - Polling

    private func startPolling(interval: TimeInterval = 1.0 / 15.0) {
        if pollTimer != nil, pollingInterval == interval { return }
        pollTimer?.invalidate()
        pollingInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            // Added to RunLoop.main below: the poll reads UI state on main.
            MainActor.assumeIsolated { self?.poll() }
        }
        // `.common` keeps the timer alive across modal / tracking run-loop modes.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        // The button may be released without us seeing `leftMouseUp` (a native
        // drag can consume it), so `pressedMouseButtons` is the source of truth
        // and the release is never left hanging (B4).
        if NSEvent.pressedMouseButtons == 0, !nativeGesture {
            applyIfNeeded()
            reset()
            return
        }
        // Respect the master switch in Settings.
        guard WorkspaceStore.shared.dragEnabled else {
            reset()
            return
        }
        let cursor = cursorPoint()
        let snapPoint = nativeGesture ? (nativePointerPoint ?? cursor) : cursor
        if nativeGesture { area = area(at: snapPoint) }
        let combo = activatorHeld
        if combo, !active, Date() >= nextHitTest {
            if !begin(at: cursor) { nextHitTest = Date().addingTimeInterval(0.25) }
        }
        startPolling(interval: combo && active ? 1.0 / 60.0 : 1.0 / 15.0)
        guard active else { return }
        guard combo else { hidePreview(); return }

        if !dragging {
            let origin = downPoint ?? snapPoint
            dragging = hypot(snapPoint.x - origin.x, snapPoint.y - origin.y) > Self.dragThreshold
        }
        if dragging { showPreview(renderFrame(zone(at: snapPoint))) }
    }

    private var activatorHeld: Bool {
        if nativeGesture { return nativeOptionHeld }
        return WorkspaceStore.shared.dragActivator.matches(NSEvent.modifierFlags)
    }

    private func cursorPoint() -> CGPoint {
        WindowController.flipPoint(NSEvent.mouseLocation)
    }

    private func area(at axPoint: CGPoint) -> CGRect {
        let cocoaPoint = WindowController.flipPoint(axPoint)
        let screen = NSScreen.screens.first { $0.frame.contains(cocoaPoint) } ?? NSScreen.main
        return WindowController.axVisibleFrame(for: screen)
    }

    /// Captures the window under `point`. Returns false when there is none.
    @discardableResult
    private func begin(at point: CGPoint) -> Bool {
        guard let hit = WindowController.window(at: point) else { return false }
        // Our own panels are placed by their controllers, and an in-process AX
        // write for them belongs to the main thread: never start a tile drag on
        // one (see `WindowController.isOwnProcess`).
        guard hit.pid != ProcessInfo.processInfo.processIdentifier else { return false }
        active = true
        element = hit.element
        area = WindowController.axVisibleFrame(for: WindowController.screen(forAXFrame: hit.frame))
        lastRendered = .zero
        return true
    }

    /// The half / golden zone nearest the pointer (logical, gap not yet inset).
    private func zone(at point: CGPoint) -> CGRect {
        TilingEngine.dragZone(area: area, point: point)
    }

    private func applyIfNeeded() {
        guard WorkspaceStore.shared.dragEnabled else { return }
        guard active, dragging, activatorHeld, let element else { return }
        WorkspaceStore.shared.applyDraggedFrame(renderFrame(zone(at: cursorPoint())), element: element)
    }

    // MARK: - Overlay

    /// Final frame shown and applied: the gap is inset once here, exactly like
    /// the keyboard path, so preview and result agree.
    private func renderFrame(_ logical: CGRect) -> CGRect {
        logical.insetBy(dx: WorkspaceStore.shared.gap / 2, dy: WorkspaceStore.shared.gap / 2).integral
    }

    private func showPreview(_ axFrame: CGRect) {
        let panel = preview ?? makePreview()
        preview = panel
        if axFrame != lastRendered {
            lastRendered = axFrame
            panel.setFrame(WindowController.flip(axFrame), display: true)
        }
        if !previewVisible {
            panel.orderFrontRegardless()
            previewVisible = true
        }
    }

    private func hidePreview() {
        guard previewVisible else { return }
        preview?.orderOut(nil)
        previewVisible = false
    }

    private func reset() {
        nextHitTest = .distantPast
        pollTimer?.invalidate()
        pollTimer = nil
        hidePreview()
        active = false
        dragging = false
        nativeGesture = false
        nativeOptionHeld = false
        nativePointerPoint = nil
        downPoint = nil
        element = nil
        lastRendered = .zero
    }

    private func makePreview() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: DragPreviewBox())
        return panel
    }
}

private struct DragPreviewBox: View {
    /// The active theme's accent, so the drag preview is in-theme.
    private var accent: Color { WorkspaceStore.shared.theme.accent }

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(accent.opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent, lineWidth: 3))
            .padding(1)
    }
}
