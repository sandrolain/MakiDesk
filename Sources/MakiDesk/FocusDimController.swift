import AppKit
import ApplicationServices

/// Dims everything outside the focused window (T62).
///
/// The veil is one click-through panel per display, at the ordinary window
/// level, ordered **below** the window that must stay sharp. Anything stacked
/// lower is dimmed; the anchor and everything above it stay clear. Because the
/// relationship is the stacking order rather than a set of rectangles, a window
/// that moves or resizes needs no update, and no Screen Recording permission is
/// involved.
///
/// Menu bar, Dock and MakiDesk's own panels live at higher levels, so they stay
/// bright — the documented behaviour, shared with the reference implementation.
@MainActor
final class FocusDimController {
    static let shared = FocusDimController()

    private struct Display {
        let id: CGDirectDisplayID
        /// Cocoa coordinates, for the panel.
        let frame: CGRect
        /// The same display in window-server (top-left) coordinates.
        let axFrame: CGRect
    }

    private struct Surface {
        let panel: DimPanel
        let placement: FocusDim.Placement
        /// The display in window-server coordinates, for the drift check.
        let axFrame: CGRect
    }

    private var surfaces: [CGDirectDisplayID: Surface] = [:]
    private var observers: [NSObjectProtocol] = []
    private var refreshWork: DispatchWorkItem?
    private var driftTimer: Timer?
    private var driftWork: DispatchWorkItem?
    /// The picked windows of the selection mode, in pick order.
    private var picked: [ActionableWindow] = []
    /// The set the apps of `picked` have already been brought forward for.
    private var activatedIDs: [CGWindowID] = []
    /// A pick changed the set while the switcher was open: the apps are brought
    /// forward as soon as the switcher is out, because activating one of them
    /// takes the keyboard away from it.
    private var activationPending = false
    /// Invalidates a running activation chain when a new one starts.
    private var activationGeneration = 0
    /// The window the user activated from the switcher: it is brought forward
    /// last, so the set lands under it and the keyboard ends where they chose.
    private var activationTail: ActionableWindow?
    /// The set already brought forward, so a later choice does not move it again.
    private var activationCompletedIDs: [CGWindowID] = []
    /// How many times the window server refused to put a veil back under its
    /// anchor; after a few the veil comes down instead of covering it.
    private var reorderFailures: [CGDirectDisplayID: Int] = [:]
    private var lastFocus: WindowController.Frontmost?
    /// The last app that had focus while MakiDesk did not: turning the effect on
    /// from our own Settings window still lights the window the user goes back to.
    private var lastExternalPID: pid_t?
    /// Invalidates a pending fade-out when the veil comes back before it ends.
    private var fadeGeneration = 0
    private var isShowing = false
    private var started = false

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           pid != ProcessInfo.processInfo.processIdentifier {
            lastExternalPID = pid
        }
        observeSystem()
        applySettings()
    }

    /// Applies the current settings, then redraws the veil.
    func applySettings() {
        guard WorkspaceStore.shared.focusDimEnabled else {
            hide(animated: true)
            return
        }
        // Changing opacity, colour or mode while the veil is up must not cost a
        // cross-process read: the last focus is still the one on screen.
        if isShowing || lastFocus != nil {
            replan()
        } else {
            refresh()
        }
    }

    /// Reads the focused window and updates the veil. `frontmost` is the value
    /// already read by the store's focus pipeline, when it has one.
    func refresh(frontmost: WindowController.Frontmost? = nil) {
        let store = WorkspaceStore.shared
        guard store.focusDimEnabled else {
            hide(animated: true)
            return
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.processIdentifier != ownPID {
            lastExternalPID = frontApp.processIdentifier
            let trusted = AXIsProcessTrusted()
            lastFocus = trusted
                ? (frontmost ?? store.recentFocusSnapshot() ?? WindowController.frontmost())
                : nil
        }
        replan()
    }

    /// Re-plans from the last known focus: no Accessibility read, for settings,
    /// inventory and stacking changes.
    func refreshPlacement() {
        guard isShowing else { return }
        replan()
    }

    /// Places the veil for the last focus read.
    private func replan() {
        let store = WorkspaceStore.shared
        guard store.focusDimEnabled else {
            hide(animated: true)
            return
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // A fixed set of windows does not depend on the focus at all, so it is
        // planned from the live frames even while one of our own panels has the
        // keyboard or the desktop is in front (T62).
        if store.focusDimSource == .selection {
            let displays = Self.displays()
            guard !displays.isEmpty,
                  presentSelection(store: store, displays: displays,
                                   stack: WindowController.onScreenStack(),
                                   ownPID: ownPID) else {
                hide(animated: true)
                return
            }
            return
        }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            hide(animated: true)
            return
        }
        // One of our own panels has focus: keeping the last anchor means
        // opening Notes or the switcher does not switch the effect off.
        let pid: pid_t
        if frontApp.processIdentifier == ownPID {
            guard let external = lastExternalPID else {
                hide(animated: true)
                return
            }
            pid = external
        } else {
            pid = frontApp.processIdentifier
        }
        if case .desktop = lastFocus {
            if store.focusDimDesktopDims {
                presentAllDimmed()
            } else {
                hide(animated: true)
            }
            return
        }
        // The app whose windows stay sharp is the one that has focus now; the
        // last read only names which of its windows it is.
        present(focus: lastFocus, pid: pid, ownPID: ownPID)
    }

    // MARK: - Planning

    private func present(focus: WindowController.Frontmost?, pid: pid_t, ownPID: pid_t) {
        let store = WorkspaceStore.shared
        let displays = Self.displays()
        guard !displays.isEmpty else {
            hide(animated: false)
            return
        }
        let stack = WindowController.onScreenStack()
        let focusedID: CGWindowID? = if case let .window(info) = focus { info.windowID } else { nil }
        // The anchor must be in the window server's on-screen stack: a stale
        // Accessibility read may name a window that has since closed, and
        // ordering under a number that is gone leaves the veil over everything.
        // The read itself is validated against the app in front by the store,
        // so a window it accepted is the one the user just activated.
        let onScreen = focusedID.flatMap { id in
            stack.first { $0.number == id }?.number
        }
        // Without Accessibility the frontmost app's topmost window is the best
        // anchor there is; the veil then still works, just less precisely.
        guard let anchor = onScreen ?? FocusDim.topmostWindow(of: pid, in: stack) else {
            hide(animated: true)
            return
        }
        let plan = FocusDim.plan(
            screens: displays.map { FocusDim.Screen(id: $0.id, frame: $0.axFrame) },
            stack: stack,
            focused: anchor,
            focusedPID: pid,
            source: store.focusDimSource,
            mode: store.focusDimDisplayMode,
            ownPID: ownPID
        )
        apply(plan, displays: displays)
    }

    /// Places the veil for the windows the user picked in the switcher. The
    /// stable identity of each window is resolved against the current snapshot,
    /// so a minimised window is skipped and a closed one cannot anchor the veil
    /// to something that is gone. False when nothing is left: the caller takes
    /// the veil down.
    private func presentSelection(store: WorkspaceStore, displays: [Display],
                                  stack: [WindowController.CGWindowEntry],
                                  ownPID: pid_t) -> Bool {
        guard !store.veilSelection.isEmpty else { return false }
        let current = store.actionableWindows()
        let selected = store.veilSelection.compactMap { requested in
            current.first { $0.id == requested.id }
        }
        .filter { $0.state == .normal && !$0.minimized }
        let ids = selected.compactMap(\.windowID)
        guard !ids.isEmpty else { return false }
        picked = selected
        // A new pick is a request to see that window: its app is brought
        // forward, once, so the set sits at the top of the stack and the veil
        // can anchor under its lowest window.
        if ids != activatedIDs {
            activatedIDs = ids
            activationPending = true
        }
        bringPickedToFront()
        let plan = FocusDim.plan(
            screens: displays.map { FocusDim.Screen(id: $0.id, frame: $0.axFrame) },
            stack: stack,
            focused: nil,
            focusedPID: nil,
            source: .selection,
            mode: store.focusDimDisplayMode,
            ownPID: ownPID,
            selection: ids
        )
        apply(plan, displays: displays)
        return true
    }

    /// Puts the picked windows on top, once per pick.
    ///
    /// macOS keeps the active app's windows above every other app's, so a
    /// window of a background app cannot be lifted without activating it
    /// (Accessibility's raise answers success but leaves the order alone). The
    /// switcher and the groups use the same three steps, here in reverse pick
    /// order: the first pick is activated last and ends in front, with the
    /// whole set contiguous at the top.
    ///
    /// One activation at a time, each waited for: two requests in the same turn
    /// and the second stays queued for seconds, leaving part of the set behind.
    /// Postponed while the switcher is open — activating an app would take the
    /// keyboard away from it — and while the pointer is down.
    private func bringPickedToFront(finishingWith last: ActionableWindow? = nil) {
        let store = WorkspaceStore.shared
        guard store.focusDimEnabled, store.focusDimSource == .selection,
              NSEvent.pressedMouseButtons == 0,
              !WindowPalette.shared.isVisible else { return }
        guard activationPending || last != nil else { return }
        activationPending = false
        activationGeneration += 1
        activationTail = last
        var windows = Array(picked.reversed())
        if let last { windows.append(last) }
        guard !windows.isEmpty else { return }
        makiLog.debug("focus dim brought forward windows=\(windows.count)")
        stepActivation(windows, index: 0, generation: activationGeneration)
    }

    private func stepActivation(_ windows: [ActionableWindow], index: Int, generation: Int) {
        let store = WorkspaceStore.shared
        guard generation == activationGeneration, store.focusDimEnabled,
              store.focusDimSource == .selection else { return }
        guard index < windows.count else {
            // The set is forward: without a chosen window the first pick ends on
            // top, then the veil is planned again from the settled order.
            if activationTail == nil, let first = picked.first {
                WindowController.raise(first.element)
                WindowController.focus(first.element)
            }
            activationCompletedIDs = picked.compactMap(\.windowID)
            activationTail = nil
            scheduleRefresh(after: 0.2)
            return
        }
        // The set can change while the chain runs: act on the live value. The
        // chosen window may not be one of the picks, so it is taken as it is.
        let target = windows[index]
        let window: ActionableWindow
        if let live = picked.first(where: { $0.id == target.id }) {
            window = live
        } else if target.id == activationTail?.id {
            window = target
        } else {
            stepActivation(windows, index: index + 1, generation: generation)
            return
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid {
            // The app is already forward (two picks of one app, or the window
            // that had the keys): only its window has to come up.
            WindowController.raise(window.element)
            WindowController.focus(window.element)
            stepActivation(windows, index: index + 1, generation: generation)
            return
        }
        NSRunningApplication(processIdentifier: window.pid)?.activate()
        // A switch takes a moment, and one sent while another is still in
        // progress waits for it: each activation is waited for before the next.
        awaitActivation(window, windows: windows, index: index, generation: generation,
                        deadline: Date().addingTimeInterval(3))
    }

    private func awaitActivation(_ window: ActionableWindow, windows: [ActionableWindow],
                                 index: Int, generation: Int, deadline: Date) {
        guard generation == activationGeneration else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard front == window.pid || Date() >= deadline else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.awaitActivation(window, windows: windows, index: index,
                                      generation: generation, deadline: deadline)
            }
            return
        }
        // The app is forward: put its chosen window in front, then the next.
        WindowController.raise(window.element)
        WindowController.focus(window.element)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.stepActivation(windows, index: index + 1, generation: generation)
        }
    }

    /// The switcher has closed; `chosen` is the window the user activated from
    /// it, if any. The set still has to be the block that stays clear, so it is
    /// brought forward first and the chosen window last: the keyboard ends where
    /// the user asked, with the set sharp right under it. Nothing moves when the
    /// set is already forward — the chosen window simply goes above it.
    func paletteDidHide(choosing chosen: ActionableWindow?) {
        if chosen != nil, activationCompletedIDs == picked.compactMap(\.windowID) { return }
        bringPickedToFront(finishingWith: chosen)
    }

    private func presentAllDimmed() {
        let displays = Self.displays()
        guard !displays.isEmpty else {
            hide(animated: false)
            return
        }
        apply(displays.map { FocusDim.Placement(display: $0.id, anchor: nil) }, displays: displays)
    }

    private func apply(_ plan: [FocusDim.Placement], displays: [Display]) {
        let store = WorkspaceStore.shared
        let alpha = FocusDim.alpha(
            opacity: store.focusDimOpacity,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
        let colour = store.focusDimColour
        fadeGeneration += 1
        isShowing = true
        reorderFailures.removeAll()

        var connected: Set<CGDirectDisplayID> = []
        for display in displays {
            connected.insert(display.id)
            guard let placement = plan.first(where: { $0.display == display.id }) else { continue }
            let panel = surfaces[display.id]?.panel ?? makePanel()
            if panel.frame != display.frame {
                panel.setFrame(display.frame, display: false)
            }
            let components = colour.components
            panel.contentView?.layer?.backgroundColor = CGColor(
                srgbRed: components.red, green: components.green,
                blue: components.blue, alpha: 1
            )
            surfaces[display.id] = Surface(panel: panel, placement: placement,
                                           axFrame: display.axFrame)
            show(panel, anchor: placement.anchor, alpha: alpha)
        }
        for id in Array(surfaces.keys) where !connected.contains(id) {
            surfaces.removeValue(forKey: id)?.panel.orderOut(nil)
        }
        startDrift()
        // One early check, so a placement the window server refuses is caught
        // in a fraction of a second instead of a whole second.
        scheduleDriftCheck(after: 0.25)
    }

    // MARK: - Panels

    private func show(_ panel: DimPanel, anchor: CGWindowID?, alpha: CGFloat) {
        let wasVisible = panel.isVisible && panel.alphaValue > 0.01
        if !wasVisible {
            panel.alphaValue = 0
            // Ordering relative to another window only works for a window that
            // is already on screen, so the panel is shown first and moved under
            // the anchor in the same run-loop turn, before anything is drawn.
            panel.orderFrontRegardless()
        }
        if let anchor {
            panel.order(.below, relativeTo: Int(anchor))
        } else if wasVisible {
            // A fully dimmed display must stay above the windows it covers,
            // which a newly activated app would otherwise raise over it.
            panel.orderFrontRegardless()
        }
        if !wasVisible || abs(panel.alphaValue - alpha) > 0.001 {
            fade(panel, to: alpha)
        }
    }

    private func fade(_ panel: DimPanel, to alpha: CGFloat) {
        let store = WorkspaceStore.shared
        let duration = store.effectiveAnimationsEnabled ? store.focusDimFade : 0
        guard duration > 0 else {
            panel.alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = alpha
        }
    }

    private func hide(animated: Bool) {
        stopDrift()
        picked = []
        activatedIDs = []
        activationCompletedIDs = []
        activationPending = false
        activationTail = nil
        activationGeneration += 1
        isShowing = false
        fadeGeneration += 1
        let generation = fadeGeneration
        let veils = surfaces.values.map(\.panel)
        surfaces.removeAll()
        guard !veils.isEmpty else { return }

        let store = WorkspaceStore.shared
        let duration = animated && store.effectiveAnimationsEnabled ? store.focusDimFade : 0
        guard duration > 0 else {
            for panel in veils { panel.orderOut(nil) }
            return
        }
        for panel in veils {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.allowsImplicitAnimation = true
                panel.animator().alphaValue = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) { [weak self] in
            guard let self, self.fadeGeneration == generation else { return }
            for panel in veils { panel.orderOut(nil) }
        }
    }

    private func makePanel() -> DimPanel {
        let panel = DimPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .normal
        // `.moveToActiveSpace` follows the desktop; `.transient` keeps the veil
        // out of Mission Control. It deliberately does **not** join full-screen
        // spaces: the full-screen window covers the veil anyway.
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isMovable = false
        // Not in screenshots, recordings or screen sharing: the veil is a
        // viewing aid, never part of what is captured.
        panel.sharingType = .none

        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        view.layer?.backgroundColor = NSColor.black.cgColor
        // The veil is decoration: nothing to read out, nothing to click.
        view.setAccessibilityElement(false)
        panel.contentView = view
        panel.setAccessibilityElement(false)
        return panel
    }

    // MARK: - Drift

    /// The stacking order can change under the veil without any notification
    /// MakiDesk subscribes to (another app raising one of its windows). One
    /// cheap check a second, only while the veil is up, puts the panel back
    /// under its anchor when it has slipped above it.
    private func startDrift() {
        guard driftTimer == nil, isShowing else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkDrift() }
        }
        RunLoop.main.add(timer, forMode: .common)
        driftTimer = timer
    }

    private func stopDrift() {
        driftTimer?.invalidate()
        driftTimer = nil
        driftWork?.cancel()
        driftWork = nil
    }

    private func scheduleDriftCheck(after delay: TimeInterval) {
        driftWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkDrift() }
        driftWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func checkDrift() {
        let store = WorkspaceStore.shared
        guard store.focusDimEnabled, isShowing else {
            stopDrift()
            return
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let stack = WindowController.onScreenStack()
        // A pick whose app could not be brought forward yet (the pointer was
        // down, or the switcher had not closed) is completed here.
        if store.focusDimSource == .selection { bringPickedToFront() }
        var anchorGone = false
        for (display, surface) in surfaces {
            let panel = surface.panel
            guard let panelIndex = stack.firstIndex(where: {
                $0.number == CGWindowID(panel.windowNumber)
            }) else {
                if let anchor = surface.placement.anchor {
                    // The window server did not list the veil: re-anchor once
                    // rather than guess where it stands.
                    panel.order(.below, relativeTo: Int(anchor))
                } else {
                    panel.orderFrontRegardless()
                }
                continue
            }
            guard let anchor = surface.placement.anchor else {
                // A fully dimmed display must stay above every ordinary window
                // on it; a newly activated app would otherwise cover it.
                if let top = FocusDim.topmostIndex(on: surface.axFrame, stack: stack,
                                                   ownPID: ownPID), panelIndex > top {
                    panel.orderFrontRegardless()
                }
                continue
            }
            guard let anchorIndex = stack.firstIndex(where: { $0.number == anchor }) else {
                anchorGone = true
                continue
            }
            guard FocusDim.needsReorder(panel: panelIndex, anchor: anchorIndex) else {
                reorderFailures[display] = nil
                continue
            }
            let attempts = (reorderFailures[display] ?? 0) + 1
            reorderFailures[display] = attempts
            guard attempts < 3 else {
                // The window server keeps refusing the placement. Taking the
                // veil down beats covering the window that must stay sharp.
                panel.orderOut(nil)
                surfaces.removeValue(forKey: display)
                reorderFailures[display] = nil
                continue
            }
            panel.order(.below, relativeTo: Int(anchor))
        }
        if anchorGone { scheduleRefresh(after: 0.05) }
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
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        ]
        for name in names {
            observers.append(workspace.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handle(name) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScreenChange() }
        })
        for name in [NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                // Our own activation keeps the last anchor; the other app's
                // activation may arrive before or after this one.
                Task { @MainActor [weak self] in self?.scheduleRefresh(after: 0.05) }
            })
        }
    }

    private func handle(_ name: Notification.Name) {
        switch name {
        case NSWorkspace.willSleepNotification,
             NSWorkspace.screensDidSleepNotification,
             NSWorkspace.sessionDidResignActiveNotification:
            hide(animated: false)
        case NSWorkspace.activeSpaceDidChangeNotification:
            // No veil from the desktop the user just left.
            hide(animated: false)
            scheduleRefresh(after: 0.2)
        case NSWorkspace.didWakeNotification,
             NSWorkspace.screensDidWakeNotification,
             NSWorkspace.sessionDidBecomeActiveNotification:
            scheduleRefresh(after: 0.15)
        case NSWorkspace.didActivateApplicationNotification:
            handleActivation()
        default:
            refresh()
        }
    }

    private func handleActivation() {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let previous = lastExternalPID
        if let pid, pid != ownPID { lastExternalPID = pid }
        let store = WorkspaceStore.shared
        guard store.focusDimEnabled else { return }
        if store.focusDimStopsOnAppChange, let pid, let previous,
           pid != previous, pid != ownPID {
            store.updateFocusDimEnabled(false)
            return
        }
        refresh()
        // Some apps publish their focused window a beat after activating.
        scheduleRefresh(after: 0.15)
    }

    private func handleScreenChange() {
        hide(animated: false)
        scheduleRefresh(after: 0.2)
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Displays

    private static func displays() -> [Display] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return nil }
            return Display(
                id: CGDirectDisplayID(number.uint32Value),
                frame: screen.frame,
                axFrame: WindowController.flip(screen.frame)
            )
        }
    }
}

/// A veil panel may cover a whole display, including the menu-bar strip; a
/// plain `NSPanel` clamps its frame and would leave an undimmed edge.
private final class DimPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
