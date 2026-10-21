import AppKit
import ApplicationServices
import os

/// Authoritative, cached index of application windows plus the event sources
/// that keep it fresh.
///
/// Replaces the "re-discover everything on every call, forever" model (B1/B7)
/// with:
/// - a published snapshot shared by all callers (no discovery per access);
/// - lazy Accessibility observers for up to four recently active applications (window created / moved /
///   resized / destroyed / miniaturised / focused, application activated);
/// - NSWorkspace launch / terminate / activate notifications;
/// - a 250 ms debounce before listeners are told the model changed;
/// - screen-parameter change notifications.
final class WindowIndex {
    static let shared = WindowIndex()

    /// Debounced: the window inventory changed (created, destroyed, hidden…).
    var onChange: (() -> Void)?
    /// Debounced: the focused window or the active application changed.
    var onFocusChange: (() -> Void)?
    /// Immediate: a window moved or resized. The focused-window border uses
    /// this so it follows a drag instead of waiting out the debounce.
    var onGeometryNow: (() -> Void)?
    /// Debounced, targeted frame updates. Geometry changes do not rebuild the
    /// entire window list; the owner updates only the affected model entries.
    var onGeometryChanged: ((AXUIElement, CGRect) -> Void)?
    /// Immediate: the focused window or the active application changed.
    var onFocusNow: (() -> Void)?
    /// The screen configuration changed (monitor added/removed, Dock shown…).
    var onScreenChange: (() -> Void)?
    var onApplicationTerminated: ((pid_t) -> Void)?

    private let debounce: TimeInterval = 0.25

    private var cache: [WindowController.WindowInfo] = []
    private var observers: [pid_t: AXObserver] = [:]
    private var failedObserverCreation = Set<pid_t>()
    private var failedNotifications: [pid_t: Set<String>] = [:]
    private var observerRetryTimer: Timer?
    private var started = false
    private var pendingChange: DispatchWorkItem?
    private var pendingFocus: DispatchWorkItem?
    private var pendingGeometry: [AXUIElement] = []
    private var pendingGeometryWork: DispatchWorkItem?
    private var asyncRefreshInFlight = false
    private var asyncRefreshWaiters: [([WindowController.WindowInfo]) -> Void] = []
    private var inventoryRevision: UInt64 = 0
    private var dirtyPIDs: Set<pid_t>?
    private var fullRefreshRequested = false
    private var activeScanIsFull = false
    private var frameUpdates: [(element: AXUIElement, frame: CGRect)] = []
    private let discover: () -> WindowController.WindowInventoryRead
    private let discoverPIDs: (Set<pid_t>) -> WindowController.WindowInventoryRead
    private let scheduleDiscovery: (@escaping () -> Void) -> Void
    private let performanceSignposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.makidesk.app",
        category: "Window Performance"
    )

    init(discover: (() -> [WindowController.WindowInfo])? = nil,
         readInventory: (() -> WindowController.WindowInventoryRead)? = nil,
         readForPIDs: ((Set<pid_t>) -> WindowController.WindowInventoryRead)? = nil,
         scheduleDiscovery: @escaping (@escaping () -> Void) -> Void = { work in
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }) {
        if let readInventory { self.discover = readInventory }
        else if let discover { self.discover = { WindowController.WindowInventoryRead(windows: discover()) } }
        else { self.discover = { WindowController.discoverInventory(includeMinimized: true) } }
        discoverPIDs = readForPIDs ?? { WindowController.discoverInventory(includeMinimized: true, onlyPIDs: $0) }
        self.scheduleDiscovery = scheduleDiscovery
    }

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
        // Do not perform cross-process Accessibility registration while the
        // SwiftUI app is still constructing its menu bar scene.
        DispatchQueue.main.async { [weak self] in self?.refreshObservers() }
    }

    /// Returns the last published snapshot without triggering Accessibility I/O.
    /// This is used by latency-sensitive UI such as the window switcher.
    func snapshot(includeMinimized: Bool = false) -> [WindowController.WindowInfo] {
        includeMinimized ? cache : cache.filter { !$0.minimized }
    }

    /// Refreshes the inventory on a worker queue and publishes the result on the
    /// main queue. Concurrent callers join the same scan.
    func refreshAsync(completion: @escaping ([WindowController.WindowInfo]) -> Void) {
        if asyncRefreshInFlight && !activeScanIsFull && !fullRefreshRequested {
            inventoryRevision &+= 1
        }
        fullRefreshRequested = true
        enqueueRefresh(completion: completion)
    }

    func refreshChangedAsync(completion: @escaping ([WindowController.WindowInfo]) -> Void) {
        if let dirtyPIDs, dirtyPIDs.isEmpty, !asyncRefreshInFlight {
            completion(cache)
            return
        }
        enqueueRefresh(completion: completion)
    }

    private func enqueueRefresh(completion: @escaping ([WindowController.WindowInfo]) -> Void) {
        asyncRefreshWaiters.append(completion)
        guard !asyncRefreshInFlight else { return }
        asyncRefreshInFlight = true
        beginRefresh()
    }

    private func beginRefresh() {
        let revision = inventoryRevision
        let scope = fullRefreshRequested ? nil : dirtyPIDs
        activeScanIsFull = scope == nil
        let scanInterval = performanceSignposter.beginInterval("AX window discovery")
        let discover = self.discover
        let discoverPIDs = self.discoverPIDs
        scheduleDiscovery { [weak self] in
            let read = scope.map { discoverPIDs($0) } ?? discover()
            DispatchQueue.main.async {
                guard let self else { return }
                self.performanceSignposter.endInterval("AX window discovery", scanInterval)
                guard self.inventoryRevision == revision else {
                    self.beginRefresh()
                    return
                }
                let relevant = self.cache.filter { scope?.contains($0.pid) ?? true }
                let unchanged = scope.map { pids in self.cache.filter { !pids.contains($0.pid) } } ?? []
                let discovered = unchanged + Self.retainingUnavailable(previous: relevant, read: read)
                var stableDiscovery = Self.reconcile(previous: self.cache, discovered: discovered)
                for update in self.frameUpdates {
                    if let index = stableDiscovery.firstIndex(where: { CFEqual($0.element, update.element) }) {
                        stableDiscovery[index].frame = update.frame
                    }
                }
                for index in stableDiscovery.indices {
                    if let id = stableDiscovery[index].windowID, let rank = read.stackingOrder[id] {
                        stableDiscovery[index].zIndex = rank
                    }
                }
                stableDiscovery.sort { $0.zIndex == $1.zIndex ? $0.id < $1.id : $0.zIndex < $1.zIndex }
                self.frameUpdates.removeAll()
                self.cache = stableDiscovery
                self.dirtyPIDs = []
                self.fullRefreshRequested = false
                self.asyncRefreshInFlight = false
                let waiters = self.asyncRefreshWaiters
                self.asyncRefreshWaiters.removeAll()
                waiters.forEach { $0(stableDiscovery) }
                if self.started { self.refreshObservers() }
            }
        }
    }

    /// Marks the cache stale so the next access re-reads reality.
    func invalidate(pid: pid_t? = nil) {
        inventoryRevision &+= 1
        if let pid { dirtyPIDs?.insert(pid) }
        else { dirtyPIDs = nil }
    }

    func updateFrame(_ frame: CGRect, for element: AXUIElement) {
        if let index = cache.firstIndex(where: { CFEqual($0.element, element) }) {
            cache[index].frame = frame
        }
        guard asyncRefreshInFlight else { return }
        frameUpdates.removeAll { CFEqual($0.element, element) }
        frameUpdates.append((element, frame))
    }

    /// Keep an already-seen window's identity when an app exposes no stable
    /// window number or AX identifier and its enumeration index changes.
    static func reconcile(
        previous: [WindowController.WindowInfo], discovered: [WindowController.WindowInfo]
    ) -> [WindowController.WindowInfo] {
        var claimed = Set<String>()
        var identities: [Int: String] = [:]
        for (index, candidate) in discovered.enumerated() {
            if let known = previous.first(where: {
                !claimed.contains($0.id) && CFEqual($0.element, candidate.element)
            }) {
                identities[index] = known.id
                claimed.insert(known.id)
            }
        }
        // Reserve old IDs before assigning new ones, including retired index
        // IDs. An insertion must never inherit another window's identity.
        var reserved = claimed.union(previous.map(\.id))
        return discovered.enumerated().map { index, candidate in
            var result = candidate
            if let identity = identities[index] {
                result.id = identity
            } else {
                if reserved.contains(result.id) || result.id.hasPrefix("\(result.pid)-idx") {
                    result.id = "\(result.pid)-runtime-\(UUID().uuidString)"
                }
                reserved.insert(result.id)
            }
            return result
        }
    }

    // MARK: - Accessibility observers

    static func retainingUnavailable(previous: [WindowController.WindowInfo],
                                     read: WindowController.WindowInventoryRead) -> [WindowController.WindowInfo] {
        var result = read.windows
        for old in previous where read.unavailablePIDs.contains(old.pid) {
            guard !result.contains(where: { CFEqual($0.element, old.element) }) else { continue }
            var retained = old
            retained.temporarilyUnavailable = true
            result.append(retained)
        }
        return result
    }

    private let observerQueue = DispatchQueue(label: "com.makidesk.ax-observers", qos: .utility)
    private var observerWork = Set<pid_t>()
    private var observerAttempts: [pid_t: Int] = [:]
    private var observerLastUsed: [pid_t: Date] = [:]
    private var observedWindows: [pid_t: [AXUIElement]] = [:]

    private func refreshObservers() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy != .prohibited, !app.isTerminated,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let pid = app.processIdentifier
        observerLastUsed[pid] = Date()
        guard !observerWork.contains(pid) else { return }
        let existing = observers[pid]
        let appNames = Set([kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                            kAXApplicationActivatedNotification].map { $0 as String })
        let windowNames = Set([kAXWindowMovedNotification, kAXWindowResizedNotification,
            kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification].map { $0 as String })
        let failed = failedNotifications[pid] ?? []
        let names = existing == nil ? appNames : failed.intersection(appNames)
        let windows = cache.filter { $0.pid == pid }.map(\.element)
        let previousWindows = observedWindows[pid] ?? []
        let newWindows = windows.filter { candidate in !previousWindows.contains { CFEqual($0, candidate) } }
        let registrationWindows = failed.isDisjoint(with: windowNames) ? newWindows : windows
        guard existing == nil || !names.isEmpty || !registrationWindows.isEmpty else { return }
        let attempts = observerAttempts[pid, default: 0]
        guard attempts < 4 || !newWindows.isEmpty else { return }
        observerAttempts[pid] = !newWindows.isEmpty ? 1 : attempts + 1
        observerWork.insert(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let interval = performanceSignposter.beginInterval("AX observer registration")
        observerQueue.async { [self] in
            var observer = existing
            if observer == nil {
                let callback: AXObserverCallback = { _, element, notification, refcon in
                    guard let refcon else { return }
                    let index = Unmanaged<WindowIndex>.fromOpaque(refcon).takeUnretainedValue()
                    index.note(notification: notification as String, element: element)
                }
                _ = AXObserverCreate(pid, callback, &observer)
            }
            var failed = Set<String>()
            if let observer {
                let appElement = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(appElement, 0.1)
                for name in names {
                    let result = AXObserverAddNotification(observer, appElement, name as CFString, context)
                    // Unsupported notifications cannot recover by polling.
                    if result == .cannotComplete || result == .failure { failed.insert(name) }
                }
                for window in registrationWindows {
                    AXUIElementSetMessagingTimeout(window, 0.05)
                    for name in windowNames {
                        let result = AXObserverAddNotification(observer, window, name as CFString, context)
                        if result == .cannotComplete || result == .failure { failed.insert(name) }
                    }
                }
            }
            let registered = observer
            let retryNames = failed
            DispatchQueue.main.async { [self] in
                performanceSignposter.endInterval("AX observer registration", interval)
                observerWork.remove(pid)
                guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
                if let registered {
                    if observers[pid] == nil {
                        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(registered), .commonModes)
                    }
                    observers[pid] = registered
                    failedObserverCreation.remove(pid)
                    failedNotifications[pid] = retryNames.isEmpty ? nil : retryNames
                    observedWindows[pid] = windows
                } else {
                    failedObserverCreation.insert(pid)
                }
                trimObservers()
                scheduleObserverRetryIfNeeded()
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                   cache.contains(where: { candidate in
                       candidate.pid == pid && !windows.contains { CFEqual($0, candidate.element) }
                   }) {
                    refreshObservers()
                }
            }
        }
    }

    private func removeObserver(for pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        failedNotifications[pid] = nil
        failedObserverCreation.remove(pid)
        observerAttempts[pid] = nil
        observerLastUsed[pid] = nil
        observedWindows[pid] = nil
    }

    private func trimObservers() {
        let activePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        while observers.count > 4,
              let oldest = observerLastUsed.filter({ $0.key != activePID && observers[$0.key] != nil })
                .min(by: { $0.value < $1.value })?.key {
            removeObserver(for: oldest)
        }
    }

    private func scheduleObserverRetryIfNeeded() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              observerAttempts[pid, default: 0] < 4,
              failedObserverCreation.contains(pid) || !(failedNotifications[pid] ?? []).isEmpty else { return }
        guard observerRetryTimer == nil else { return }
        let delay = pow(2, Double(observerAttempts[pid, default: 0]))
        observerRetryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.observerRetryTimer = nil
            self.refreshObservers()
        }
    }

    /// Geometry events update only their window; a dedicated focus check runs
    /// for focus/activation events. Neither path rediscovers every window.
    private func note(notification: String, element: AXUIElement) {
        if notification == kAXWindowMovedNotification as String
            || notification == kAXWindowResizedNotification as String {
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            if pid == NSWorkspace.shared.frontmostApplication?.processIdentifier { onGeometryNow?() }
            scheduleGeometryUpdate(for: element)
            return
        }

        // Focus and activation change which window is in front, not the window
        // inventory. Refreshing every app's AX windows here stalls the main
        // thread on each app switch and on the first activation after launch.
        if notification == kAXFocusedWindowChangedNotification as String
            || notification == kAXApplicationActivatedNotification as String {
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            guard pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
            onFocusNow?()
            scheduleFocus()
            return
        }

        // These events can add/remove an actionable window, so rebuild the
        // inventory after the debounce. Focus and geometry are handled above.
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        invalidate(pid: pid)
        scheduleChange()
    }

    /// Coalesces a burst of move/resize notifications into targeted frame reads.
    /// This keeps live dragging responsive without a global AX discovery pass.
    private func scheduleGeometryUpdate(for element: AXUIElement) {
        if !pendingGeometry.contains(where: { CFEqual($0, element) }) {
            pendingGeometry.append(element)
        }
        pendingGeometryWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let elements = self.pendingGeometry
            self.pendingGeometry.removeAll()
            self.pendingGeometryWork = nil
            for element in elements {
                guard let frame = WindowController.frame(of: element) else { continue }
                self.updateFrame(frame, for: element)
                self.onGeometryChanged?(element, frame)
            }
        }
        pendingGeometryWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
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
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        invalidate(pid: app?.processIdentifier)
        scheduleChange()
        scheduleFocus()
    }

    @objc private func appTerminated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            removeObserver(for: app.processIdentifier)
            onApplicationTerminated?(app.processIdentifier)
        }
        invalidate(pid: app?.processIdentifier)
        scheduleChange()
        scheduleFocus()
    }

    @objc private func appActivated(_ note: Notification) {
        refreshObservers()
        onFocusNow?()
        scheduleFocus()
    }

    @objc private func screensChanged() {
        invalidate()
        onScreenChange?()
        scheduleChange()
    }
}
