import AppKit

/// The display that most recently hosted something the user did — a window
/// taking focus or the pointer arriving on it. The floating cards (checklist,
/// countdowns, the mini map) and the panels that open on demand (switcher,
/// search) follow this display instead of assuming the menu-bar screen.
///
/// Focus and pointer are kept apart and the newer event wins, so the rule is
/// exactly "the monitor of the last focus change or mouse move". A move inside
/// the same display still counts as the newest event: after the keyboard moved
/// to another display, moving the pointer back brings the cards back with it.
@MainActor
final class ActiveDisplayTracker {
    static let shared = ActiveDisplayTracker()

    /// One observer per controller that follows the active display.
    private var observers: [UUID: (NSScreen) -> Void] = [:]
    private var focus: (id: CGDirectDisplayID, at: Date)?
    private var mouse: (id: CGDirectDisplayID, at: Date)?
    private var lastAnnounced: CGDirectDisplayID?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var started = false

    private init() {}

    /// Starts the two pointer monitors and the display-change observer. Safe to
    /// call more than once. `WorkspaceStore` starts it before the panels.
    func start() {
        guard !started else { return }
        started = true
        // A global monitor sees moves while another app is active; the local
        // one covers the same events when a MakiDesk panel has the keys.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            // Global mouse monitors deliver on the main run loop.
            MainActor.assumeIsolated { self?.notePointer() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated { self?.notePointer() }
            return event
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        // No pointer sample here: until the user moves or focuses something,
        // `currentScreen` falls back to the system's key-window display, which
        // is where the focus is at launch.
    }

    /// The display to use right now, with the same fallback everywhere: the
    /// newest event's display, then the system's idea, then the first screen.
    var currentScreen: NSScreen? {
        let chosen = ActiveDisplaySelection.mostRecent(
            focusID: focus?.id, focusAt: focus?.at ?? .distantPast,
            mouseID: mouse?.id, mouseAt: mouse?.at ?? .distantPast
        )
        if let chosen, let screen = screen(with: chosen) { return screen }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Called when a window gains focus. The frame is in Accessibility
    /// coordinates, like every other window frame in the index.
    func noteFocus(frame: CGRect) {
        guard let screen = WindowController.screen(forAXFrame: frame),
              let id = PaletteScreenLocation.displayID(screen) else { return }
        focus = (id, Date())
        announceIfNeeded()
    }

    /// Adds a follower. The returned token removes it again; the controllers
    /// here live for the whole app, but the token keeps teardown possible.
    @discardableResult
    func addObserver(_ body: @escaping (NSScreen) -> Void) -> UUID {
        let token = UUID()
        observers[token] = body
        return token
    }

    func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    private func notePointer() {
        guard let screen = screen(containing: NSEvent.mouseLocation),
              let id = PaletteScreenLocation.displayID(screen) else { return }
        // Even a move inside one display is the newest event: after a focus
        // change elsewhere, moving the pointer back must bring the cards back.
        mouse = (id, Date())
        announceIfNeeded()
    }

    private func screensChanged() {
        focus = focus.flatMap { entry in
            screen(with: entry.id).map { _ in (entry.id, entry.at) }
        }
        mouse = mouse.flatMap { entry in
            screen(with: entry.id).map { _ in (entry.id, entry.at) }
        }
        // The pointer may now be on a display that just appeared, or on a
        // surviving one with a new origin. A pointer that was never seen is
        // not invented here: the fallback keeps the focus display.
        if mouse != nil { notePointer() }
        announceIfNeeded(force: true)
    }

    private func announceIfNeeded(force: Bool = false) {
        guard let screen = currentScreen,
              let id = PaletteScreenLocation.displayID(screen) else { return }
        guard force || id != lastAnnounced else { return }
        lastAnnounced = id
        for observer in observers.values { observer(screen) }
    }

    private func screen(with id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { PaletteScreenLocation.displayID($0) == id }
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}

/// The pure part of the rule, so "the newest event wins" is checked without a
/// display attached.
enum ActiveDisplaySelection {
    static func mostRecent(focusID: CGDirectDisplayID?, focusAt: Date,
                           mouseID: CGDirectDisplayID?, mouseAt: Date) -> CGDirectDisplayID? {
        if let mouseID, mouseAt >= focusAt { return mouseID }
        return focusID ?? mouseID
    }
}
