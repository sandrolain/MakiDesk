import AppKit
import ApplicationServices

/// Authoritative, cached index of application windows plus the event sources
/// that keep it fresh.
///
/// Replaces the "re-discover everything on every call, forever" model (B1/B7)
/// with:
/// - a short TTL cache shared by all callers (no O(n) re-discovery per access);
/// - one Accessibility observer per application (window created / moved /
///   resized / destroyed / miniaturised / focused, application activated);
/// - NSWorkspace launch / terminate / activate notifications;
/// - a 250 ms debounce before listeners are told the model changed;
/// - screen-parameter change notifications.
final class WindowIndex {
    static let shared = WindowIndex()

    /// Debounced: the window set or a window's frame changed.
    var onChange: (() -> Void)?
    /// Debounced: the focused window or the active application changed.
    var onFocusChange: (() -> Void)?
    /// Immediate: a window moved or resized. The focused-window border uses
    /// this so it follows a drag instead of waiting out the debounce.
    var onGeometryNow: (() -> Void)?
    /// Immediate: the focused window or the active application changed.
    var onFocusNow: (() -> Void)?
    /// The screen configuration changed (monitor added/removed, Dock shown…).
    var onScreenChange: (() -> Void)?

    /// How long a discovery result is reused before it is read again.
    private let ttl: TimeInterval = 0.3
    private let debounce: TimeInterval = 0.25

    private var cache: [WindowController.WindowInfo] = []
    private var cachedAt = Date.distantPast
    private var observers: [pid_t: AXObserver] = [:]
    private var started = false
    private var pendingChange: DispatchWorkItem?
    private var pendingFocus: DispatchWorkItem?

    private init() {}

    /// Installs the observers. Safe to call more than once.
    func start() {
        guard !started else { return }
        started = true
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(appLaunched(_:)),
                              name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(appTerminated(_:)),
                              name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(appActivated(_:)),
                              name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        refreshObservers()
        cachedAt = .distantPast
    }

    /// Cached window list, front-to-back. Re-reads only when the cache is stale
    /// unless `force` is set.
    @discardableResult
    func windows(includeMinimized: Bool = false, force: Bool = false) -> [WindowController.WindowInfo] {
        if force || Date().timeIntervalSince(cachedAt) > ttl {
            cache = WindowController.discoverWindows(includeMinimized: true)
            cachedAt = Date()
        }
        return includeMinimized ? cache : cache.filter { !$0.minimized }
    }

    /// Marks the cache stale so the next access re-reads reality.
    func invalidate() { cachedAt = .distantPast }

    // MARK: - Accessibility observers

    private func refreshObservers() {
        let pids = Set(NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular
                    && !$0.isTerminated
                    && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }
            .map(\.processIdentifier))

        for pid in pids where observers[pid] == nil { addObserver(for: pid) }
        for pid in observers.keys where !pids.contains(pid) {
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                      AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
    }

    private func addObserver(for pid: pid_t) {
        var observerRef: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let index = Unmanaged<WindowIndex>.fromOpaque(refcon).takeUnretainedValue()
            index.note(notification: notification as String)
        }
        guard AXObserverCreate(pid, callback, &observerRef) == .success, let observer = observerRef else {
            return
        }
        let appElement = AXUIElementCreateApplication(pid)
        let notifications = [
            kAXWindowCreatedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXUIElementDestroyedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXFocusedWindowChangedNotification,
            kAXApplicationActivatedNotification
        ]
        for name in notifications {
            _ = AXObserverAddNotification(observer, appElement, name as CFString,
                                          Unmanaged.passUnretained(self).toOpaque())
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    /// Geometry events refresh the window list only; a dedicated focus check runs
    /// just for focus/activation events, so dragging a window does not keep
    /// re-querying the frontmost window.
    private func note(notification: String) {
        invalidate()
        if notification == kAXWindowMovedNotification as String
            || notification == kAXWindowResizedNotification as String {
            onGeometryNow?()
        }
        scheduleChange()
        if notification == kAXFocusedWindowChangedNotification as String
            || notification == kAXApplicationActivatedNotification as String {
            onFocusNow?()
            scheduleFocus()
        }
    }

    private func scheduleChange() {
        pendingChange?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange?() }
        pendingChange = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    private func scheduleFocus() {
        pendingFocus?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onFocusChange?() }
        pendingFocus = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    // MARK: - Workspace / screen notifications

    @objc private func appLaunched(_ note: Notification) {
        refreshObservers()
        invalidate()
        scheduleChange()
        scheduleFocus()
    }

    @objc private func appTerminated(_ note: Notification) {
        refreshObservers()
        invalidate()
        scheduleChange()
        scheduleFocus()
    }

    @objc private func appActivated(_ note: Notification) {
        invalidate()
        onFocusNow?()
        scheduleFocus()
    }

    @objc private func screensChanged() {
        invalidate()
        onScreenChange?()
        scheduleChange()
    }
}
