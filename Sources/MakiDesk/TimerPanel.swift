import AppKit
import Observation
import SwiftUI

/// Owns the timers, the countdown overlay and the 1 Hz beat they need (T61).
///
/// The beat runs only while a timer is running: a paused list, an empty list or
/// a hidden overlay schedules nothing. Every remaining time is computed from
/// the deadline, never by subtracting ticks, so a sleep, a clock change or a
/// suspended app cannot make the count drift.
@Observable
@MainActor
final class TimerController {
    static let shared = TimerController()

    private(set) var board = TimerBoard()
    /// The moment the timers were read for, so the view counts down without
    /// owning a clock of its own.
    private(set) var now = Date()

    private var ticker: Timer?
    private var monitor: Any?
    private var proximity = TimerProximity()
    private var overlay: NSPanel?
    private var layoutWork: DispatchWorkItem?
    private var revealWork: DispatchWorkItem?
    private var started = false

    private init() {}

    var timers: [AppTimer] { board.sorted(at: now) }
    /// The list the menu shows. It deliberately does not read `now`: a title
    /// that changed every second made SwiftUI rebuild the open menu, which
    /// closed it under the pointer (T61).
    var listedTimers: [AppTimer] { board.timers }
    var hasTimers: Bool { board.isEmpty == false }
    /// More timers than the overlay has room for; the menu still lists them all.
    var hiddenFromOverlay: Int { max(0, board.timers.count - 4) }

    func start() {
        guard !started else { return }
        started = true
        applySettings()
    }

    // MARK: - Starting and changing

    @discardableResult
    func startCountdown(_ seconds: TimeInterval, label: String? = nil) -> Bool {
        let moment = Date()
        now = moment
        guard board.startCountdown(seconds, label: label, now: moment) != nil else {
            return false
        }
        timersChanged()
        return true
    }

    /// Starts what the input field understood, under the label the user
    /// typed when there is one. Returns the message to show, or nil when the
    /// timer started.
    @discardableResult
    func start(_ input: TimerInput, label: String? = nil) -> String? {
        let moment = Date()
        now = moment
        let name = TimerText.cleanLabel(label)
        switch input {
        case let .countdown(seconds):
            guard board.startCountdown(seconds, label: name, now: moment) != nil else {
                return failureMessage
            }
        case let .clock(hour, minute):
            guard board.startClock(hour: hour, minute: minute, now: moment,
                                   label: name) != nil else {
                return failureMessage
            }
        }
        timersChanged()
        return nil
    }

    func pause(_ id: UUID) {
        board.pause(id, now: Date())
        timersChanged()
    }

    func resume(_ id: UUID) {
        board.resume(id, now: Date())
        timersChanged()
    }

    func remove(_ id: UUID) {
        board.remove(id)
        timersChanged()
    }

    func removeAll() {
        board.removeAll()
        timersChanged()
    }

    private var failureMessage: String {
        board.timers.count >= TimerBoard.maxTimers
            ? "The list is full: \(TimerBoard.maxTimers) timers is the limit."
            : "That length cannot be used."
    }

    private func timersChanged() {
        now = Date()
        ensureTicking()
        refreshOverlay()
    }

    // MARK: - The beat

    private func ensureTicking() {
        guard board.hasRunning else {
            stopTicking()
            return
        }
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        now = Date()
        let finished = board.expire(at: now)
        for timer in finished { announce(timer) }

        guard board.isEmpty == false else {
            stopTicking()
            hideOverlay()
            return
        }
        // The card has one row fewer: measure it again instead of leaving a
        // gap where the finished timer was.
        if finished.isEmpty == false { scheduleLayout() }
        // Everything paused: nothing to count, nothing to tick.
        ensureTicking()
        sampleProximity()
    }

    /// A timer that ran out is an alarm: it stays in the corner until the user
    /// takes it away, even when the overlay itself is hidden by the pointer,
    /// and it offers the one thing that is usually wanted next.
    private func announce(_ timer: AppTimer) {
        if WorkspaceStore.shared.timerSoundEnabled {
            TimerChime.shared.play(WorkspaceStore.shared.timerSoundName)
        }
        let label = timer.label
        HUDController.shared.show(
            "Time's up · \(label)",
            symbol: "timer",
            kind: .warning,
            sticky: true,
            actions: [HUDAction(title: "5 more minutes") { [weak self] in
                _ = self?.startCountdown(300, label: label)
            }]
        )
    }

    // MARK: - The overlay

    func applySettings() {
        guard WorkspaceStore.shared.timerOverlayVisible, board.isEmpty == false else {
            hideOverlay()
            return
        }
        refreshOverlay()
    }

    private var targetAlpha: CGFloat {
        TimerSettings.alpha(
            opacity: WorkspaceStore.shared.timerOverlayOpacity,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
    }

    private func refreshOverlay() {
        guard WorkspaceStore.shared.timerOverlayVisible, board.isEmpty == false else {
            hideOverlay()
            return
        }
        if overlay == nil { buildOverlay() }
        guard let panel = overlay else { return }
        if panel.isVisible == false {
            proximity.reset()
            panel.alphaValue = targetAlpha
            panel.orderFrontRegardless()
            startProximityMonitor()
        }
        scheduleLayout()
    }

    private func buildOverlay() {
        let hosting = NSHostingView(rootView: TimerOverlayView(controller: self))
        let panel = TimerOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 230, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above the ordinary windows and above the focus dim's veil, which
        // both live at the normal level.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .none
        // Countdowns are a viewing aid, like the notices and the checklist:
        // never part of a screenshot or a recording.
        panel.sharingType = .none
        // The overlay never takes a click: approaching it with the pointer is
        // what makes it step aside.
        panel.ignoresMouseEvents = true
        overlay = panel
    }

    private func hideOverlay() {
        stopProximityMonitor()
        proximity.reset()
        revealWork?.cancel()
        revealWork = nil
        layoutWork?.cancel()
        layoutWork = nil
        overlay?.orderOut(nil)
    }

    private func scheduleLayout() {
        guard overlay?.isVisible == true else { return }
        layoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.layoutOverlay() }
        layoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Sizes the card to its rows and puts it in the chosen corner, on the
    /// window gap and clear of the checklist when they share a corner.
    private func layoutOverlay() {
        guard let panel = overlay, let hosting = panel.contentView else { return }
        let settings = WorkspaceStore.shared
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width < 1 || size.height < 1 {
            size = CGSize(width: 230, height: 80)
        }
        size.width = max(230, size.width)
        panel.setContentSize(size)
        guard let screen = settings.timerOverlayScreen.targetScreen() else { return }
        let frame = CornerPlacement.frame(
            size: size,
            position: settings.timerOverlayPosition.palettePosition,
            screen: screen.visibleFrame,
            avoiding: ChecklistController.shared.panelFrame,
            margin: ChecklistSettings.edgeMargin(forGap: settings.gap)
        )
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        panel.alphaValue = proximity.isHidden ? 0 : targetAlpha
    }

    // MARK: - Proximity

    /// The pointer coming near takes the card away; it comes back when the
    /// pointer is well clear of it. The monitor exists only while the overlay
    /// is on screen, and the 1 Hz beat samples the pointer as well, so the
    /// rule also works where a global monitor is not allowed.
    private func startProximityMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            // Global monitors deliver on the main run loop.
            MainActor.assumeIsolated {
                self?.sampleProximity()
            }
        }
    }

    private func stopProximityMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func sampleProximity() {
        guard let panel = overlay, panel.isVisible else { return }
        let hidden = proximity.update(pointer: NSEvent.mouseLocation,
                                      overlay: panel.frame,
                                      now: Date())
        setOverlayHidden(hidden)
        if let revealAt = proximity.revealAt {
            revealWork?.cancel()
            let delay = max(0, revealAt.timeIntervalSinceNow)
            let work = DispatchWorkItem { [weak self] in self?.sampleProximity() }
            revealWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.02, execute: work)
        }
    }

    private func setOverlayHidden(_ hidden: Bool) {
        guard let panel = overlay else { return }
        let target: CGFloat = hidden ? 0 : targetAlpha
        guard abs(panel.alphaValue - target) > 0.002 else { return }
        guard WorkspaceStore.shared.effectiveAnimationsEnabled else {
            panel.alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = target
        }
    }
}

/// The sound that says a timer is over (T61).
///
/// It is a system sound from `/System/Library/Sounds`, played through `NSSound`
/// and kept alive here: a sound released the moment it starts stops before it
/// is heard. The Mac's own volume and mute apply, as with every other alert.
@MainActor
final class TimerChime {
    static let shared = TimerChime()

    private var cache: [String: NSSound] = [:]

    private init() {}

    func play(_ name: String) {
        let resolved = TimerSettings.resolvedSound(name)
        let sound: NSSound
        if let cached = cache[resolved] {
            sound = cached
        } else {
            guard let loaded = NSSound(named: resolved) else { return }
            cache[resolved] = loaded
            sound = loaded
        }
        // `play()` is ignored while the same sound is still ringing.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}

/// A card that may sit anywhere on any display and never takes a click.
private final class TimerOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// The countdown card: one line per timer, the nearest first.
private struct TimerOverlayView: View {
    let controller: TimerController

    private var theme: PaletteTheme { WorkspaceStore.shared.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(controller.timers.prefix(4))) { timer in
                HStack(spacing: 8) {
                    Image(systemName: timer.isPaused ? "pause.fill" : "timer")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .frame(width: 12)
                    Text(timer.label)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.subtext)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(TimerText.countdown(timer.remaining(at: controller.now)))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.text)
                        .monospacedDigit()
                }
            }
            if controller.hiddenFromOverlay > 0 {
                Text("+\(controller.hiddenFromOverlay) more in the menu")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.subtext)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: 230, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(theme.border.opacity(0.6), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Timers")
        .accessibilityValue(controller.timers.map {
            "\($0.label) \(TimerText.duration($0.remaining(at: controller.now)))"
        }.joined(separator: ", "))
    }
}

// MARK: - The input field

/// What the input card is showing.
@Observable
@MainActor
final class TimerInputModel {
    var text = ""
    /// What the card and the overlay call this timer; empty takes the default
    /// ("25m", "8:30").
    var label = ""
    var error: String?

    static let hint = "25m · 1h 30m · 40s · 8:30 — a time of day is written with a colon."
    static let unreadable = "That is neither a length nor a time. Try 25m, 1h 30m or 8:30; 1:30 is half past one at night, not ninety minutes."
}

/// The little card behind **New Timer…**: a field, a hint and nothing else.
@MainActor
final class TimerInputController {
    static let shared = TimerInputController()

    let model = TimerInputModel()
    private var window: TimerInputPanel?
    private let focusReturn = PanelFocusReturn()

    private init() {}

    var isVisible: Bool { window?.isVisible == true }

    /// Opens the card. `prefill` is a length or a time already written for the
    /// user — the quick starts use it — so the only thing left is a label.
    func show(prefill: String? = nil) {
        if window == nil { build() }
        guard let window else { return }
        model.text = prefill ?? ""
        model.label = ""
        model.error = nil
        focusReturn.capture()
        place(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard let window, window.isVisible else { return }
        let restore = focusReturn.takeRestoreAction(ownsKeyboard: window.isKeyWindow)
        window.orderOut(nil)
        restore?()
    }

    func submit() {
        guard let input = TimerText.parse(model.text) else {
            model.error = TimerInputModel.unreadable
            return
        }
        if let message = TimerController.shared.start(input, label: model.label) {
            model.error = message
            return
        }
        hide()
    }

    private func build() {
        let hosting = NSHostingView(rootView: TimerInputView(model: model))
        let panel = TimerInputPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 152),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.sharingType = .none
        panel.onCancel = { [weak self] in self?.hide() }
        window = panel
    }

    private func place(_ window: NSWindow) {
        guard let screen = PaletteScreenLocation.focusedWindow.targetScreen() else { return }
        window.setFrame(
            UtilityWindowPlacement.centeredFrame(size: window.frame.size,
                                                 in: screen.visibleFrame),
            display: false
        )
    }
}

private final class TimerInputPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

private struct TimerInputView: View {
    @Bindable var model: TimerInputModel
    @FocusState private var typing: Bool
    @FocusState private var labeling: Bool

    private var theme: PaletteTheme { WorkspaceStore.shared.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "timer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text("New timer")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.text)
                Spacer(minLength: 6)
                Text("Ret starts · Esc closes")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.subtext)
            }
            TextField("25m, 1h 30m, 8:30…", text: $model.text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(theme.text)
                .focused($typing)
                .onSubmit { TimerInputController.shared.submit() }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(theme.background.opacity(0.55))
                )
                .accessibilityLabel("Timer length or time of day")
            TextField("Label (optional) — Tea, Focus, Stand up…", text: $model.label)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.text)
                .focused($labeling)
                .onSubmit { TimerInputController.shared.submit() }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(theme.background.opacity(0.55))
                )
                .accessibilityLabel("Timer label, optional")
            Text(model.error ?? TimerInputModel.hint)
                .font(.system(size: 10.5))
                .foregroundStyle(model.error == nil ? theme.subtext : Color.red)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 420, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(theme.border.opacity(0.6), lineWidth: 1)
                )
        )
        .onExitCommand { TimerInputController.shared.hide() }
        .onAppear {
            DispatchQueue.main.async {
                // A prefilled length is already right: the cursor goes to the
                // label, which is the only thing left to add.
                if model.text.isEmpty { typing = true } else { labeling = true }
            }
        }
    }
}
