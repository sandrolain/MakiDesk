import AppKit
import Observation

/// Owns the pointer effects (E1–E7): the one-shot pulse, the selected
/// presentation style and the ripple of a click.
///
/// No Accessibility and no Input Monitoring: the pointer is read through
/// `NSEvent.mouseLocation` and a global mouse monitor, the same way the utility
/// bar and the drag snapping already do. Nothing is captured, and no pointer
/// position is ever logged: the panels never take a click.
@Observable
@MainActor
final class PointerEffectController {
    static let shared = PointerEffectController()

    /// Whether the ring is following the pointer, for the menu and the HUD.
    private(set) var isPresentationActive = false
    /// When the presentation stops by itself.
    private(set) var presentationEndsAt: Date?
    private(set) var settings = PointerEffectSettings.standard

    @ObservationIgnored private var surfaces: [CGDirectDisplayID: PointerEffectSurface] = [:]
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var follow = PointerFollow(.zero)
    @ObservationIgnored private var trail = PointerTrail()
    @ObservationIgnored private var lastPointer: CGPoint?
    @ObservationIgnored private var lastMoveAt = Date.distantPast
    @ObservationIgnored private var effectDisplayID: CGDirectDisplayID?
    @ObservationIgnored private var pulseGenerations: [CGDirectDisplayID: Int] = [:]
    @ObservationIgnored private var pulseHideWork: [CGDirectDisplayID: DispatchWorkItem] = [:]
    @ObservationIgnored private var expiryWork: DispatchWorkItem?

    private init() {}

    /// How often the follower reads the pointer while it is moving. The ring is
    /// settled in a fraction of a second; the timer stops as soon as it is.
    private static let tickInterval: TimeInterval = 1.0 / 60.0
    /// After this long without movement and with the button up, there is
    /// nothing left to follow.
    private static let idleStop: TimeInterval = 1.0
    private static let followFactor: Double = 0.42

    /// The windows the still-capture paths must leave out. They show no cursor
    /// (`showsCursor = false`), so a ring without a pointer would be a ghost;
    /// recordings keep the cursor and the effect.
    var excludedWindowNumbers: [CGWindowID] {
        surfaces.values.compactMap { surface in
            surface.isVisible ? CGWindowID(surface.windowNumber) : nil
        }
    }

    // MARK: - Settings

    func applySettings() {
        let oldStyle = settings.style
        settings = PointerEffectSettings.load()
        if oldStyle != settings.style {
            trail.removeAll()
        }
        for surface in surfaces.values {
            surface.setSharingType(sharingType)
        }
        if isPresentationActive {
            updateEffect(at: NSEvent.mouseLocation)
        }
    }

    // MARK: - Pulse

    /// Shows the pulse around the pointer, on the display it is on. Works when
    /// the app is not active and installs nothing that outlives the effect.
    func pulse() {
        settings = PointerEffectSettings.load()
        let pointer = NSEvent.mouseLocation
        guard let screen = screen(containing: pointer),
              let surface = surface(for: screen) else { return }

        let local = surface.localPoint(pointer)
        let radius = PointerEffectGeometry.clampedRadius(
            settings.size, at: local,
            in: CGRect(origin: .zero, size: surface.displayFrame.size)
        )

        pulseGenerations[surface.displayID, default: 0] += 1
        let generation = pulseGenerations[surface.displayID] ?? 1
        pulseHideWork[surface.displayID]?.cancel()

        surface.showPulse(at: local, radius: radius,
                          intensity: settings.intensity,
                          duration: settings.pulseDuration,
                          reduceMotion: reduceMotion,
                          colour: accent)

        let lifetime = PointerPulse(
            startedAt: Date().timeIntervalSinceReferenceDate,
            duration: settings.pulseDuration
        ).visibleUntil - Date().timeIntervalSinceReferenceDate + 0.35
        let displayID = surface.displayID
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.pulseGenerations[displayID] == generation else { return }
                surface.hidePulse()
                self.pulseHideWork[displayID] = nil
            }
        }
        pulseHideWork[displayID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime, execute: work)
        MakiLog.app.notice("pointer pulse rings=\(PointerPulse.ringCount, privacy: .public)")
    }

    // MARK: - Presentation

    func togglePresentation() {
        if isPresentationActive {
            stopPresentation()
        } else {
            startPresentation()
        }
    }

    func startPresentation() {
        guard isPresentationActive == false else { return }
        settings = PointerEffectSettings.load()

        let now = Date()
        isPresentationActive = true
        presentationEndsAt = now.addingTimeInterval(
            TimeInterval(settings.presentationMinutes * 60)
        )
        let pointer = NSEvent.mouseLocation
        follow = PointerFollow(pointer)
        lastPointer = pointer
        lastMoveAt = now
        trail.removeAll()

        installMonitors()
        installObservers()
        updateEffect(at: pointer)
        startTicker()
        scheduleExpiry()

        HUDController.shared.show(
            HUDMessage.pointerEffects(active: true, minutes: settings.presentationMinutes)
        )
        MakiLog.app.notice("pointer effects on minutes=\(self.settings.presentationMinutes, privacy: .public)")
    }

    enum StopReason: String, Sendable {
        case manual
        case expired
        case system
    }

    /// Turns the presentation off and releases everything it installed. A pulse
    /// already on screen is left to finish: it has its own lifetime.
    func stopPresentation(announce: Bool = true, reason: StopReason = .manual) {
        guard isPresentationActive else { return }
        isPresentationActive = false
        presentationEndsAt = nil
        expiryWork?.cancel()
        expiryWork = nil
        removeMonitors()
        removeObservers()
        stopTicker()
        if reason == .system {
            // A sleep or a lock is not a pause: do not leave an ordered-out
            // high-level window behind for the wake to inherit.
            closeAllSurfaces()
        } else {
            hideAllEffects()
        }

        guard announce else { return }
        HUDController.shared.show(
            reason == .expired ? HUDMessage.pointerEffectsEnded
                               : HUDMessage.pointerEffects(active: false)
        )
        MakiLog.app.notice("pointer effects off reason=\(reason.rawValue, privacy: .public)")
    }

    private func presentationExpired() {
        stopPresentation(announce: true, reason: .expired)
    }

    private func scheduleExpiry() {
        guard let endsAt = presentationEndsAt else { return }
        let delay = max(0, endsAt.timeIntervalSinceNow)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.presentationExpired() }
        }
        expiryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Input

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown,
                                           .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
    }

    private func handle(_ event: NSEvent) {
        guard isPresentationActive else { return }
        let pointer = NSEvent.mouseLocation
        lastMoveAt = Date()

        switch event.type {
        case .mouseMoved:
            startTicker()
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            startTicker()
            if settings.clickRipple {
                showRipple(at: pointer)
            }
        default:
            break
        }
    }

    private func showRipple(at pointer: CGPoint) {
        guard let screen = screen(containing: pointer),
              let surface = surface(for: screen) else { return }
        let local = surface.localPoint(pointer)
        let radius = PointerEffectGeometry.clampedRadius(
            settings.size, at: local,
            in: CGRect(origin: .zero, size: surface.displayFrame.size)
        )
        surface.showRipple(at: local, radius: radius,
                           intensity: settings.intensity,
                           reduceMotion: reduceMotion,
                           colour: accent)
    }

    // MARK: - Following

    private func startTicker() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // `.common` keeps the ring following during a drag or a menu tracking
        // loop, where the default mode would stand still.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard isPresentationActive else {
            stopTicker()
            return
        }
        let now = Date()
        let pointer = NSEvent.mouseLocation
        var isMoving = false
        if let last = lastPointer,
           hypot(pointer.x - last.x, pointer.y - last.y) > 0.5 {
            lastMoveAt = now
            isMoving = true
        }
        lastPointer = pointer

        let buttonDown = NSEvent.pressedMouseButtons != 0
        let idleFor = now.timeIntervalSince(lastMoveAt)
        if buttonDown == false, idleFor > Self.idleStop,
           follow.distance(to: pointer) < 0.6 {
            if settings.style == .ribbon {
                trail.prune(before: now.timeIntervalSinceReferenceDate - 0.45)
                updateEffect(at: pointer, isMoving: false)
            } else if settings.style == .particles {
                updateEffect(at: pointer, isMoving: false)
            }
            stopTicker()
            return
        }

        _ = follow.move(towards: pointer, factor: Self.followFactor)
        let point = settings.style == .ring ? follow.position : pointer
        updateEffect(at: point, isMoving: isMoving || buttonDown)
    }

    private func updateEffect(at point: CGPoint? = nil, isMoving: Bool = false) {
        guard isPresentationActive else { return }
        let point = point ?? follow.position
        guard let screen = screen(containing: point),
              let id = PaletteScreenLocation.displayID(screen),
              let surface = surface(for: screen) else { return }

        if effectDisplayID != id {
            if let old = effectDisplayID, let oldSurface = surfaces[old] {
                oldSurface.hideEffect()
            }
            effectDisplayID = id
            trail.removeAll()
        }

        let local = surface.localPoint(point)
        let now = Date().timeIntervalSinceReferenceDate
        if settings.style == .ribbon, reduceMotion == false {
            if isMoving {
                trail.append(local, at: now)
            }
            trail.prune(before: now - 0.45)
        }
        let radius = settings.style == .spotlight
            ? settings.size
            : PointerEffectGeometry.clampedRadius(
                settings.size, at: local,
                in: CGRect(origin: .zero, size: surface.displayFrame.size)
            )
        surface.update(style: settings.style, at: local, radius: radius,
                       intensity: settings.intensity, colour: accent,
                       trail: trail, isMoving: isMoving, reduceMotion: reduceMotion)
    }

    private func hideAllEffects() {
        for surface in surfaces.values {
            surface.hideEffect()
        }
        effectDisplayID = nil
        trail.removeAll()
    }

    // MARK: - Surfaces

    private var sharingType: NSWindow.SharingType {
        settings.includesInCaptures ? .readOnly : .none
    }

    private func surface(for screen: NSScreen) -> PointerEffectSurface? {
        guard let id = PaletteScreenLocation.displayID(screen) else { return nil }
        if let existing = surfaces[id] {
            if PointerEffectGeometry.frameMatches(existing.displayFrame, screen.frame) {
                existing.setSharingType(sharingType)
                return existing
            }
            existing.close()
            surfaces[id] = nil
        }
        let created = PointerEffectSurface(screen: screen, sharingType: sharingType)
        surfaces[id] = created
        return created
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        let screens = NSScreen.screens
        guard let index = PointerEffectGeometry.screenIndex(for: point,
                                                            screens: screens.map(\.frame)) else {
            return nil
        }
        return screens[index]
    }

    private func closeAllSurfaces() {
        pulseHideWork.values.forEach { $0.cancel() }
        pulseHideWork.removeAll()
        for surface in surfaces.values {
            surface.close()
        }
        surfaces.removeAll()
        effectDisplayID = nil
        trail.removeAll()
    }

    // MARK: - System observers

    private func installObservers() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let stopping: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ]
        for name in stopping {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.stopPresentation(announce: false, reason: .system)
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildSurfaces() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .makiDeskThemeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        })
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    /// A display went away or changed resolution: the old panels no longer
    /// describe the desktop, so they are rebuilt instead of moved.
    private func rebuildSurfaces() {
        closeAllSurfaces()
        guard isPresentationActive else { return }
        let pointer = NSEvent.mouseLocation
        follow = PointerFollow(pointer)
        lastPointer = pointer
        updateEffect(at: pointer)
    }

    private var accent: NSColor {
        NSColor(WorkspaceStore.shared.theme.accent)
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
