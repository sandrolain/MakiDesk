import AppKit
import CoreGraphics

/// The shared screen-region selector (T49).
///
/// One overlay per display, a still capture of the display under the pointer for
/// the loupe, drag to select, `Esc` or a click to cancel. It returns the
/// selection in AppKit global coordinates together with the crop at native pixel
/// size, so the same call feeds text recognition (T41), screenshot and
/// annotation (T40), the colour picker (T36) and the on-screen ruler (T39).
///
/// Usage, from the main actor:
///
/// ```swift
/// do {
///     let selection = try await ScreenRegionSelector.shared.select()
///     // selection.image is a CGImage at native scale; selection.rect is global.
/// } catch ScreenRegionError.cancelled {
///     // The user pressed Esc, right-clicked or clicked without dragging.
/// }
/// ```
///
/// `onChange` reports the live rectangle while dragging, for consumers that
/// measure instead of capturing (T39).
@MainActor
final class ScreenRegionSelector {
    enum Mode: Equatable, Sendable {
        /// Drag a rectangle.
        case rectangle
        /// Click a single point; the returned image is the point's pixel.
        case point
    }

    /// Which axes snapped during the drag (T39).
    struct SnapInfo: Equatable, Sendable {
        var axisX = false
        var axisY = false

        static let none = SnapInfo()
    }

    /// Per-session options. The defaults match the rectangle capture OCR and the
    /// colour picker use; the ruler asks for a lighter dim, no required capture
    /// and its own label (T39).
    struct Options {
        /// The caller needs the pixels: Screen Recording is required and the
        /// final capture is returned.
        var capturesPixels = true
        /// The loupe needs a capture; it also appears only when permitted.
        var showsLoupe = true
        /// How dark the overlay makes the screen.
        var dimAlpha: CGFloat = 0.45
        /// Snap to window and display centres as well as their edges.
        var snapToCenters = false
        /// Apply ⇧ (square) and ⌥ (from the centre) while dragging. Off for
        /// text recognition and the colour picker.
        var respectsModifiers = false
        /// Replaces the default hint on the display with the pointer.
        var hint: String?
        /// Replaces the default accessibility label of each overlay.
        var accessibilityLabel: String?
        /// The live badge text; `nil` keeps the default size label.
        var label: ((CGRect, ScreenRegionDisplay, SnapInfo) -> String)?
    }

    struct Selection {
        /// AppKit global coordinates.
        let rect: CGRect
        let display: ScreenRegionDisplay
        /// The selection at native pixel size; `nil` when the caller did not
        /// ask for pixels (T39).
        let image: CGImage?
        /// The clicked point in `.point` mode, otherwise `nil`.
        let point: CGPoint?
        /// Which axes were snapped when the selection ended.
        let snapped: SnapInfo

        init(rect: CGRect, display: ScreenRegionDisplay, image: CGImage?,
             point: CGPoint?, snapped: SnapInfo = .none) {
            self.rect = rect
            self.display = display
            self.image = image
            self.point = point
            self.snapped = snapped
        }
    }

    static let shared = ScreenRegionSelector()

    /// Accent used for the selection border, handles and labels.
    var accentColor: NSColor = .controlAccentColor
    /// The loupe needs a still capture; selection works without it.
    var showsLoupe = true
    /// Snap the moving edges to window and display edges.
    var snapToWindows = true
    var snapTolerance: CGFloat = 6
    /// Live rectangle while dragging, `nil` when the drag resets or ends.
    var onChange: ((CGRect?, SnapInfo) -> Void)?

    var isSelecting: Bool { continuation != nil }

    private struct Overlay {
        let display: ScreenRegionDisplay
        let window: NSPanel
        let view: ScreenRegionOverlayView
    }

    private var overlays: [Overlay] = []
    private var continuation: CheckedContinuation<Selection, Error>?
    private var mode: Mode = .rectangle
    private var options = Options()
    private var currentSnap = SnapInfo.none
    private var focusReturn = PanelFocusReturn()

    private var dragStart: CGPoint?
    private var currentRect: CGRect?
    private var activeDisplayID: CGDirectDisplayID?
    private var snapEdgesX: [CGFloat] = []
    private var snapEdgesY: [CGFloat] = []

    private var snapshot: (display: ScreenRegionDisplay, image: CGImage)?
    private var snapshotRequest: CGDirectDisplayID?
    private var snapshotFailedDisplay: CGDirectDisplayID?
    private var snapshotTask: Task<Void, Never>?
    private var snapshotGeneration: UInt64 = 0
    private var resignObserver: NSObjectProtocol?

    private init() {}

    // MARK: - Public API

    func select(mode: Mode = .rectangle, options: Options = Options()) async throws -> Selection {
        guard continuation == nil else { throw ScreenRegionError.alreadySelecting }
        if options.capturesPixels, ScreenRegionCapture.isAuthorized == false {
            throw ScreenRegionError.permissionDenied
        }
        let displays = Self.availableDisplays()
        guard displays.isEmpty == false else { throw ScreenRegionError.displayUnavailable }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.mode = mode
                self.options = options
                self.currentRect = nil
                self.currentSnap = .none
                self.dragStart = nil
                self.begin(displays: displays)
            }
        } onCancel: {
            // The caller gave up (a panel closed mid-selection): close the
            // overlay instead of leaving it on screen forever.
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    /// Ends the current selection as cancelled. Safe to call when nothing is
    /// open.
    func cancel() {
        guard let continuation else { return }
        self.continuation = nil
        onChange?(nil, .none)
        tearDown(restoreFocus: true)
        continuation.resume(throwing: ScreenRegionError.cancelled)
    }

    // MARK: - Session

    private func begin(displays: [ScreenRegionDisplay]) {
        focusReturn.capture()
        prepareSnapEdges(displays: displays)
        overlays = displays.map(makeOverlay)

        // Switching to another app with Cmd-Tab must not leave an overlay that
        // no longer receives the keyboard: the session cancels instead.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }

        let pointer = NSEvent.mouseLocation
        let active = ScreenRegionGeometry.display(containing: pointer, in: displays)
        activeDisplayID = active?.id

        NSApp.activate(ignoringOtherApps: true)
        for overlay in overlays {
            overlay.window.orderFrontRegardless()
        }
        if let overlay = overlays.first(where: { $0.display.id == active?.id }) ?? overlays.first {
            overlay.window.makeKeyAndOrderFront(nil)
            overlay.window.makeFirstResponder(overlay.view)
            overlay.view.setPointer(local(pointer, in: overlay.display))
        }
        // Only the screen with the pointer carries the hint; the others are
        // just dimmed while the drag stays on its own display.
        overlays.first(where: { $0.display.id == active?.id })?.view.hintText =
            options.hint ?? (mode == .point
                ? "Click a colour · Esc to cancel"
                : "Drag to select an area · Esc to cancel")

        if let active {
            ensureSnapshot(for: active)
        }
    }

    private func makeOverlay(for display: ScreenRegionDisplay) -> Overlay {
        let window = ScreenRegionOverlayWindow(
            contentRect: display.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                     .stationary, .ignoresCycle]
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.setFrame(display.frame, display: false)

        let view = ScreenRegionOverlayView(frame: CGRect(origin: .zero, size: display.frame.size))
        view.accentColor = accentColor
        view.showsLoupe = showsLoupe && options.showsLoupe && ScreenRegionCapture.isAuthorized
        view.dimAlpha = options.dimAlpha
        view.showsColorPreview = mode == .point
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel(options.accessibilityLabel ?? (mode == .point
            ? "Pick a colour from the screen"
            : "Select an area of the screen"))
        view.onPointerMoved = { [weak self] point in
            self?.pointerMoved(point, displayID: display.id)
        }
        view.onMouseDown = { [weak self] point in
            self?.dragBegan(point, displayID: display.id)
        }
        view.onMouseDragged = { [weak self] point in
            self?.dragMoved(point, displayID: display.id)
        }
        view.onMouseUp = { [weak self] point in
            self?.dragEnded(point, displayID: display.id)
        }
        view.onCancel = { [weak self] in
            self?.cancel()
        }
        window.contentView = view
        return Overlay(display: display, window: window, view: view)
    }

    // MARK: - Pointer

    private func pointerMoved(_ point: CGPoint, displayID: CGDirectDisplayID) {
        guard let overlay = overlay(for: displayID) else { return }
        // A fresh crosshair must not stay behind on the screen we left.
        for other in overlays where other.display.id != displayID {
            other.view.setPointer(nil)
        }
        activeDisplayID = displayID
        ensureSnapshot(for: overlay.display)
    }

    private func dragBegan(_ point: CGPoint, displayID: CGDirectDisplayID) {
        guard let overlay = overlay(for: displayID) else { return }
        overlay.window.makeKeyAndOrderFront(nil)
        overlay.window.makeFirstResponder(overlay.view)
        activeDisplayID = displayID
        dragStart = global(point, in: overlay.display)
        currentRect = nil
        currentSnap = .none
        overlay.view.setSelection(nil, label: nil)
        onChange?(nil, .none)
        ensureSnapshot(for: overlay.display)
    }

    private func dragMoved(_ point: CGPoint, displayID: CGDirectDisplayID) {
        // In point mode a drag only moves the pointer: the loupe follows it and
        // the click picks one pixel, so there is no rectangle to draw.
        guard mode == .rectangle else { return }
        guard let overlay = overlay(for: displayID), let dragStart else { return }
        let end = global(point, in: overlay.display)
        let flags = NSEvent.modifierFlags
        let raw = ScreenRegionGeometry.measureRect(
            from: dragStart, to: end,
            centered: options.respectsModifiers && flags.contains(.option),
            square: options.respectsModifiers && flags.contains(.shift)
        )
        var visual = ScreenRegionGeometry.clamped(raw, to: overlay.display)
        var snapInfo = SnapInfo.none
        if visual.width >= ScreenRegionGeometry.minimumSide,
           visual.height >= ScreenRegionGeometry.minimumSide {
            let snap = ScreenRegionGeometry.snapped(visual,
                                                    edgesX: snapEdgesX, edgesY: snapEdgesY,
                                                    tolerance: snapTolerance)
            // A window edge can sit outside the display (a window dragged partly
            // off-screen), so the snapped result is clamped again.
            visual = ScreenRegionGeometry.clamped(snap.rect, to: overlay.display)
            snapInfo = SnapInfo(axisX: snap.snappedX, axisY: snap.snappedY)
        }
        let isValid = visual.width >= ScreenRegionGeometry.minimumSide
            && visual.height >= ScreenRegionGeometry.minimumSide
        currentRect = isValid ? visual : nil
        currentSnap = isValid ? snapInfo : .none
        let label = currentRect.map { rect in
            options.label?(rect, overlay.display, currentSnap)
                ?? ScreenRegionGeometry.sizeLabel(for: rect, scale: overlay.display.scale)
        }
        overlay.view.setSelection(local(visual, in: overlay.display), label: label)
        onChange?(currentRect, currentSnap)
    }

    private func dragEnded(_ point: CGPoint, displayID: CGDirectDisplayID) {
        guard let overlay = overlay(for: displayID) else { return }
        let end = global(point, in: overlay.display)

        if mode == .point {
            let x = min(max(end.x, overlay.display.frame.minX), overlay.display.frame.maxX - 1)
            let y = min(max(end.y, overlay.display.frame.minY), overlay.display.frame.maxY - 1)
            finish(rect: CGRect(x: x, y: y, width: 1, height: 1),
                   display: overlay.display, point: CGPoint(x: x, y: y))
            return
        }

        if let rect = currentRect {
            finish(rect: rect, display: overlay.display, point: nil)
        } else {
            // A click without a drag is a cancellation, like Esc.
            cancel()
        }
    }

    // MARK: - Completion

    private func finish(rect: CGRect, display: ScreenRegionDisplay, point: CGPoint?) {
        guard let continuation else { return }
        self.continuation = nil
        let snapped = currentSnap
        onChange?(nil, .none)
        let needsPixels = options.capturesPixels
        let cached = snapshot?.display.id == display.id ? snapshot?.image : nil
        tearDown(restoreFocus: true)

        Task { @MainActor in
            guard needsPixels else {
                continuation.resume(returning: Selection(rect: rect, display: display,
                                                         image: nil, point: point,
                                                         snapped: snapped))
                return
            }
            do {
                let source: CGImage
                if let cached {
                    source = cached
                } else {
                    // The overlays are gone, so nothing of ours is on screen.
                    source = try await ScreenRegionCapture.capture(display: display)
                }
                let image = try ScreenRegionCapture.image(of: rect, in: display, from: source)
                continuation.resume(returning: Selection(rect: rect, display: display,
                                                         image: image, point: point,
                                                         snapped: snapped))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func tearDown(restoreFocus: Bool) {
        snapshotGeneration &+= 1
        snapshotTask?.cancel()
        snapshotTask = nil
        snapshotRequest = nil
        snapshotFailedDisplay = nil
        snapshot = nil
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }

        let restore = restoreFocus
            ? focusReturn.takeRestoreAction(ownsKeyboard: NSApp.isActive)
            : nil
        for overlay in overlays {
            overlay.window.orderOut(nil)
            overlay.window.contentView = nil
            overlay.window.close()
        }
        overlays.removeAll()
        dragStart = nil
        currentRect = nil
        activeDisplayID = nil
        restore?()
    }

    // MARK: - Still capture for the loupe

    private func ensureSnapshot(for display: ScreenRegionDisplay) {
        if snapshot?.display.id == display.id { return }
        if snapshotRequest == display.id { return }
        if snapshotFailedDisplay == display.id { return }
        guard ScreenRegionCapture.isAuthorized else { return }

        snapshotRequest = display.id
        snapshotGeneration &+= 1
        let generation = snapshotGeneration
        let excluded = overlays.map { CGWindowID(truncatingIfNeeded: $0.window.windowNumber) }

        snapshotTask = Task { @MainActor [weak self] in
            let image = try? await ScreenRegionCapture.capture(display: display,
                                                               excluding: excluded)
            guard let self else { return }
            guard self.snapshotGeneration == generation,
                  self.continuation != nil else { return }
            self.snapshotRequest = nil
            guard let image else {
                // One failed capture per session and display: a permission that
                // was revoked mid-session must not be retried on every move.
                self.snapshotFailedDisplay = display.id
                return
            }
            self.snapshot = (display, image)
            // One display image at a time: on a 5K screen each is ~59 MB, and
            // the loupe only ever shows the display under the pointer.
            for overlay in self.overlays {
                if overlay.display.id == display.id {
                    overlay.view.setSnapshot(image, displaySize: display.frame.size)
                } else {
                    overlay.view.setSnapshot(nil, displaySize: .zero)
                }
            }
        }
    }

    // MARK: - Helpers

    private func overlay(for displayID: CGDirectDisplayID) -> Overlay? {
        overlays.first { $0.display.id == displayID }
    }

    private func global(_ local: CGPoint, in display: ScreenRegionDisplay) -> CGPoint {
        CGPoint(x: display.frame.minX + local.x, y: display.frame.minY + local.y)
    }

    private func local(_ point: CGPoint, in display: ScreenRegionDisplay) -> CGPoint {
        CGPoint(x: point.x - display.frame.minX, y: point.y - display.frame.minY)
    }

    private func local(_ rect: CGRect, in display: ScreenRegionDisplay) -> CGRect {
        CGRect(x: rect.minX - display.frame.minX, y: rect.minY - display.frame.minY,
               width: rect.width, height: rect.height)
    }

    private func prepareSnapEdges(displays: [ScreenRegionDisplay]) {
        var frames = displays.map(\.frame)
        if snapToWindows {
            // A published snapshot, never a discovery: the overlay is opened
            // from an interactive command and must not wait for Accessibility.
            frames += WindowIndex.shared.snapshot().map { WindowController.flip($0.frame) }
        }
        let edges = ScreenRegionGeometry.edges(of: frames)
        if options.snapToCenters {
            snapEdgesX = (edges.x + frames.map(\.midX)).sorted()
            snapEdgesY = (edges.y + frames.map(\.midY)).sorted()
        } else {
            snapEdgesX = edges.x
            snapEdgesY = edges.y
        }
    }

    private static func availableDisplays() -> [ScreenRegionDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber else { return nil }
            return ScreenRegionDisplay(id: CGDirectDisplayID(number.uint32Value),
                                       frame: screen.frame,
                                       scale: screen.backingScaleFactor)
        }
    }
}

/// A borderless panel that can take the keyboard for `Esc` without becoming the
/// main window.
private final class ScreenRegionOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
