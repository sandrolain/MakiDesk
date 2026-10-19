import AppKit
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
final class WindowDrag {
    static let shared = WindowDrag()

    /// Movement (in points) needed before a press counts as a drag.
    private static let dragThreshold: CGFloat = 4

    private var monitor: Any?
    private var pollTimer: Timer?
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

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            self?.handle(event)
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            downPoint = cursorPoint()
            startPolling()
        case .leftMouseUp:
            applyIfNeeded()
            reset()
        default:
            break
        }
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.poll() }
        // `.common` keeps the timer alive across modal / tracking run-loop modes.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        // The button may be released without us seeing `leftMouseUp` (a native
        // drag can consume it), so `pressedMouseButtons` is the source of truth
        // and the release is never left hanging (B4).
        if NSEvent.pressedMouseButtons == 0 {
            applyIfNeeded()
            reset()
            return
        }
        // Respect the master switch in Settings.
        guard WorkspaceStore.shared.dragEnabled else {
            if active { hidePreview() }
            return
        }
        let cursor = cursorPoint()
        let combo = activatorHeld
        if combo, !active {
            begin(at: cursor)
        }
        guard active else { return }
        guard combo else { hidePreview(); return }

        if !dragging {
            let origin = downPoint ?? cursor
            dragging = hypot(cursor.x - origin.x, cursor.y - origin.y) > Self.dragThreshold
        }
        if dragging { showPreview(renderFrame(zone(at: cursor))) }
    }

    private var activatorHeld: Bool {
        WorkspaceStore.shared.dragActivator.matches(NSEvent.modifierFlags)
    }

    private func cursorPoint() -> CGPoint {
        WindowController.flipPoint(NSEvent.mouseLocation)
    }

    /// Captures the window under `point`. Returns false when there is none.
    @discardableResult
    private func begin(at point: CGPoint) -> Bool {
        guard let hit = WindowController.window(at: point) else { return false }
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
        pollTimer?.invalidate()
        pollTimer = nil
        hidePreview()
        active = false
        dragging = false
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
