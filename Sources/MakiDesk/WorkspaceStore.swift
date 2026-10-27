import Foundation
import AppKit
import ApplicationServices
import SwiftUI
import Observation
import os

let makiLog = Logger(subsystem: "com.makidesk.app", category: "app")

/// A window the switcher / search can act on.
struct ActionableWindow: Identifiable {
    let id: String
    let title: String
    let appName: String
    let frame: CGRect
    let pid: pid_t
    var minimized: Bool
    let element: AXUIElement
    let color: NSColor
    let windowID: CGWindowID?
    /// The owning application's icon (cached per pid); shown on the card.
    let icon: NSImage?
    /// Whether the window is on screen or minimised.
    var state: WindowState
}

/// Where a window currently sits, for the palette's state indicator (T5).
enum WindowState: Equatable {
    case normal
    case minimized
    case unavailable
}

@Observable
@MainActor
final class WorkspaceStore {
    var windows: [WorkspaceWindow] = []
    var selectedID: UUID?
    var status = "Starting…"
    var accessibilityTrusted = AXIsProcessTrusted()
    private var recentFocusedWindowIDs: [String] = []
    var mostRecentFocusedWindowID: String? { recentFocusedWindowIDs.first }
    @ObservationIgnored private var focusedWindowSnapshot: WindowController.Frontmost?
    @ObservationIgnored private var focusedWindowSnapshotAt = Date.distantPast
    @ObservationIgnored private var focusedWindowSnapshotPID: pid_t?

    func recentFocusSnapshot() -> WindowController.Frontmost? {
        guard Date().timeIntervalSince(focusedWindowSnapshotAt) < 0.1,
              focusedWindowSnapshotPID == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return focusedWindowSnapshot
    }
    var shortcutsRegistered = 0
    var shortcutsBlocked = 0

    /// Which hot keys another app owns, for the catalog and Settings (T53).
    var blockedShortcutIDs: Set<String> { shortcutManager?.blockedShortcutIDs ?? [] }
    var blockedShortcutTitles: [String] { shortcutManager?.blockedTitles ?? [] }
    var gap = (UserDefaults.standard.object(forKey: "windowGap") == nil
        ? 12
        : UserDefaults.standard.double(forKey: "windowGap")).clamped(to: 0...80)
    var showMiniMap = UserDefaults.standard.object(forKey: "showMiniMap") as? Bool ?? true
    var showPreview = UserDefaults.standard.object(forKey: "showPreview") as? Bool ?? true
    /// OCR quality and correction (T41). Languages stay automatic.
    var ocrFastRecognition = UserDefaults.standard.object(forKey: "ocrFastRecognition") as? Bool ?? false
    var ocrLanguageCorrection = UserDefaults.standard.object(forKey: "ocrLanguageCorrection") as? Bool ?? true
    var textRecognitionOptions: TextRecognitionOptions {
        TextRecognitionOptions(quality: ocrFastRecognition ? .fast : .accurate,
                               usesLanguageCorrection: ocrLanguageCorrection,
                               languages: [])
    }
    var miniMapPosition = PalettePosition(rawValue: UserDefaults.standard.string(forKey: "miniMapPosition") ?? "") ?? .topRight
    var themeID = PaletteTheme.normalized(UserDefaults.standard.string(forKey: "themeID") ?? "mocha")
    var overlayScale = UserDefaults.standard.object(forKey: "overlayScale") as? Double ?? 1.0
    var overlayOpacity = UserDefaults.standard.object(forKey: "overlayOpacity") as? Double ?? 0.94
    /// The largest a palette card may get, in points (the user's size setting).
    var paletteMaxCardWidth = UserDefaults.standard.object(forKey: "paletteMaxCardWidth") as? Double ?? 250
    /// Grid columns for the palette: 0 means "auto" (2–4 by window count), a
    /// positive value pins the count (T15).
    var paletteColumns = UserDefaults.standard.object(forKey: "paletteColumns") as? Int ?? 0
    var paletteOpacity = UserDefaults.standard.object(forKey: "paletteOpacity") as? Double ?? 0.9
    /// Whether the palette cards are tinted with the per-app colour (T12).
    var paletteTintedCards = UserDefaults.standard.object(forKey: "paletteTintedCards") as? Bool ?? true
    /// Whether the palette opens full screen (T13).
    var paletteFullScreen = UserDefaults.standard.object(forKey: "paletteFullScreen") as? Bool ?? false
    var paletteScreenLocation = PaletteScreenLocation(
        rawValue: UserDefaults.standard.string(forKey: "paletteScreenLocation") ?? ""
    ) ?? .focusedWindow
    var dragActivator = DragActivator(rawValue: UserDefaults.standard.string(forKey: "dragActivator") ?? "") ?? .fallback
    var dragEnabled = UserDefaults.standard.object(forKey: "dragEnabled") as? Bool ?? true
    /// Whether the intelligent layout offers what it suggests — with the reason —
    /// instead of applying it straight away (T18).
    var layoutAsksFirst = UserDefaults.standard.object(forKey: "layoutAsksFirst") as? Bool ?? true
    /// Per-kind priors for the content-weighted layout (T30), 0.5 … 2.0.
    var layoutPriors: [WindowKind: Double] = WorkspaceStore.loadLayoutPriors()

    /// Motion for lists and panels (T33). macOS Reduce Motion always wins.
    var animationsEnabled = UserDefaults.standard.object(forKey: "animationsEnabled") as? Bool ?? true
    var animationDuration = min(max(
        UserDefaults.standard.object(forKey: "animationDuration") as? Double ?? 0.22,
        0.08), 0.6)

    /// The coloured outline around the focused window (T36).
    var focusBorderEnabled = UserDefaults.standard.object(forKey: "focusBorderEnabled") as? Bool ?? true
    var focusBorderWidth = FocusBorder.clampedWidth(
        UserDefaults.standard.object(forKey: "focusBorderWidth") as? Double ?? FocusBorder.defaultWidth
    )

    var effectiveAnimationsEnabled: Bool {
        animationsEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Shake-to-open settings for the shelf (T31).
    var shelfShakeEnabled = UserDefaults.standard.object(forKey: "shelfShakeEnabled") as? Bool ?? true
    var shelfShakeSensitivity: ShelfShakeSensitivity = {
        let raw = UserDefaults.standard.string(forKey: "shelfShakeSensitivity") ?? ""
        return ShelfShakeSensitivity(rawValue: raw) ?? .medium
    }()
    var shelfExcludedApps: [String] = UserDefaults.standard.stringArray(forKey: "shelfExcludedApps") ?? []
    var macOSTilingEnabled = MacOSTiling.optionDragEnabled
    var setupCompleted = UserDefaults.standard.bool(forKey: "setupCompleted")
    var screenRecordingTrusted = WindowCapture.isAuthorized
    /// The windows last ticked in the switcher, so the menu can run a layout on
    /// the same subset after the palette has closed (T14).
    var lastLayoutSelection: [ActionableWindow] = []
    /// The numbered window groups (1…9), restored at start and saved on every
    /// change by `GroupStore` (G2).
    var groups: [Int: WindowGroup] = [:]
    /// The group most recently recalled, so adding a window to it can be brought
    /// forward with it (T15) and so the palette can mark it.
    var activeGroupSlot: Int?
    /// What is in use on screen, for the menu (T17): a group's name, or
    /// "Focus". `nil` when nothing is being kept in use. This is the observable
    /// mirror of the scene, which the scene itself never needs to be.
    private(set) var sceneTitle: String?
    /// The layout the advisor proposed and is waiting to be accepted (T18). Its
    /// windows ride along out of sight, since the menu only needs the label.
    private(set) var pendingLayout: LayoutAdvice?
    /// What is being kept in use on screen, if anything (T15/T17): which windows
    /// those are, where the scene put them, and what it had to put away for them.
    @ObservationIgnored private var scene: Scene?
    /// One step back (T17): the scene that was on screen before the last
    /// transition, and where the windows it moved were standing. Overwritten by
    /// every transition, so there is exactly one level to undo.
    @ObservationIgnored private var sceneUndo: SceneUndo?
    /// The windows the pending advice was computed for, and the timer that lets
    /// the offer lapse (T18).
    @ObservationIgnored private var pendingLayoutSet = ArrangeableSet()
    @ObservationIgnored private var pendingLayoutTimer: Timer?

    var theme: PaletteTheme { PaletteTheme.named(themeID) }

    static let shared = WorkspaceStore()

    @ObservationIgnored private var elements: [UUID: AXUIElement] = [:]
    @ObservationIgnored private var shortcutManager: ShortcutManager?
    @ObservationIgnored private var trustTimer: Timer?
    @ObservationIgnored private var frameTimers: [String: Timer] = [:]
    @ObservationIgnored private var frameLastWritten: [String: CGRect] = [:]
    /// Increments for every accepted frame command. Async layouts and delayed
    /// scene restores use it to discard work superseded by a newer command.
    @ObservationIgnored private var frameCommandEpoch = 0
    @ObservationIgnored private var contentAnalysisTask: Task<Void, Never>?
    @ObservationIgnored private var peekCaptureTask: Task<Void, Never>?
    @ObservationIgnored private var lastFrontmostKey: String?
    @ObservationIgnored private var promptedForTrust = false
    @ObservationIgnored private var promptedForScreenRecording = false
    @ObservationIgnored private var peekCaptureGeneration = 0
    @ObservationIgnored private var didInitialRecall = false
    /// App icons by pid, so each card does not hit the filesystem (T3).
    @ObservationIgnored private var iconCache: [pid_t: NSImage] = [:]
    /// Reads and writes the groups file (G2). Injectable only for tests, which
    /// point it at a temporary directory instead of Application Support.
    @ObservationIgnored var groupStore = GroupStore()
    /// The window designated for the peek (T16): the one ⌃⌥H shows while held.
    /// Session only — quitting forgets it — and never written to disk.
    @ObservationIgnored private var peekRef: WindowRef?
    /// The last image seen for the designated window, kept in memory for the
    /// rest of the session so a window closed since it was designated still has
    /// something to show ("Non più aperta").
    @ObservationIgnored private var peekLastImage: NSImage?
    /// Press / release / watchdog bookkeeping, kept pure and testable.
    @ObservationIgnored private let peekHold = PeekController()
    @ObservationIgnored private var peekWatchdog: Timer?
    @ObservationIgnored private var peekEscapeKey: UInt32?
    /// System notifications the peek listens for (sleep, screen lock), kept so
    /// the tokens are not lost.
    @ObservationIgnored private var systemObservers: [NSObjectProtocol] = []
    /// App name of the designated window, for the menu (T16).
    private(set) var peekName: String?
    /// Frames remembered since the last write to the groups file (T15). A drag
    /// or a recall touches the arrangement many times in a row, and rewriting
    /// the whole file each time would be wasteful: the write happens once the
    /// moving stops, and again if the app quits before the timer fires.
    @ObservationIgnored private var arrangementDirty = false
    @ObservationIgnored private var arrangementFlushTimer: Timer?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?
    @ObservationIgnored private var enhancedUIActivationObserver: NSObjectProtocol?

    /// What is on screen, in use, as the one record the scene commands work
    /// from: leaving it, undoing back to it, sending one more window to the tray.
    /// A group is a saved thing; a scene is only what is in use now, so nothing
    /// in here is ever written to disk.
    private struct Scene {
        /// Where the windows came from: a saved group's slot, or a set assembled
        /// on the spot (the ones in use, whatever put them there).
        enum Source: Equatable {
            case group(Int)
            case adHoc
        }

        var source: Source
        /// What the HUD calls it: the group's name, or "Focus".
        var title: String
        /// The windows in use, in the order they were put on screen.
        var members: [String]
        /// Where each member sits, as the scene left it. A window the scene never
        /// moved keeps the frame it already had.
        var frames: [String: CGRect]
        /// The apps the scene hid, to be shown again on the way out.
        var hiddenApps: [pid_t]
        /// The windows the scene minimised, to be restored on the way out.
        var minimizedWindows: [AXUIElement]
    }

    /// One step back (T17): what was on screen before a transition, and where the
    /// windows that transition was about to move were standing.
    private struct SceneUndo {
        var scene: Scene?
        var frames: [String: CGRect]
    }

    // Registers shortcuts, wires the event-driven window index and keeps
    // permission state live; no manual "connect" needed, no permanent polling.
    func start() {
        guard shortcutManager == nil else { return }
        loadGroups()
        WindowIndex.shared.start()
        WindowOutlineController.shared.start()
        startEnhancedUIHandling()
        WindowIndex.shared.onChange = { [weak self] in
            self?.syncModel()
            WindowOutlineController.shared.refresh()
        }
        WindowIndex.shared.onFocusChange = { [weak self] in
            self?.checkFrontmostChange()
            WindowOutlineController.shared.refresh(frontmost: self?.recentFocusSnapshot())
        }
        WindowIndex.shared.onGeometryNow = { WindowOutlineController.shared.refreshGeometry() }
        WindowIndex.shared.onGeometryChanged = { [weak self] element, frame in
            self?.syncWindowGeometry(element: element, frame: frame)
            WindowOutlineController.shared.refreshGeometry(for: element, frame: frame)
        }
        WindowIndex.shared.onFocusNow = { [weak self] in
            let focused = WindowController.frontmost()
            self?.focusedWindowSnapshot = focused
            self?.focusedWindowSnapshotAt = Date()
            self?.focusedWindowSnapshotPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            self?.recordFrontmostWindowFocus(focused)
            WindowOutlineController.shared.refresh(frontmost: focused)
        }
        WindowIndex.shared.onScreenChange = { [weak self] in self?.handleScreenChange() }
        WindowIndex.shared.onApplicationTerminated = { [weak self] pid in
            self?.iconCache[pid] = nil
            self?.recentFocusedWindowIDs.removeAll { $0.hasPrefix("\(pid)-") }
            AXEnhancedUIController.applicationDidTerminate(pid: pid)
        }
        startGlobalShortcuts()
        checkTrust()
        if !accessibilityTrusted { scheduleTrustPoll() }
        // The arrangement is written on a short debounce; a quit in the middle
        // of that window must not lose it (T15). The peek is session state: the
        // window it put away comes back on the way out, or quitting MakiDesk
        // would leave it hidden with nothing left to show it.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Registered on the main queue: the callbacks below are main-actor.
            MainActor.assumeIsolated {
                self?.clearPeek(announce: false)
                self?.flushArrangement()
            }
        }
        // The peek overlay must not outlive the desktop it was shown on: a lock
        // or a sleep takes the key away, and the release that would have closed
        // it never arrives (T16).
        systemObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePeek() }
        })
        systemObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePeek() }
        })
    }

    private func startEnhancedUIHandling() {
        guard enhancedUIActivationObserver == nil else { return }
        enhancedUIActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            let pid = application.processIdentifier
            let bundleIdentifier = application.bundleIdentifier
            Task { @MainActor [weak self] in
                self?.scheduleEnhancedUIDisable(pid: pid, bundleIdentifier: bundleIdentifier)
            }
        }
        if let application = NSWorkspace.shared.frontmostApplication {
            scheduleEnhancedUIDisable(pid: application.processIdentifier,
                                      bundleIdentifier: application.bundleIdentifier)
        }
    }

    private func scheduleEnhancedUIDisable(pid: pid_t, bundleIdentifier: String?) {
        guard AXEnhancedUIController.isChromiumBundle(bundleIdentifier),
              !NSWorkspace.shared.isVoiceOverEnabled,
              !NSWorkspace.shared.isSwitchControlEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            Task { @MainActor [weak self] in
                guard self != nil, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                DispatchQueue.global(qos: .utility).async {
                    AXEnhancedUIController.disableForChromiumApplication(pid: pid)
                }
            }
        }
    }

    private func scheduleTrustPoll() {
        guard trustTimer == nil else { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTrust() }
        }
    }

    private func checkFrontmostChange() {
        guard showMiniMap, accessibilityTrusted else { return }
        switch recentFocusSnapshot() ?? WindowController.frontmost() {
        case let .window(target):
            let key = target.id
            guard key != lastFrontmostKey else { return }
            lastFrontmostKey = key
            showMiniMapIfEnabled(for: target, frame: target.frame)
        case .desktop:
            // The desktop is not a window: no box round the whole screen. The
            // map comes up without a callout, and any previous one goes away.
            guard lastFrontmostKey != nil else { return }
            lastFrontmostKey = nil
            showMiniMapIfEnabled()
        case .none:
            return
        }
    }

    func checkTrust() {
        let trusted = AXIsProcessTrusted()
        let changed = trusted != accessibilityTrusted
        accessibilityTrusted = trusted
        if changed { makiLog.notice("accessibility trust changed -> \(trusted, privacy: .public)") }
        if trusted {
            // Accessibility has no change notification: once granted we can stop
            // polling. A revoked permission is caught by the next command.
            trustTimer?.invalidate()
            trustTimer = nil
            if changed || windows.isEmpty { refreshRealWindows() }
            maybePromptForScreenRecording()
        } else {
            scheduleTrustPoll()
            if !promptedForTrust {
                promptedForTrust = true
                _ = WindowController.requestAccessibilityPermission()
            }
            status = "Accessibility not granted · open Settings"
        }
        WindowOutlineController.shared.applySettings()
    }

    func openAccessibilitySettings() { WindowController.openAccessibilitySettings() }
    func openScreenRecordingSettings() { WindowController.openScreenRecordingSettings() }

    /// Screen Recording has no change notification either; the UI calls this to
    /// re-read the current state after the user visits System Settings.
    func refreshPermissionState() {
        accessibilityTrusted = AXIsProcessTrusted()
        screenRecordingTrusted = WindowCapture.isAuthorized
        WindowOutlineController.shared.applySettings()
    }

    // MARK: - Screen Recording

    private func maybePromptForScreenRecording() {
        guard showPreview, !screenRecordingTrusted, !promptedForScreenRecording else { return }
        promptedForScreenRecording = true
        requestScreenRecording()
    }

    func requestScreenRecording() {
        _ = WindowCapture.requestAuthorization()
        screenRecordingTrusted = WindowCapture.isAuthorized
    }

    // MARK: - Environment (Settings diagnostics)

    var bundleVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        default: return "development build"
        }
    }

    var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? "com.makidesk.app" }

    /// TCC keys permissions by the app's path: a build run from the build folder
    /// loses the grant as soon as it is moved or rebuilt.
    var isInApplications: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    func startGlobalShortcuts() {
        let manager = ShortcutManager { [weak self] action in
            self?.applyShortcut(action)
        }
        manager.start()
        // The peek's hold key (T16) needs both halves of the press, so it lives
        // apart from the fixed table above.
        if manager.registerPeekHold(
            onPress: { [weak self] in self?.showPeek() },
            onRelease: { [weak self] in self?.hidePeek() }
        ) == nil {
            makiLog.error("peek hold key unavailable: ⌃⌥H is taken by another app")
        }
        shortcutManager = manager
        shortcutsRegistered = manager.registeredCount
        shortcutsBlocked = manager.failedCount
    }

    func updateGap(_ value: Double) {
        gap = value.clamped(to: 0...80)
        UserDefaults.standard.set(gap, forKey: "windowGap")
    }

    func updateMiniMapVisibility(_ value: Bool) {
        showMiniMap = value
        UserDefaults.standard.set(value, forKey: "showMiniMap")
    }

    func updateShowPreview(_ value: Bool) {
        showPreview = value
        UserDefaults.standard.set(value, forKey: "showPreview")
        if value { maybePromptForScreenRecording() }
    }

    func updateOCRFastRecognition(_ value: Bool) {
        ocrFastRecognition = value
        UserDefaults.standard.set(value, forKey: "ocrFastRecognition")
    }

    func updateOCRLanguageCorrection(_ value: Bool) {
        ocrLanguageCorrection = value
        UserDefaults.standard.set(value, forKey: "ocrLanguageCorrection")
    }

    func updateMiniMapPosition(_ value: PalettePosition) {
        miniMapPosition = value
        UserDefaults.standard.set(value.rawValue, forKey: "miniMapPosition")
    }

    func updateTheme(_ value: String) {
        themeID = value
        UserDefaults.standard.set(value, forKey: "themeID")
        NotificationCenter.default.post(name: .makiDeskThemeChanged, object: nil)
    }

    func updateOverlayScale(_ value: Double) {
        overlayScale = value.clamped(to: 0.7...1.6)
        UserDefaults.standard.set(overlayScale, forKey: "overlayScale")
    }

    func updateOverlayOpacity(_ value: Double) {
        overlayOpacity = value.clamped(to: 0.4...1.0)
        UserDefaults.standard.set(overlayOpacity, forKey: "overlayOpacity")
    }

    /// Sets the largest a palette card may get (points). If the chosen number of
    /// columns would overflow the screen, cards shrink below this to fit (T15).
    func updatePaletteMaxCardWidth(_ value: Double) {
        paletteMaxCardWidth = value.clamped(to: 160...480)
        UserDefaults.standard.set(paletteMaxCardWidth, forKey: "paletteMaxCardWidth")
        WindowPalette.shared.applySettings(from: self)
    }

    /// Pins the palette grid columns; 0 restores the automatic count (T15).
    func updatePaletteColumns(_ value: Int) {
        paletteColumns = max(0, min(8, value))
        UserDefaults.standard.set(paletteColumns, forKey: "paletteColumns")
        WindowPalette.shared.applySettings(from: self)
    }

    func updatePaletteOpacity(_ value: Double) {
        paletteOpacity = value.clamped(to: 0.5...1.0)
        UserDefaults.standard.set(paletteOpacity, forKey: "paletteOpacity")
    }

    /// Tints the palette cards with the per-app colour, or leaves them neutral.
    func updatePaletteTintedCards(_ value: Bool) {
        paletteTintedCards = value
        UserDefaults.standard.set(value, forKey: "paletteTintedCards")
        WindowPalette.shared.applySettings(from: self)
    }

    /// Opens the window switcher full screen (T13), or in the compact panel.
    func updatePaletteFullScreen(_ value: Bool) {
        paletteFullScreen = value
        UserDefaults.standard.set(value, forKey: "paletteFullScreen")
        WindowPalette.shared.applySettings(from: self)
    }

    func updatePaletteScreenLocation(_ value: PaletteScreenLocation) {
        paletteScreenLocation = value
        UserDefaults.standard.set(value.rawValue, forKey: "paletteScreenLocation")
        // Placement is chosen at the next opening, so an open session stays put.
    }

    func updateDragActivator(_ value: DragActivator) {
        dragActivator = value
        UserDefaults.standard.set(value.rawValue, forKey: "dragActivator")
    }

    func updateDragEnabled(_ value: Bool) {
        dragEnabled = value
        UserDefaults.standard.set(value, forKey: "dragEnabled")
    }

    func updateLayoutAsksFirst(_ value: Bool) {
        layoutAsksFirst = value
        UserDefaults.standard.set(value, forKey: "layoutAsksFirst")
    }

    private static func loadLayoutPriors() -> [WindowKind: Double] {
        var priors = LayoutAdvisor.defaultPriors
        if let stored = UserDefaults.standard.dictionary(forKey: "layoutPriors") {
            for (key, value) in stored {
                if let kind = WindowKind(rawValue: key), let number = value as? NSNumber {
                    priors[kind] = min(max(number.doubleValue, 0.5), 2.0)
                }
            }
        }
        return priors
    }

    func layoutPrior(_ kind: WindowKind) -> Double {
        layoutPriors[kind] ?? LayoutAdvisor.defaultPriors[kind] ?? 1.0
    }

    func updateAnimationsEnabled(_ value: Bool) {
        animationsEnabled = value
        UserDefaults.standard.set(value, forKey: "animationsEnabled")
    }

    func updateAnimationDuration(_ value: Double) {
        let clamped = min(max(value, 0.08), 0.6)
        animationDuration = clamped
        UserDefaults.standard.set(clamped, forKey: "animationDuration")
    }

    func updateFocusBorderEnabled(_ value: Bool) {
        focusBorderEnabled = value
        UserDefaults.standard.set(value, forKey: "focusBorderEnabled")
        WindowOutlineController.shared.applySettings()
    }

    func updateFocusBorderWidth(_ value: Double) {
        let clamped = FocusBorder.clampedWidth(value)
        focusBorderWidth = clamped
        UserDefaults.standard.set(clamped, forKey: "focusBorderWidth")
        WindowOutlineController.shared.applySettings()
    }

    func updateShelfShakeEnabled(_ value: Bool) {
        shelfShakeEnabled = value
        UserDefaults.standard.set(value, forKey: "shelfShakeEnabled")
    }

    func updateShelfShakeSensitivity(_ value: ShelfShakeSensitivity) {
        shelfShakeSensitivity = value
        UserDefaults.standard.set(value.rawValue, forKey: "shelfShakeSensitivity")
    }

    /// Comma- or newline-separated bundle identifiers.
    func updateShelfExcludedApps(_ text: String) {
        let values = text
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }
        var unique: [String] = []
        for value in values where unique.contains(where: {
            $0.caseInsensitiveCompare(value) == .orderedSame
        }) == false {
            unique.append(value)
        }
        shelfExcludedApps = unique
        UserDefaults.standard.set(unique, forKey: "shelfExcludedApps")
    }

    func isShelfExcluded(bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return shelfExcludedApps.contains {
            $0.caseInsensitiveCompare(bundleId) == .orderedSame
        }
    }

    func updateLayoutPrior(_ value: Double, for kind: WindowKind) {
        let clamped = min(max(value, 0.5), 2.0)
        guard layoutPriors[kind] != clamped else { return }
        layoutPriors[kind] = clamped
        let stored = Dictionary(uniqueKeysWithValues: layoutPriors.map {
            ($0.key.rawValue, $0.value)
        })
        UserDefaults.standard.set(stored, forKey: "layoutPriors")
    }

    /// Turns the macOS "hold ⌥ to tile" setting on/off (writes the system
    /// preference) and mirrors it in our observable state.
    func updateMacOSTiling(_ enabled: Bool) {
        MacOSTiling.optionDragEnabled = enabled
        macOSTilingEnabled = enabled
    }

    /// Re-reads the macOS setting (e.g. after it was changed in System Settings).
    func refreshMacOSTiling() {
        macOSTilingEnabled = MacOSTiling.optionDragEnabled
    }

    /// What a factory reset clears (T23). The settings are always part of it —
    /// that is what the reset is — while the data that is **not** a setting is a
    /// tick the user makes in the confirmation. What a future panel keeps adds
    /// its own case here and its own tick there: notes (T20), the clipboard
    /// history (T21), the dropzones (T44).
    struct ResetScope: OptionSet {
        let rawValue: Int
        static let settings = ResetScope(rawValue: 1 << 0)
        /// The window groups, with their members and the arrangement remembered
        /// for them: the user's data, not a setting.
        static let groups = ResetScope(rawValue: 1 << 1)
        /// The notes and their drafts (T20).
        static let notes = ResetScope(rawValue: 1 << 2)
        /// The in-memory clipboard history (T21).
        static let clipboard = ResetScope(rawValue: 1 << 3)
        /// The dropzone commands (T44). A file written by a newer version is
        /// left alone.
        static let dropzones = ResetScope(rawValue: 1 << 4)
    }

    /// Restores the settings to their default values, going through the same
    /// update methods as the individual controls so all side effects (the open
    /// palette, the overlay) follow.
    ///
    /// Onboarding (`setupCompleted`) is deliberately kept, so the reset does not
    /// send the user back through the first-run flow, and the macOS ⌥-tiling
    /// preference is left alone: it is a system-wide setting, not one of ours.
    /// The window groups go only when `scope` asks for them (T23): they are the
    /// user's data, and the round starts by taking the scene on screen apart —
    /// otherwise the windows it had put away would stay hidden with no group
    /// left to bring them back.
    func resetToDefaults(scope: ResetScope = .settings) {
        if scope.contains(.notes) {
            MainActor.assumeIsolated { NotesStore.shared.deleteAllNotes() }
        }
        if scope.contains(.clipboard) {
            MainActor.assumeIsolated { ClipboardHistory.shared.clear() }
        }
        if scope.contains(.dropzones) {
            let removed = DropzoneStore().remove()
            MainActor.assumeIsolated {
                DropzoneCoordinator.shared.reload()
                if removed {
                    NotificationCenter.default.post(name: .makiDeskDropzonesReset, object: nil)
                }
            }
        }
        if scope.contains(.groups), !groups.isEmpty {
            leaveScene()
            sceneUndo = nil
            groups.removeAll()
            groupStore.save([])
        }
        guard scope.contains(.settings) else { return }
        updateGap(12)
        updateMiniMapVisibility(true)
        updateShowPreview(true)
        updateOCRFastRecognition(false)
        updateOCRLanguageCorrection(true)
        updateMiniMapPosition(.topRight)
        updateTheme("mocha")
        updateOverlayScale(1.0)
        updateOverlayOpacity(0.94)
        updatePaletteMaxCardWidth(250)
        updatePaletteColumns(0)
        updatePaletteOpacity(0.9)
        updatePaletteTintedCards(true)
        updatePaletteFullScreen(false)
        updatePaletteScreenLocation(.focusedWindow)
        updateDragActivator(.option)
        updateDragEnabled(true)
        updateLayoutAsksFirst(true)
        layoutPriors = LayoutAdvisor.defaultPriors
        UserDefaults.standard.removeObject(forKey: "layoutPriors")
        updateShelfShakeEnabled(true)
        updateShelfShakeSensitivity(.medium)
        updateShelfExcludedApps("")
        updateAnimationsEnabled(true)
        updateAnimationDuration(0.22)
        updateFocusBorderEnabled(true)
        updateFocusBorderWidth(FocusBorder.defaultWidth)
    }

    /// Frame of the overlay at its configured position (for placement math).
    var overlayFrame: CGRect {
        let size = CGSize(width: 320 * overlayScale, height: 220 * overlayScale)
        guard let screen = NSScreen.main else { return CGRect(origin: .zero, size: size) }
        return CGRect(origin: miniMapPosition.origin(size: size, in: screen.visibleFrame), size: size)
    }

    func completeSetup() {
        setupCompleted = true
        UserDefaults.standard.set(true, forKey: "setupCompleted")
    }

    func openSettings() {
        // The status-item bridge holds the `openSettings` environment action.
        // The legacy `showSettingsWindow:` selector reaches no responder in an
        // accessory app, so route the request through the bridge instead.
        NotificationCenter.default.post(name: .makiDeskOpenSettings, object: nil)
        bringSettingsToFront()
    }

    /// Brings the Settings window to the front and gives this accessory app the
    /// keyboard focus, without touching auxiliary windows.
    func bringSettingsToFront() {
        // A floating window cannot become main, and an accessory app with no
        // main window is not allowed to activate: Settings lives at the normal
        // level. Only touch its own window, never an auxiliary dialog.
        NSApp.activate()
        DispatchQueue.main.async {
            let all = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) }
            let settings = all.filter { $0.identifier?.rawValue == "MakiDeskSettingsWindow" }
            for window in (settings.isEmpty ? all.filter(\.canBecomeMain) : settings) {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: - Shortcuts

    func applyShortcut(_ action: WindowController.ShortcutAction) {
        // The notes panel does not touch other windows, so it must work even
        // when Accessibility has not been granted (T20).
        if action == .toggleNotes {
            MainActor.assumeIsolated { NotesController.shared.toggle() }
            return
        }
        if action == .toggleShelf {
            MainActor.assumeIsolated { ShelfController.shared.toggle() }
            return
        }
        // OCR reads the screen with Screen Recording; it must work without
        // Accessibility, like the panels (T41).
        if action == .recognizeText {
            TextRecognitionController.shared.recognizeArea(options: textRecognitionOptions)
            return
        }
        // The colour picker reads one pixel the same way (T36).
        if action == .sampleColor {
            ColorSamplerController.shared.sample()
            return
        }
        // Measuring reads no pixels at all: no permission required (T39).
        if action == .measureArea {
            MeasureController.shared.start()
            return
        }
        // Utility windows and presentation toggles need no Accessibility (T53).
        switch action {
        case .openSettings:
            NSApp.activate()
            NotificationCenter.default.post(name: .makiDeskOpenSettings, object: nil)
            return
        case .openKeyboardShortcuts:
            ShortcutsWindowController.shared.show()
            return
        case .openScreenshots:
            ScreenshotLibraryController.shared.show()
            return
        case .toggleFocusBorder:
            updateFocusBorderEnabled(!focusBorderEnabled)
            return
        case .toggleMiniMap:
            updateMiniMapVisibility(!showMiniMap)
            return
        case .leaveGroup:
            leaveGroup()
            return
        default:
            break
        }
        let trusted = AXIsProcessTrusted()
        accessibilityTrusted = trusted
        guard trusted else {
            status = "Accessibility not granted · open Settings"
            scheduleTrustPoll()
            return
        }
        switch action {
        case .clipboardHistory:
            MainActor.assumeIsolated { ClipboardController.shared.toggle() }
            return
        case .switchWindows:
            WindowPalette.shared.show(store: self, mode: .browse, backwards: false)
            return
        case .switchWindowsBack:
            WindowPalette.shared.show(store: self, mode: .browse, backwards: true)
            return
        case .searchWindows:
            // While the palette is open the Carbon hot key has already eaten
            // the key event, so the palette's own space handling can never run;
            // hand the press over rather than re-opening in search mode.
            if WindowPalette.shared.isVisible {
                WindowPalette.shared.handleSpaceHotKey()
                return
            }
            WindowPalette.shared.show(store: self, mode: .search)
            return
        case let .assignToGroup(slot):
            toggleGroupMembership(slot: slot)
            return
        case let .recallGroup(slot):
            recallGroup(slot: slot)
            return
        case .peekDesignate:
            togglePeekDesignation()
            return
        case .putAwayFront:
            putAwayFrontWindow()
            return
        case .showEverything:
            showEverything()
            return
        case .undoStep:
            undoScene()
            return
        case .focusSelection:
            focus(on: lastLayoutSelection)
            return
        case .clearPeek:
            clearPeek()
            return
        case .applySuggestedLayout:
            if pendingLayout != nil { acceptPendingLayout() }
            else { status = "No suggested layout to apply" }
            return
        case .gridLayout:
            tileOnScreen(gap: gap)
            return
        case .spiralLayout:
            autoLayout()
            return
        case .suggestLayout:
            suggestLayout()
            return
        case .contentLayout:
            contentLayout()
            return
        default:
            break
        }
        guard let target = WindowController.frontmostWindow() else {
            status = "No controllable frontmost window"
            return
        }
        applyTiling(action, to: target)
    }

    /// Places the frontmost window on the screen. Positions never depend on the
    /// other windows, so a command is never blocked by an overlap.
    private func applyTiling(_ action: WindowController.ShortcutAction, to target: WindowController.WindowInfo) {
        if action == .toggleFullScreen {
            let on = !WindowController.isFullScreen(target.element)
            if WindowController.setFullScreen(on, for: target.element) {
                status = "\(target.appName) · \(on ? "full screen" : "windowed")"
            } else {
                status = "⚠︎ \(target.appName) · full screen not available"
            }
            return
        }
        if action == .minimize {
            setMinimized(true, target: target)
            focusNextStack(after: target)
            return
        }

        // Some windows (panels, dialogs, some Electron apps) refuse geometry
        // changes; report that instead of doing nothing (B10).
        let capabilities = WindowController.capabilities(of: target.element)
        guard capabilities.resizable else {
            status = "⚠︎ \(target.appName) · this window cannot be resized"
            return
        }

        // `target` was just read from the focused AX window above. Do not
        // invalidate and rediscover every window here: that global AX scan can
        // block the hotkey for seconds. `applyFrame` updates the local model for
        // this window, and WindowIndex notifications keep other changes fresh.
        // AX may still expose the previous frame while an earlier keyboard
        // command is queued. Continue the ladder from the latest requested
        // frame so rapid key presses do not repeat a step.
        let tilingTarget = targetWithPendingFrame(target)
        let screen = WindowController.screen(forAXFrame: tilingTarget.frame)
        let gapHalf = gap / 2
        let visible = WindowController.axVisibleFrame(for: screen)
        let area = visible
        let current = tilingTarget.frame.insetBy(dx: -gapHalf, dy: -gapHalf)

        if let outcome = ladderStep(action, area: area, current: current) {
            // Arrow commands are discrete steps. Apply the final frame once,
            // then use the bounded T27 verification retries if an app restores
            // its old size asynchronously. A newer key press invalidates them.
            switch outcome {
            case .frame(let logical):
                applyFrame(logical.insetBy(dx: gapHalf, dy: gapHalf).integral, to: target,
                           reason: label(for: action), animate: false)
            case .minimize:
                setMinimized(true, target: target)
            case .screenBoundary(let direction, let fallback):
                if let frame = frameOnAdjacentScreen(from: tilingTarget.frame, direction: direction) {
                    // Keep the frame on one display throughout the move. An
                    // interpolated frame straddles monitors, so the next arrow
                    // event can classify it against the wrong screen.
                    applyFrame(frame, to: target, reason: "moved to adjacent display",
                               animate: false)
                } else if let fallback {
                    applyFrame(fallback.insetBy(dx: gapHalf, dy: gapHalf).integral, to: target,
                               reason: label(for: action), animate: false, retryOnMismatch: false)
                } else {
                    setMinimized(true, target: target)
                }
            }
            return
        }

        let key = "\(target.appName)|\(target.title)"
        guard let logical = logicalFrame(for: action, area: area, current: current, key: key) else { return }
        applyFrame(logical.insetBy(dx: gapHalf, dy: gapHalf).integral, to: target,
                   reason: label(for: action))
    }

    private enum LadderOutcome {
        case frame(CGRect)
        case minimize
        case screenBoundary(ScreenDirection, fallback: CGRect?)
    }

    private enum ScreenDirection: Equatable { case left, right, up, down }

    /// Steps the ladder one position. Beyond an edge state the caller can move
    /// to a neighboring display, falling back to the previous clamp/minimize
    /// behavior when no display exists in that direction.
    private func ladderStep(
        _ action: WindowController.ShortcutAction,
        area: CGRect,
        current: CGRect
    ) -> LadderOutcome? {
        guard let (axis, direction) = ladderAxisAndDirection(for: action) else { return nil }
        let orthogonal = orthogonalRange(of: current, axis: axis)
        let states = TilingEngine.ladderRects(area: area, axis: axis, orthogonal: orthogonal)
        let slot = TilingEngine.slot(of: current, area: area, axis: axis, states: states)
        let next = slot.advanced(by: direction)
        switch next {
        case .beforeStart:
            switch axis {
            case .horizontal: return .screenBoundary(.left, fallback: states[0])
            case .vertical:
                return .screenBoundary(.up, fallback: minHeightRect(area: area, orthogonal: orthogonal))
            }
        case .afterEnd:
            switch axis {
            case .horizontal:
                return .screenBoundary(.right, fallback: states[states.count - 1])
            case .vertical: return .screenBoundary(.down, fallback: nil)
            }
        case .step(let index):
            return .frame(states[index])
        }
    }

    /// Finds the nearest display in the requested direction and preserves the
    /// current size when it fits, so a constrained app can move without first
    /// accepting a resize.
    private func frameOnAdjacentScreen(from frame: CGRect, direction: ScreenDirection) -> CGRect? {
        let screens = NSScreen.screens.map { (screen: $0, frame: WindowController.axVisibleFrame(for: $0)) }
        guard let source = screens.max(by: { lhs, rhs in
            let left = lhs.frame.intersection(frame)
            let right = rhs.frame.intersection(frame)
            return left.width * left.height < right.width * right.height
        }) else { return nil }

        func directionalGap(_ candidate: CGRect) -> CGFloat? {
            switch direction {
            case .left where candidate.maxX <= source.frame.minX:
                return source.frame.minX - candidate.maxX
            case .right where candidate.minX >= source.frame.maxX:
                return candidate.minX - source.frame.maxX
            case .up where candidate.maxY <= source.frame.minY:
                return source.frame.minY - candidate.maxY
            case .down where candidate.minY >= source.frame.maxY:
                return candidate.minY - source.frame.maxY
            default:
                return nil
            }
        }
        func orthogonalDistance(_ candidate: CGRect) -> CGFloat {
            switch direction {
            case .left, .right:
                if candidate.maxY < frame.minY { return frame.minY - candidate.maxY }
                if candidate.minY > frame.maxY { return candidate.minY - frame.maxY }
            case .up, .down:
                if candidate.maxX < frame.minX { return frame.minX - candidate.maxX }
                if candidate.minX > frame.maxX { return candidate.minX - frame.maxX }
            }
            return 0
        }

        guard let destination = screens
            .filter({ $0.screen != source.screen })
            .compactMap({ item -> (CGRect, CGFloat, CGFloat)? in
                guard let gap = directionalGap(item.frame) else { return nil }
                return (item.frame, gap, orthogonalDistance(item.frame))
            })
            .min(by: { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.2 < rhs.2 : lhs.1 < rhs.1
            })?.0 else { return nil }

        let size = TilingEngine.sizeFitting(frame.size, in: destination)
        let width = size.width
        let height = size.height
        var x = min(max(frame.minX, destination.minX), destination.maxX - width)
        var y = min(max(frame.minY, destination.minY), destination.maxY - height)
        switch direction {
        case .left: x = destination.maxX - width
        case .right: x = destination.minX
        case .up: y = destination.maxY - height
        case .down: y = destination.minY
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func minHeightRect(area: CGRect, orthogonal: ClosedRange<CGFloat>) -> CGRect {
        let height = min(TilingEngine.minimumHeight, area.height)
        return CGRect(x: orthogonal.lowerBound, y: area.minY,
                      width: orthogonal.upperBound - orthogonal.lowerBound, height: height)
    }

    private func orthogonalRange(of rect: CGRect, axis: TilingEngine.Axis) -> ClosedRange<CGFloat> {
        switch axis {
        case .horizontal: return rect.minY...rect.maxY
        case .vertical: return rect.minX...rect.maxX
        }
    }

    private func ladderAxisAndDirection(for action: WindowController.ShortcutAction) -> (TilingEngine.Axis, Int)? {
        switch action {
        case .leftHalf: return (.horizontal, -1)
        case .rightHalf: return (.horizontal, 1)
        case .topHalf: return (.vertical, -1)
        case .bottomHalf: return (.vertical, 1)
        default: return nil
        }
    }

    private func logicalFrame(
        for action: WindowController.ShortcutAction,
        area: CGRect,
        current: CGRect,
        key: String
    ) -> CGRect? {
        switch action {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf:
            return nil
        case .topLeft:
            return TilingEngine.regionRect(area: area, relative: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        case .topRight:
            return TilingEngine.regionRect(area: area, relative: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        case .bottomLeft:
            return TilingEngine.regionRect(area: area, relative: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
        case .bottomRight:
            return TilingEngine.regionRect(area: area, relative: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        case .centerCycle:
            return centerCycleFrame(area: area, current: current, key: key)
        case .center:
            let width = min(current.width, area.width)
            let height = min(current.height, area.height)
            return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
        case .phi:
            return goldenFrame(area: area)
        case .toggleFullScreen, .minimize, .switchWindows, .switchWindowsBack, .searchWindows,
             .assignToGroup, .recallGroup, .peekDesignate,
             .putAwayFront, .showEverything, .undoStep,
             .gridLayout, .spiralLayout, .suggestLayout, .contentLayout,
             .toggleNotes, .clipboardHistory, .toggleShelf, .recognizeText, .sampleColor,
             .measureArea, .openSettings, .openKeyboardShortcuts, .openScreenshots,
             .toggleFocusBorder, .toggleMiniMap, .focusSelection, .leaveGroup,
             .clearPeek, .applySuggestedLayout:
            return nil
        }
    }

    private func goldenFrame(area: CGRect) -> CGRect {
        let width = min(area.width, area.height * TilingEngine.phi)
        let height = min(area.height, area.width / TilingEngine.phi)
        return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }

    /// Ctrl-Opt-Return: two states only — full screen ↔ golden-centred.
    private func centerCycleFrame(area: CGRect, current: CGRect, key: String) -> CGRect {
        if framesMatch(current, area) { return cycleGoldenFrame(area: area) }
        return area
    }

    /// Golden-ratio reduction of the full-screen size, centred (0.618 × 0.618).
    private func cycleGoldenFrame(area: CGRect) -> CGRect {
        let width = area.width / TilingEngine.phi
        let height = area.height / TilingEngine.phi
        return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }

    private func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 12 && abs(a.minY - b.minY) < 12
            && abs(a.width - b.width) < 12 && abs(a.height - b.height) < 12
    }

    /// Focuses the next window behind `target` in the stacking order.
    private func focusNextStack(after target: WindowController.WindowInfo) {
        let all = WindowIndex.shared.snapshot()
        guard !all.isEmpty else { return }
        let next: WindowController.WindowInfo
        if let index = all.firstIndex(where: { $0.id == target.id }) {
            next = all[(index + 1) % all.count]
        } else {
            next = all[0]
        }
        guard next.id != target.id else { return }
        NSRunningApplication(processIdentifier: next.pid)?.activate()
        WindowController.raise(next.element)
        WindowController.focus(next.element)
    }

    // MARK: - The single frame-application path (A4)

    /// Applies a frame to a window in one place: the AX element, the model, the
    /// overlay and the on-screen feedback all move together. Every path —
    /// keyboard ladder, regions, auto layout and Ctrl+Opt+drag — uses this.
    ///
    /// The write is verified and, if it did not stick, tried again (T27): some
    /// apps impose a minimum size, take the new size a run loop later, or put
    /// their own frame back while the un-minimise animation runs. A full-screen
    /// window is left alone: it has no frame of ours to set.
    func applyFrame(_ frame: CGRect, to target: WindowController.WindowInfo, reason: String,
                    animate: Bool = true, retryOnMismatch: Bool = true) {
        guard !WindowController.isFullScreen(target.element) else {
            status = "\(target.appName) · full screen, left alone"
            return
        }
        contentAnalysisTask?.cancel()
        let adjusted = frame.integral
        frameCommandEpoch &+= 1
        if let entry = matchingIndex(for: target) {
            windows[entry].x = adjusted.minX
            windows[entry].y = adjusted.minY
            windows[entry].width = adjusted.width
            windows[entry].height = adjusted.height
        }
        // Remember where every group holding this window is putting it (T15):
        // this is the one path every move goes through — keyboard, regions, a
        // recall, Ctrl+Opt+drag — so the arrangement a group restores is always
        // the last one seen.
        rememberArrangement(adjusted, for: target)
        // One generation per window per command: a re-try that belongs to an
        // older command is dropped instead of writing over a newer one, so a
        // re-try can never make a window dance (T27).
        let key = animationKey(for: target)
        let generation = (frameGenerations[key] ?? 0) + 1
        frameGenerations[key] = generation
        pendingFrameTargets[key] = adjusted
        makiLog.notice("frame command window=\(key, privacy: .public) app=\(target.appName, privacy: .public) reason=\(reason, privacy: .public) requested=(\(Int(adjusted.minX)),\(Int(adjusted.minY)),\(Int(adjusted.width)),\(Int(adjusted.height))) generation=\(generation, privacy: .public)")
        let finish: () -> Void = { [weak self] in
            self?.verifyFrame(adjusted, target: target, reason: reason,
                              key: key, generation: generation, attempt: 0,
                              retryOnMismatch: retryOnMismatch)
        }
        if animate && effectiveAnimationsEnabled && target.pid != Self.ownPID {
            animateFrame(to: adjusted, element: target.element, key: key,
                         generation: generation, completion: finish)
        } else {
            frameTimers[key]?.invalidate()
            frameTimers[key] = nil
            frameLastWritten[key] = nil
            WindowController.setFrameAsync(adjusted, for: target.element, identity: key) {
                WindowOutlineController.shared.refreshGeometry(for: target.element, frame: adjusted)
                if retryOnMismatch {
                    finish()
                } else {
                    // Give AX-backed apps a moment to publish the write before
                    // reading their accepted frame. Arrow steps intentionally do
                    // not retry a mismatch, which can fight an app's constraints.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: finish)
                }
            }
        }
    }

    /// The only process whose windows must never be written from a worker
    /// queue: AppKit services its own Accessibility writes on the main thread.
    private static let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Counts frame commands per window, so a re-try belonging to an older
    /// command never writes over a newer one (T27).
    @ObservationIgnored private var frameGenerations: [String: Int] = [:]
    @ObservationIgnored private var pendingFrameTargets: [String: CGRect] = [:]

    private func targetWithPendingFrame(_ target: WindowController.WindowInfo) -> WindowController.WindowInfo {
        var updated = target
        updated.frame = Self.tilingFrame(actual: target.frame,
                                         pending: pendingFrameTargets[animationKey(for: target)])
        return updated
    }

    static func tilingFrame(actual: CGRect, pending: CGRect?) -> CGRect {
        pending ?? actual
    }

    /// How long to wait before each re-try of a frame that did not stick (T27),
    /// so a command settles in about half a second and never makes a window
    /// dance: two re-tries, then the app is the constraint.
    private static let frameRetries: [TimeInterval] = [0.15, 0.3]

    /// Beyond this the frame is not the one that was asked for; below it, the
    /// couple of points some apps add are their own chrome (T27).
    private static let frameTolerance: CGFloat = 2

    /// Checks that the frame stuck and, when it did not, writes it again —
    /// through the opposite order the second time, and integral the third, which
    /// is what an app that imposes a minimum or rounds the size needs. Only
    /// after both re-tries does the feedback declare the constraint, with the
    /// frame that was asked for and the one that is actually there.
    private func verifyFrame(_ wanted: CGRect, target: WindowController.WindowInfo,
                             reason: String, key: String, generation: Int, attempt: Int,
                             retryOnMismatch: Bool = true) {
        // A newer command owns this window now: this check is history.
        guard frameGenerations[key] == generation else { return }
        if target.pid == Self.ownPID {
            // Reading our own window's frame runs AppKit in-process too, so it
            // stays on the main thread with the write it verifies.
            applyVerification(WindowController.frame(of: target.element), wanted: wanted,
                              target: target, reason: reason, key: key,
                              generation: generation, attempt: attempt,
                              retryOnMismatch: retryOnMismatch)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let actual = WindowController.frame(of: target.element)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.applyVerification(actual, wanted: wanted, target: target, reason: reason,
                                       key: key, generation: generation, attempt: attempt,
                                       retryOnMismatch: retryOnMismatch)
            }
        }
    }

    private func applyVerification(_ actual: CGRect?, wanted: CGRect,
                                   target: WindowController.WindowInfo, reason: String,
                                   key: String, generation: Int, attempt: Int,
                                   retryOnMismatch: Bool) {
        guard frameGenerations[key] == generation else { return }
        if let actual {
            WindowIndex.shared.updateFrame(actual, for: target.element)
            WindowOutlineController.shared.refreshGeometry(for: target.element, frame: actual)
        }
        if let actual, withinTolerance(actual, wanted) {
            pendingFrameTargets[key] = nil
            makiLog.notice("frame verified window=\(key, privacy: .public) attempt=\(attempt, privacy: .public) actual=(\(Int(actual.minX)),\(Int(actual.minY)),\(Int(actual.width)),\(Int(actual.height)))")
            status = "\(target.appName) · \(reason)"
            showMiniMapIfEnabled(for: target, frame: wanted)
            return
        }
        guard retryOnMismatch, attempt < Self.frameRetries.count else {
            pendingFrameTargets[key] = nil
            let asked = "\(Int(wanted.width))×\(Int(wanted.height))"
            let got = actual.map { "\(Int($0.width))×\(Int($0.height))" } ?? "nothing"
            let actualOrigin = actual.map { "(\(Int($0.minX)),\(Int($0.minY)))" } ?? "unknown"
            makiLog.error("frame mismatch window=\(key, privacy: .public) requested=(\(Int(wanted.minX)),\(Int(wanted.minY)),\(asked)) actual=(\(actualOrigin),\(got)) retries=\(attempt, privacy: .public)")
            status = "⚠︎ \(target.appName) · asked \(asked), got \(got)"
            HUDController.shared.show("\(target.appName) keeps its own size\nasked \(asked) · got \(got)",
                                      symbol: "exclamationmark.triangle.fill")
            showMiniMapIfEnabled(for: target, frame: actual ?? wanted)
            return
        }
        retryFrame(wanted, target: target, attempt: attempt, key: key) {
            let delay = Self.frameRetries[attempt]
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.verifyFrame(wanted, target: target, reason: reason,
                                  key: key, generation: generation, attempt: attempt + 1,
                                  retryOnMismatch: retryOnMismatch)
            }
        }
    }

    /// The first re-try writes the size before the position: an app that refuses
    /// a size while it is being moved accepts it on its own; the second writes
    /// whole points (T27).
    private func retryFrame(_ wanted: CGRect, target: WindowController.WindowInfo, attempt: Int,
                            key: String, completion: @escaping @MainActor () -> Void) {
        if attempt == 0 {
            WindowController.setFrameAsync(wanted, for: target.element, identity: key,
                                           order: .sizeThenPosition, completion: completion)
        } else {
            WindowController.setFrameAsync(wanted.integral, for: target.element,
                                           identity: key, completion: completion)
        }
    }

    private func withinTolerance(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= Self.frameTolerance && abs(a.minY - b.minY) <= Self.frameTolerance
            && abs(a.width - b.width) <= Self.frameTolerance && abs(a.height - b.height) <= Self.frameTolerance
    }

    /// The identity the frame write coordinator uses for a model window. It
    /// matches `animationKey(for:)`, so a keyboard animation and a mini-map
    /// drag for the same window serialize on one queue instead of racing.
    private func frameIdentity(for window: WorkspaceWindow) -> String? {
        if let systemID = window.systemID, systemID.isEmpty == false { return systemID }
        guard let element = elements[window.id] else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return "pid-\(pid)-element-\(CFHash(element))"
    }

    /// Timers are keyed by logical identity, not by the transient AX element
    /// instance, so a repeated command animates one timer per window.
    private func animationKey(for target: WindowController.WindowInfo) -> String {
        target.id.isEmpty
            ? "pid-\(target.pid)-element-\(CFHash(target.element))"
            : target.id
    }

    /// Applies a frame chosen by Ctrl+Opt+drag. The drag works on a raw window
    /// hit (no id), so it is matched back to the model here.
    func applyDraggedFrame(_ frame: CGRect, element: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        // The tiling drag is for other applications. Our own panels are placed
        // by their controllers, and an in-process AX write would have to run on
        // the main thread (see `WindowController.isOwnProcess`).
        guard pid != Self.ownPID else { return }
        let target = WindowController.WindowInfo(
            id: "", title: "", appName: appName(for: pid) ?? "Window",
            element: element, frame: frame, pid: pid
        )
        applyFrame(frame, to: target, reason: "dragged")
    }

    private func appName(for pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    /// Smoothly animates a window's frame (position + size). Each window has its
    /// own timer, so overlapping animations do not cancel each other, and the
    /// completion is always delivered (A3).
    private func animateFrame(to target: CGRect, element: AXUIElement, key: String,
                              generation: Int, completion: (@MainActor () -> Void)? = nil) {
        frameTimers[key]?.invalidate()
        frameTimers[key] = nil
        frameLastWritten[key] = nil
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let start = reduceMotion ? nil : WindowController.frame(of: element)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.frameGenerations[key] == generation else { return }
                guard !reduceMotion, let start else {
                    WindowController.setFrameAsync(target, for: element, identity: key,
                                                   completion: { completion?() })
                    return
                }
                self.startFrameAnimation(from: start, to: target, element: element,
                                         key: key, completion: completion)
            }
        }
    }

    private func startFrameAnimation(from start: CGRect, to target: CGRect,
                                     element: AXUIElement, key: String,
                                     completion: (@MainActor () -> Void)?) {
        let startTime = ProcessInfo.processInfo.systemUptime
        let duration = 0.18
        frameLastWritten[key] = start.integral
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            // The timer is scheduled on the main run loop; the animation state
            // and the frame writes belong to the store's main actor.
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min(max((ProcessInfo.processInfo.systemUptime - startTime) / duration, 0), 1)
                let eased = 1 - pow(1 - t, 3)
                let frame = CGRect(
                    x: start.minX + (target.minX - start.minX) * eased,
                    y: start.minY + (target.minY - start.minY) * eased,
                    width: start.width + (target.width - start.width) * eased,
                    height: start.height + (target.height - start.height) * eased
                ).integral
                let previous = self.frameLastWritten[key] ?? start.integral
                if t >= 1 {
                    timer.invalidate()
                    self.frameTimers[key] = nil
                    self.frameLastWritten[key] = nil
                    WindowController.setFrameAsync(target, for: element, identity: key,
                                                   completion: { completion?() })
                } else if frame.origin != previous.origin || frame.size != previous.size {
                    self.frameLastWritten[key] = frame
                    WindowController.setFrameAsync(frame, for: element, identity: key)
                }
            }
        }
        frameTimers[key] = timer
    }

    private func setMinimized(_ minimized: Bool, target: WindowController.WindowInfo) {
        do {
            try WindowController.setMinimized(minimized, for: target.element)
            status = "\(target.appName) · \(minimized ? "minimized" : "restored")"
        } catch {
            status = "⚠︎ \(target.appName) · \(error.localizedDescription)"
        }
    }

    /// Finds the model entry for a freshly discovered window: by stable system id
    /// first, then by the AX element itself, then by title (A2).
    private func matchingIndex(for target: WindowController.WindowInfo) -> Int? {
        if let index = windows.firstIndex(where: { $0.systemID == target.id }) { return index }
        for (index, window) in windows.enumerated() {
            if let element = elements[window.id], CFEqual(element, target.element) { return index }
        }
        return windows.firstIndex { $0.appName == target.appName && $0.title == target.title }
    }

    private func label(for action: WindowController.ShortcutAction) -> String {
        switch action {
        case .leftHalf: return "left column"
        case .rightHalf: return "right column"
        case .topHalf: return "top row"
        case .bottomHalf: return "bottom row"
        case .topLeft: return "top-left quarter"
        case .topRight: return "top-right quarter"
        case .bottomLeft: return "bottom-left quarter"
        case .bottomRight: return "bottom-right quarter"
        case .centerCycle: return "center cycle"
        case .center: return "centered"
        case .phi: return "golden ratio"
        case .toggleFullScreen: return "full screen"
        case .minimize: return "minimized"
        case .switchWindows: return "switch"
        case .switchWindowsBack: return "switch"
        case .searchWindows: return "search"
        case .assignToGroup, .recallGroup: return "group"
        case .toggleNotes: return "notes"
        case .clipboardHistory: return "clipboard"
        case .toggleShelf: return "shelf"
        case .recognizeText: return "text"
        case .sampleColor: return "colour"
        case .measureArea: return "measure"
        case .openSettings: return "settings"
        case .openKeyboardShortcuts: return "shortcuts"
        case .openScreenshots: return "screenshots"
        case .toggleFocusBorder: return "focus border"
        case .toggleMiniMap: return "mini map"
        case .focusSelection: return "focus selection"
        case .leaveGroup: return "left group"
        case .clearPeek: return "peek cleared"
        case .applySuggestedLayout: return "suggested layout"
        case .peekDesignate: return "peek"
        case .putAwayFront: return "sent away"
        case .showEverything: return "everything back"
        case .undoStep: return "undone"
        case .gridLayout: return "grid layout"
        case .spiralLayout: return "golden spiral"
        case .suggestLayout: return "suggested layout"
        case .contentLayout: return "content layout"
        }
    }

    // MARK: - Discovery

    @ObservationIgnored private var inventoryCommandDepth = 0

    /// Recursive entry after the refresh executes the command synchronously
    /// against that published snapshot. A newer frame command cancels the wait.
    private func deferUntilFreshInventory(_ action: @escaping () -> Void) -> Bool {
        guard inventoryCommandDepth == 0 else { return false }
        contentAnalysisTask?.cancel()
        frameCommandEpoch &+= 1
        let epoch = frameCommandEpoch
        let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        WindowIndex.shared.refreshAsync { [weak self] _ in
            guard let self, self.frameCommandEpoch == epoch, self.accessibilityTrusted,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundPID else { return }
            self.inventoryCommandDepth += 1
            defer { self.inventoryCommandDepth -= 1 }
            action()
        }
        return true
    }

    /// Event-driven model refresh: never touches the status message so it does
    /// not clobber the feedback of the command that just ran.
    private func syncModel() {
        guard accessibilityTrusted else { return }
        WindowIndex.shared.refreshChangedAsync { [weak self] discovered in
            self?.rebuildModel(from: discovered, announce: false)
        }
    }

    /// Updates one moved/resized window from its AX notification. A geometry
    /// event must not trigger a full discovery across every running app.
    private func syncWindowGeometry(element: AXUIElement, frame: CGRect) {
        guard let index = windows.indices.first(where: { index in
            guard let tracked = elements[windows[index].id] else { return false }
            return CFEqual(tracked, element)
        }) else { return }
        windows[index].x = frame.minX
        windows[index].y = frame.minY
        windows[index].width = frame.width
        windows[index].height = frame.height
    }

    func refreshRealWindows() {
        accessibilityTrusted = AXIsProcessTrusted()
        guard accessibilityTrusted else {
            status = "Accessibility not granted · open Settings"
            return
        }
        screenRecordingTrusted = WindowCapture.isAuthorized
        WindowIndex.shared.refreshAsync { [weak self] discovered in
            guard let self, self.accessibilityTrusted else { return }
            self.rebuildModel(from: discovered, announce: true)
            let focused = WindowController.frontmost()
            self.focusedWindowSnapshot = focused
            self.recordFrontmostWindowFocus(focused)
            if !self.didInitialRecall {
                self.didInitialRecall = true
                self.recallOffscreenWindows()
            }
        }
    }

    private func rebuildModel(from inventory: [WindowController.WindowInfo], announce: Bool) {
        let discovered = inventory.filter { !$0.minimized && !$0.temporarilyUnavailable }
        var existingBySystemID: [String: WorkspaceWindow] = [:]
        for window in windows {
            if let systemID = window.systemID { existingBySystemID[systemID] = window }
        }
        var updated: [WorkspaceWindow] = []
        var newElements: [UUID: AXUIElement] = [:]

        for info in discovered {
            let existing = existingBySystemID.removeValue(forKey: info.id)
            let window = WorkspaceWindow(
                id: existing?.id ?? UUID(),
                title: info.title,
                appName: info.appName,
                x: info.frame.origin.x,
                y: info.frame.origin.y,
                width: info.frame.width,
                height: info.frame.height,
                tint: existing?.tint ?? tint(for: info.appName),
                systemID: info.id
            )
            updated.append(window)
            newElements[window.id] = info.element
        }

        windows = updated
        elements = newElements
        selectedID = updated.contains(where: { $0.id == selectedID }) ? selectedID : updated.first?.id
        guard announce else { return }
        status = shortcutsBlocked > 0
            ? "Ready · \(shortcutsBlocked) shortcuts taken by another app"
            : "Ready · \(updated.count) windows"
    }

    /// Published windows, including minimised ones. Inventory-consuming
    /// commands request a fresh asynchronous snapshot before entering here.
    func actionableWindows() -> [ActionableWindow] {
        WindowIndex.shared.snapshot(includeMinimized: true).map { info in
            ActionableWindow(id: info.id, title: info.title, appName: info.appName,
                             frame: info.frame, pid: info.pid, minimized: info.minimized,
                             element: info.element, color: color(for: info.appName),
                             windowID: info.windowID, icon: icon(for: info.pid),
                             state: state(for: info))
        }
    }

    /// Maps the most recently published index snapshot without causing a fresh
    /// system-wide Accessibility scan.
    func cachedActionableWindows() -> [ActionableWindow] { actionableWindows() }

    private func validatedSelection(_ requested: [ActionableWindow]) -> [ActionableWindow] {
        let live = Dictionary(actionableWindows().map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        return requested.compactMap { live[$0.id] }.filter { $0.state != .unavailable }
    }

    /// Stable switcher order: windows visited most recently first, followed by
    /// never-focused windows in alphabetical order. CG stacking order is
    /// intentionally ignored because it can vary between discovery scans.
    func orderedWindowsForPalette(_ candidates: [ActionableWindow]) -> [ActionableWindow] {
        let recency = Dictionary(uniqueKeysWithValues:
            recentFocusedWindowIDs.enumerated().map { ($0.element, $0.offset) })
        return candidates.sorted { lhs, rhs in
            let leftRank = recency[lhs.id]
            let rightRank = recency[rhs.id]
            if let leftRank, let rightRank, leftRank != rightRank { return leftRank < rightRank }
            if leftRank != nil && rightRank == nil { return true }
            if leftRank == nil && rightRank != nil { return false }
            let appOrder = lhs.appName.localizedStandardCompare(rhs.appName)
            if appOrder != .orderedSame { return appOrder == .orderedAscending }
            let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    private func recordFrontmostWindowFocus(_ frontmost: WindowController.Frontmost) {
        guard case let .window(focused) = frontmost else { return }
        let snapshot = WindowIndex.shared.snapshot(includeMinimized: true)
        let known = snapshot.first(where: { CFEqual($0.element, focused.element) })
            ?? snapshot.first(where: {
                $0.pid == focused.pid && $0.title == focused.title && $0.frame == focused.frame
            })
        let id = known?.id ?? focused.id
        recentFocusedWindowIDs.removeAll { $0 == id }
        recentFocusedWindowIDs.insert(id, at: 0)
        if recentFocusedWindowIDs.count > 64 {
            recentFocusedWindowIDs.removeLast(recentFocusedWindowIDs.count - 64)
        }
    }

    /// What a layout command does with one live window: place it, or leave it
    /// alone for a stated reason (T24).
    enum LayoutDisposition: Equatable {
        /// In view and arrangeable.
        case arrange
        /// In full screen: the app owns the frame and refuses ours.
        case fullScreen
        /// Minimised, or owned by an app that is hidden: out of view on purpose.
        case away
    }

    static func disposition(minimized: Bool, appHidden: Bool, fullScreen: Bool) -> LayoutDisposition {
        if minimized || appHidden { return .away }
        if fullScreen { return .fullScreen }
        return .arrange
    }

    /// A layout command's candidates, with what it deliberately left out so the
    /// feedback can say how many windows it placed and why there were not more
    /// (T24).
    struct ArrangeableSet {
        var windows: [ActionableWindow] = []
        /// In view, but in full screen: no frame of ours to set.
        var fullScreen = 0
        /// Out of view on purpose: minimised, or its app is hidden.
        var away = 0
        var unavailable = 0

        init(windows: [ActionableWindow] = []) { self.windows = windows }

        var isEmpty: Bool { windows.isEmpty }
    }

    /// The windows a layout command may arrange: the ones actually on screen —
    /// not minimised, not full screen, and not owned by an app that is hidden. A
    /// window nobody can see must not be pulled out of the Dock or out from
    /// under a scene keeping it away, and it must not take a tile from a window
    /// that is visible; a full-screen window has no frame of ours to set, and
    /// counting it would leave the grid one cell short (T18/T24).
    ///
    /// The index is re-read first: the command must see the windows that are
    /// there now (T24).
    private func arrangeableSet() -> ArrangeableSet {
        var set = ArrangeableSet()
        for window in actionableWindows() {
            if window.state == .unavailable { set.unavailable += 1; continue }
            let disposition = Self.disposition(
                minimized: window.minimized,
                appHidden: NSRunningApplication(processIdentifier: window.pid)?.isHidden ?? false,
                fullScreen: WindowController.isFullScreen(window.element)
            )
            switch disposition {
            case .arrange: set.windows.append(window)
            case .fullScreen: set.fullScreen += 1
            case .away: set.away += 1
            }
        }
        return set
    }

    /// The windows a layout command arranges (T18).
    private func arrangeableWindows() -> [ActionableWindow] { arrangeableSet().windows }

    /// One line saying how many windows a layout placed and, when that is fewer
    /// than what is in view, why: a window that is away stays away, a full-screen
    /// window cannot be given a frame of ours (T24).
    static func layoutSummary(_ set: ArrangeableSet) -> String {
        var text = set.windows.count == 1 ? "1 window" : "\(set.windows.count) windows"
        if set.fullScreen == 1 { text += " · 1 full screen" }
        if set.fullScreen > 1 { text += " · \(set.fullScreen) full screen" }
        if set.away == 1 { text += " · 1 away" }
        if set.away > 1 { text += " · \(set.away) away" }
        if set.unavailable > 0 { text += " · \(set.unavailable) temporarily unavailable" }
        return text
    }

    /// The app icon, looked up once per pid and cached (T3).
    private func icon(for pid: pid_t) -> NSImage? {
        if let cached = iconCache[pid] { return cached }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon
        if let icon { iconCache[pid] = icon }
        return icon
    }

    /// Whether a window is on screen or minimised (T5).
    private func state(for info: WindowController.WindowInfo) -> WindowState {
        info.temporarilyUnavailable ? .unavailable : (info.minimized ? .minimized : .normal)
    }

    func windowInfo(for window: ActionableWindow) -> WindowController.WindowInfo {
        WindowController.WindowInfo(
            id: window.id, title: window.title, appName: window.appName,
            element: window.element, frame: window.frame, pid: window.pid,
            windowID: window.windowID, minimized: window.minimized
        )
    }

    /// Brings a window back on screen and focuses it: un-minimises it and, if it
    /// is off-screen, clamps its current size inside the visible area.
    func bringOnScreen(_ window: ActionableWindow) {
        guard window.state != .unavailable else {
            NSRunningApplication(processIdentifier: window.pid)?.activate()
            status = "\(window.appName) · window temporarily unavailable"
            return
        }
        let screen = WindowController.screen(forAXFrame: window.frame)
        let area = WindowController.axVisibleFrame(for: screen)
        // Already on screen and not minimised: just focus it.
        if !window.minimized, let frame = WindowController.frame(of: window.element), area.contains(frame) {
            focus(window)
            return
        }
        if window.minimized {
            try? WindowController.setMinimized(false, for: window.element)
        }
        let raw = WindowController.frame(of: window.element)?.size ?? window.frame.size
        let width = raw.width > 120 ? min(raw.width, area.width) : area.width * 0.6
        let height = raw.height > 120 ? min(raw.height, area.height) : area.height * 0.6
        let x = min(max(window.frame.minX, area.minX), area.maxX - width)
        let y = min(max(window.frame.minY, area.minY), area.maxY - height)
        let target = CGRect(x: x, y: y, width: width, height: height)
        applyFrame(target, to: windowInfo(for: window), reason: "brought on screen")
        activate(window)
    }

    func focus(_ window: ActionableWindow) {
        if window.minimized { try? WindowController.setMinimized(false, for: window.element) }
        activate(window)
        status = "\(window.appName) · focused"
    }

    // MARK: - Window groups (G0/G2)

    /// Reads the saved groups once, at start, so they survive a restart. A
    /// missing or unreadable file simply means no groups (see `GroupStore`).
    private func loadGroups() {
        var loaded: [Int: WindowGroup] = [:]
        for group in groupStore.load() where (1...9).contains(group.slot) {
            loaded[group.slot] = group
        }
        groups = loaded
    }

    /// Stores `group` and writes the whole set to disk. Every group mutation goes
    /// through here, so the file can never drift from the in-memory state.
    private func commit(_ group: WindowGroup) {
        groups[group.slot] = group
        groupStore.save(groups.values.sorted { $0.slot < $1.slot })
    }

    /// A live window reduced to the fields a group remembers.
    func identity(for window: ActionableWindow) -> WindowIdentity {
        WindowIdentity(id: window.id,
                       bundleId: NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier,
                       appName: window.appName,
                       title: window.title,
                       document: WindowController.document(of: window.element))
    }

    private func identity(for info: WindowController.WindowInfo) -> WindowIdentity {
        WindowIdentity(id: info.id,
                       bundleId: NSRunningApplication(processIdentifier: info.pid)?.bundleIdentifier,
                       appName: info.appName,
                       title: info.title,
                       document: WindowController.document(of: info.element))
    }

    /// Adds the frontmost window to group `slot`, or removes it when already
    /// there. Adding to the group that is currently on screen re-presents it, so
    /// the newcomer is brought forward with it (T15).
    func toggleGroupMembership(slot: Int) {
        guard (1...9).contains(slot) else { return }
        guard accessibilityTrusted else {
            HUDController.shared.show("Accessibility not granted", symbol: "exclamationmark.triangle.fill")
            return
        }
        guard let front = WindowController.frontmostWindow() else {
            HUDController.shared.show("No window", symbol: "exclamationmark.triangle.fill")
            return
        }
        toggleMembership(ref: WindowRef(identity: identity(for: front)), in: slot)
    }

    /// Adds or removes one specific window to/from group `slot`, persisting the
    /// change and reporting it. Used by the palette, where the window comes from
    /// a card rather than from the frontmost app. Adding to the group that is
    /// currently on screen re-presents it. Returns `true` when it was added.
    @discardableResult
    func toggleMembership(of window: ActionableWindow, in slot: Int) -> Bool {
        toggleMembership(ref: WindowRef(identity: identity(for: window)), in: slot)
    }

    /// The one place membership mutates: commit to memory and disk, report, and
    /// re-present the group along the way when it is the one on screen.
    @discardableResult
    private func toggleMembership(ref: WindowRef, in slot: Int) -> Bool {
        guard (1...9).contains(slot) else { return false }
        var group = groups[slot] ?? WindowGroup(slot: slot)

        if let index = group.members.firstIndex(where: { $0.matches(ref) }) {
            group.members.remove(at: index)
            commit(group)
            HUDController.shared.show("Removed from \(group.displayName) · \(count(group.members.count))",
                                      symbol: "minus.circle.fill")
            return false
        }
        group.members.append(ref)
        commit(group)
        HUDController.shared.show("Added to \(group.displayName) · \(count(group.members.count))",
                                  symbol: "plus.circle.fill")
        if activeGroupSlot == slot { recallGroup(slot: slot, announce: false) }
        return true
    }

    /// The windows of `group` that are live in `windows`, in the group's saved
    /// order. Uses the same ladder as a recall, so ticks match what a recall
    /// would actually lay out.
    func groupMembers(of slot: Int, among windows: [ActionableWindow]) -> [ActionableWindow] {
        guard let group = groups[slot], !group.members.isEmpty else { return [] }
        let matches = GroupMatcher.match(group.members, to: windows.map { identity(for: $0) })
        return matches.compactMap { $0.map { windows[$0] } }
    }

    /// Whether `window` belongs to group `slot` right now.
    func groupContains(_ slot: Int, window: ActionableWindow) -> Bool {
        guard let group = groups[slot] else { return false }
        let ref = WindowRef(identity: identity(for: window))
        return group.members.contains { $0.matches(ref) }
    }

    /// Which groups each live window belongs to, keyed by window id — what the
    /// palette badges on the thumbnails. Each group is matched on its own (a
    /// window can sit in several), with the same ladder as a recall.
    func groupSlots(among windows: [ActionableWindow]) -> [String: [Int]] {
        let used = groups.filter { !$0.value.members.isEmpty }
        guard !used.isEmpty else { return [:] }
        let identities = windows.map { identity(for: $0) }
        var result: [String: [Int]] = [:]
        for slot in used.keys.sorted() {
            let matches = GroupMatcher.match(groups[slot]!.members, to: identities)
            for index in Set(matches.compactMap { $0 }) {
                result[windows[index].id, default: []].append(slot)
            }
        }
        return result
    }

    // MARK: - Remembering where a group's windows are (T15)

    /// Remembers `frame` as the place `target` has now, in every group that owns
    /// it. A move arrives through `applyFrame` as a raw window; it is matched
    /// back to the model here, so the group is found by the same identity a
    /// recall would use.
    private func rememberArrangement(_ frame: CGRect, for target: WindowController.WindowInfo) {
        guard let index = matchingIndex(for: target) else { return }
        rememberArrangement(frame, ofModelWindowAt: index)
    }

    /// Remembers `frame` for the model window at `index`, in every group that
    /// owns it.
    private func rememberArrangement(_ frame: CGRect, ofModelWindowAt index: Int) {
        guard let ref = ref(forModelWindowAt: index) else { return }
        rememberArrangement(frame, ref: ref)
    }

    /// Remembers `frame` for a live member window, matched by the identity a
    /// recall uses.
    private func rememberArrangement(_ frame: CGRect, of window: ActionableWindow) {
        rememberArrangement(frame, ref: WindowRef(identity: identity(for: window)))
    }

    /// The one place a frame is written to a group: every group holding this
    /// window gets it, keyed by the *member's* own saved id — the key a recall
    /// looks up, which survives a restart where a fresh system id would not.
    /// In memory only; the file follows on a short debounce.
    private func rememberArrangement(_ frame: CGRect, ref: WindowRef) {
        var changed = false
        for slot in groups.keys {
            guard var group = groups[slot],
                  let index = group.members.firstIndex(where: { $0.matches(ref) }) else { continue }
            let key = group.members[index].id
            guard group.frames[key] != frame else { continue }
            group.frames[key] = frame
            groups[slot] = group
            changed = true
        }
        guard changed else { return }
        arrangementDirty = true
        scheduleArrangementFlush()
    }

    /// The saved-reference form of a model window: the same fields a group
    /// stores, read back so a frame can be remembered under a key that survives
    /// a restart.
    private func ref(forModelWindowAt index: Int) -> WindowRef? {
        guard index < windows.count else { return nil }
        let window = windows[index]
        guard let systemID = window.systemID, !systemID.isEmpty else { return nil }
        let element = elements[window.id]
        var pid: pid_t = 0
        if let element { AXUIElementGetPid(element, &pid) }
        return WindowRef(identity: WindowIdentity(
            id: systemID,
            bundleId: pid != 0 ? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier : nil,
            appName: window.appName,
            title: window.title,
            document: element.flatMap { WindowController.document(of: $0) }
        ))
    }

    /// Writes the remembered arrangement once the movement has stopped.
    private func scheduleArrangementFlush() {
        arrangementFlushTimer?.invalidate()
        arrangementFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            // The timer runs on the main run loop, where the store is isolated.
            MainActor.assumeIsolated { self?.flushArrangement() }
        }
    }

    /// Writes the groups file now if the arrangement changed since the last
    /// write. Called by the debounce timer and again when the app terminates.
    func flushArrangement() {
        arrangementFlushTimer?.invalidate()
        arrangementFlushTimer = nil
        guard arrangementDirty else { return }
        if groupStore.save(groups.values.sorted { $0.slot < $1.slot }) {
            arrangementDirty = false
        } else {
            scheduleArrangementRetry()
        }
    }

    private func scheduleArrangementRetry() {
        arrangementFlushTimer?.invalidate()
        arrangementFlushTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushArrangement() }
        }
    }

    // MARK: - Recalling a group: a scene, not a re-disposition (T15)

    /// Brings the members of group `slot` on screen **where they were**: the
    /// arrangement recorded when they were last placed is restored — positions
    /// and sizes as they were, no layout computed, nothing ordered by content.
    /// Windows that are not in the group are put away, so the group is the only
    /// thing on screen.
    ///
    /// A group with nothing recorded yet (saved before T15, or never placed)
    /// brings its windows back where they stand and records that: a group has no
    /// layout of its own (T18) — the arrangement is the user's.
    func recallGroup(slot: Int, announce: Bool = true) {
        if deferUntilFreshInventory({ [weak self] in guard let self else { return }; self.recallGroup(slot: slot, announce: announce) }) { return }
        guard (1...9).contains(slot) else { return }
        guard let group = groups[slot], !group.members.isEmpty else {
            if announce { HUDController.shared.show("\(groupName(slot)) is empty", symbol: "tray") }
            return
        }

        let (resolved, missing) = resolveGroup(group)
        guard !resolved.isEmpty else {
            HUDController.shared.show("\(group.displayName) — no windows found", symbol: "exclamationmark.triangle.fill")
            return
        }

        // One step back (T17) before anything moves: the scene on screen now, and
        // where the windows about to come into use are standing.
        rememberStepBack(moving: resolved.map(\.window))

        // Entering another scene takes the previous one apart first, so its
        // windows come back and only then does the new group clear the screen.
        if scene?.source != .group(slot) { leaveScene() }

        present(source: .group(slot), title: group.displayName,
                resolved: resolved, arrangement: group.frames,
                missing: missing, announce: announce)
    }

    /// The live members of `group`, in the group's saved order, each with the
    /// reference it matched (the key its remembered frame is stored under).
    ///
    /// The window list is re-read here, not taken from the cache: a member whose
    /// window was opened a moment ago must be recognised, not reported missing
    /// (T22).
    private func resolveGroup(_ group: WindowGroup) -> (resolved: [(ref: WindowRef, window: ActionableWindow)], missing: Int) {
        let live = actionableWindows()
        let matches = GroupMatcher.match(group.members, to: live.map { identity(for: $0) })
        var resolved: [(ref: WindowRef, window: ActionableWindow)] = []
        var missing = 0
        for (index, ref) in group.members.enumerated() {
            if let match = matches[index] {
                if live[match].state == .unavailable { missing += 1 }
                else { resolved.append((ref, live[match])) }
            } else {
                missing += 1
            }
        }
        return (resolved, missing)
    }

    /// Puts one set of windows on screen in use (T15/T17): brings them back,
    /// places them, puts everything else away on their display, and records the
    /// scene — the thing leaving, or undoing, works from.
    ///
    /// `arrangement` is where each window goes, keyed by its ref — the frames a
    /// group remembers, or the frames a caller has just computed for an ad-hoc
    /// scene (the grid `focus(on:)` uses). A window with nothing in the table
    /// keeps the place it is in now: moving it somewhere arbitrary would be
    /// worse than leaving it.
    private func present(source: Scene.Source, title: String,
                         resolved: [(ref: WindowRef, window: ActionableWindow)],
                         arrangement: [String: CGRect],
                         missing: Int, announce: Bool) {
        let members = resolved.map(\.window)
        let area = sceneArea(for: members)

        let planned: [(window: ActionableWindow, frame: CGRect?)] =
            resolved.map { ($0.window, arrangement[$0.ref.id]) }

        // Work from the windows' live state, not the cached index: a window that
        // is really minimised ignores geometry until it is restored, and an app
        // that is hidden draws none of its windows, so its tile stays empty.
        // Both are the reveal half of the spec (§6.2), and it precedes the
        // arranging: a frame set on a window still in the Dock does not stick.
        let reveal = WindowScene.revealPlan(members: members.map { member in
            WindowScene.Candidate(
                id: member.id, pid: member.pid,
                minimized: WindowController.isMinimized(member.element),
                appHidden: NSRunningApplication(processIdentifier: member.pid)?.isHidden ?? false
            )
        })
        for pid in reveal.revealedApps { NSRunningApplication(processIdentifier: pid)?.unhide() }
        var needsRestore: [String: Bool] = [:]
        for id in reveal.restoredWindows {
            guard let member = members.first(where: { $0.id == id }) else { continue }
            try? WindowController.setMinimized(false, for: member.element)
            needsRestore[id] = true
        }
        // `offDesktop` counts members that are not on this Space at all (their
        // CG window number is unknown because they are not in the on-screen
        // list): those get a tile, but no public API can pull them across.
        let offDesktop = members.filter { member in
            !reveal.revealedApps.contains(member.pid)
                && !reveal.restoredWindows.contains(member.id)
                && member.windowID == nil
        }.count

        var applied: [(window: ActionableWindow, frame: CGRect)] = []
        for entry in planned {
            guard let frame = entry.frame else { continue }
            applyFrame(frame, to: windowInfo(for: entry.window), reason: title)
            applied.append((entry.window, frame))
        }

        // Every member ends up with a remembered place, including one that had
        // none: its current frame is written down, so the next recall knows
        // where to put it back. The same frames are the scene's, so putting the
        // scene back after an undo re-places exactly these windows.
        var placed: [String: CGRect] = [:]
        for entry in planned {
            guard let frame = entry.frame ?? WindowController.frame(of: entry.window.element),
                  !WindowController.isMinimized(entry.window.element) else { continue }
            placed[entry.window.id] = frame
            rememberArrangement(frame, of: entry.window)
        }

        // The scene: everything that is not a member goes away, on this display.
        // Done before the members are raised, so the app that had the focus goes
        // away first and the group ends up in front, not something that hid late.
        let removals = putAwayNonMembers(members: members, on: area)
        // Re-presenting the same scene adds nothing (its non-members are already
        // away); the record keeps what an earlier pass put away, so leaving it
        // still brings everything back.
        let previous = scene?.source == source ? scene : nil
        let hiddenApps = (previous?.hiddenApps ?? [])
            + removals.hiddenApps.filter { !(previous?.hiddenApps ?? []).contains($0) }
        let minimized = (previous?.minimizedWindows ?? []) + removals.minimizedWindows
        let putAway = hiddenApps.count + minimized.count
        scene = Scene(source: source, title: title,
                      members: members.map(\.id), frames: placed,
                      hiddenApps: hiddenApps, minimizedWindows: minimized)
        sceneTitle = title

        switch source {
        case let .group(slot): activeGroupSlot = slot
        case .adHoc: activeGroupSlot = nil
        }
        // A deliberate recall brings the whole set forward: tiling only *moves*
        // windows, so without this the windows would stay behind whatever you
        // were using, and one full-screen-sized window there hides every tile
        // that is not its own app's. Each window's app is activated in turn
        // (newest last, so the first window's app ends on top) — only for the
        // windows that are already on this desktop, because activating an app
        // whose window is on another Space would yank you there. Raising then
        // fixes the order inside each app, where a sibling window would
        // otherwise cover a tile.
        // Re-disposing after adding a window must not do any of this: it must
        // not steal focus.
        let focus = members.first
        if announce {
            var activated = Set<pid_t>()
            for window in members.reversed()
            where window.windowID != nil && activated.insert(window.pid).inserted {
                NSRunningApplication(processIdentifier: window.pid)?.activate()
            }
            if let focus { activate(focus) }
        }
        raiseToFront(members, topmost: focus, focusFirst: announce)

        // The app can put its own frame back while the un-minimise animation runs,
        // undoing the placement; re-apply once it has settled.
        let restoring = applied.compactMap { entry -> (WindowController.WindowInfo, CGRect)? in
            guard needsRestore[entry.window.id] == true else { return nil }
            return (windowInfo(for: entry.window), entry.frame)
        }
        if !restoring.isEmpty {
            let restoreEpoch = frameCommandEpoch
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.frameCommandEpoch == restoreEpoch else { return }
                for (target, frame) in restoring {
                    self.applyFrame(frame, to: target, reason: title, animate: false)
                }
            }
        }

        if announce {
            let verb = source == .adHoc ? "arranged" : "restored"
            var text = applied.count == 0
                ? "\(title) — \(count(members.count)) in use, where they stand"
                : "\(title) — \(count(applied.count)) \(verb)"
            if applied.count > 0, applied.count < members.count {
                text += " · \(members.count - applied.count) left where they stand"
            }
            if missing > 0 { text += " · \(missing) not found" }
            if offDesktop == 1 { text += " · 1 on another desktop" }
            if offDesktop > 1 { text += " · \(offDesktop) on other desktops" }
            if putAway > 0 { text += " · \(putAway) put away" }
            HUDController.shared.show(text, symbol: source == .adHoc
                                      ? "square.grid.3x3.fill" : "arrow.uturn.backward.circle.fill")

            // A member that does not actually come back is never absent in
            // silence: the reveal settles (or does not) within half a second, and
            // what is still in the Dock is counted (T22).
            let feedbackEpoch = frameCommandEpoch
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.frameCommandEpoch == feedbackEpoch else { return }
                let away = members.filter { member in
                    WindowController.isMinimized(member.element)
                        || (NSRunningApplication(processIdentifier: member.pid)?.isHidden ?? false)
                }.count
                guard away > 0 else { return }
                HUDController.shared.show(
                    "\(title) · \(away) \(away == 1 ? "window" : "windows") still away",
                    symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    /// The visible area of the display the group lives on: the one holding most
    /// of its windows (ties to the earliest screen). Scenes are per display
    /// (T15), so a layout computed here never drags a group onto another screen.
    private func sceneArea(for windows: [ActionableWindow]) -> CGRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return WindowController.axVisibleFrame(for: nil) }
        var best: NSScreen?
        var bestCount = 0
        for screen in screens {
            let count = windows.filter { WindowController.screen(forAXFrame: $0.frame) === screen }.count
            if count > bestCount { bestCount = count; best = screen }
        }
        return WindowController.axVisibleFrame(for: best ?? NSScreen.main ?? screens[0])
    }

    /// Puts every window that is not in use away on their display (T15/T17) and
    /// reports what was moved, so the caller can record the scene. An app owning
    /// a member stays visible — hiding it would hide the member — and only its
    /// other windows are minimised. Windows the user had already minimised, apps
    /// already hidden, windows we may not touch, and windows on other displays
    /// are left untouched.
    private func putAwayNonMembers(members: [ActionableWindow], on area: CGRect)
        -> (hiddenApps: [pid_t], minimizedWindows: [AXUIElement]) {
        let memberIDs = Set(members.map(\.id))
        // Every live window is offered to the planner, members included: an app
        // owning a member has to be recognised as such, or hiding it would take
        // the member off the screen with it.
        var candidates: [WindowScene.Candidate] = []
        var elements: [String: AXUIElement] = [:]
        // Reality, not the cache: a window opened in the last moment is still a
        // window to put away (T22).
        for window in actionableWindows() {
            guard window.state != .unavailable else { continue }
            let app = NSRunningApplication(processIdentifier: window.pid)
            candidates.append(WindowScene.Candidate(
                id: window.id, pid: window.pid,
                minimized: window.minimized || WindowController.isMinimized(window.element),
                appHidden: app?.isHidden ?? false,
                appHideable: app != nil,
                onDisplay: memberIDs.contains(window.id) || area.intersects(window.frame),
                unmanaged: WindowController.isFullScreen(window.element)
            ))
            elements[window.id] = window.element
        }

        let plan = WindowScene.plan(windows: candidates, members: memberIDs)
        guard !plan.isEmpty else { return ([], []) }

        var hiddenApps: [pid_t] = []
        var minimizedWindows: [AXUIElement] = []
        func minimize(_ element: AXUIElement) {
            if (try? WindowController.setMinimized(true, for: element)) != nil {
                minimizedWindows.append(element)
            }
        }
        for pid in plan.hiddenApps {
            if NSRunningApplication(processIdentifier: pid)?.hide() == true {
                hiddenApps.append(pid)
            } else {
                // The app could not be hidden after all: minimise its windows so
                // the scene is still the only thing on screen.
                for window in candidates where window.pid == pid {
                    if let element = elements[window.id] { minimize(element) }
                }
            }
        }
        for id in plan.minimizedWindows {
            if let element = elements[id] { minimize(element) }
        }
        return (hiddenApps, minimizedWindows)
    }

    /// Takes the scene on screen apart: the apps it hid are shown again and the
    /// windows it minimised are restored — only those, so a window the user has
    /// since opened or minimised himself is his own call. Nothing is left in use
    /// (T15/T17), which is why every other scene command starts here.
    private func leaveScene() {
        guard let current = scene else { return }
        scene = nil
        activeGroupSlot = nil
        sceneTitle = nil
        for pid in current.hiddenApps { NSRunningApplication(processIdentifier: pid)?.unhide() }
        for element in current.minimizedWindows where WindowController.isMinimized(element) {
            try? WindowController.setMinimized(false, for: element)
        }
    }

    /// Leaves the group on screen: the windows it put away come back, and no
    /// group is on screen any more (T15). This is what the *Leave group* menu
    /// item does; entering another group does the same thing first.
    func leaveGroup(announce: Bool = true) {
        guard let slot = activeGroupSlot else { return }
        rememberStepBack()
        leaveScene()
        if announce { HUDController.shared.show("Left \(groupName(slot))", symbol: "arrow.uturn.backward") }
    }

    // MARK: - Focus: a scene without a group (T17)

    /// Brings a set of windows into use on the spot — the ones ticked in the
    /// switcher, or whatever the caller has in hand — placed in a grid and
    /// nothing saved anywhere. It is the one scene that arranges on entry: there
    /// is no arrangement to restore for a set assembled just now. Entering a
    /// scene again takes the current one apart first, and the step is undoable
    /// like any other.
    func focus(on requested: [ActionableWindow], announce: Bool = true) {
        if deferUntilFreshInventory({ [weak self] in guard let self else { return }; self.focus(on: requested, announce: announce) }) { return }
        let windows = validatedSelection(requested)
        guard !windows.isEmpty else { return }
        let area = sceneArea(for: windows)
        let frames = TilingEngine.frames(for: .grid, count: windows.count, in: area, gap: gap)
        var resolved: [(ref: WindowRef, window: ActionableWindow)] = []
        var arrangement: [String: CGRect] = [:]
        for (index, window) in windows.enumerated() {
            let ref = WindowRef(identity: identity(for: window))
            resolved.append((ref, window))
            if index < frames.count { arrangement[ref.id] = frames[index] }
        }
        rememberStepBack(moving: windows)
        if scene?.source != .adHoc { leaveScene() }
        present(source: .adHoc, title: "Focus",
                resolved: resolved, arrangement: arrangement,
                missing: 0, announce: announce)
    }

    /// Sends the frontmost window to the tray: it leaves the scene while the
    /// rest stay in use (T17). It is put away by the same rules as any other
    /// window out of use — minimised, or its whole app when that was the app's
    /// last window in use.
    func putAwayFrontWindow() {
        if deferUntilFreshInventory({ [weak self] in guard let self else { return }; self.putAwayFrontWindow() }) { return }
        guard let current = scene else {
            HUDController.shared.show("Nothing in use", symbol: "tray")
            return
        }
        guard let front = WindowController.frontmostWindow() else {
            HUDController.shared.show("No window", symbol: "exclamationmark.triangle.fill")
            return
        }
        // Match by the stable system id first, then by the element itself: the
        // frontmost window's identity is the same one the scene recorded.
        let live = actionableWindows()
        guard let target = live.first(where: { $0.id == front.id || CFEqual($0.element, front.element) }) else {
            HUDController.shared.show("No window", symbol: "exclamationmark.triangle.fill")
            return
        }
        guard current.members.contains(target.id) else {
            status = "\(front.appName) is not in use"
            return
        }
        let remaining = current.members.filter { $0 != target.id }
        // First back to how the scene found things, then in with one window
        // fewer, so the one taken out follows the ordinary rules.
        rememberStepBack()
        leaveScene()
        guard !remaining.isEmpty else {
            HUDController.shared.show("Nothing left in use", symbol: "tray")
            return
        }
        presentLive(ids: remaining, like: current, announce: true)
    }

    /// Puts everything away back on screen, scene and all (T17): the apps the
    /// scene hid show again and its windows come back. The way out of a scene
    /// that went wrong partway through.
    func showEverything(announce: Bool = true) {
        guard scene != nil else {
            if announce { HUDController.shared.show("Nothing put away", symbol: "eye") }
            return
        }
        rememberStepBack()
        leaveScene()
        if announce { HUDController.shared.show("Everything back", symbol: "rectangle.on.rectangle") }
    }

    /// One step back (T17): the apps and windows the last transition put away
    /// come back, the windows it moved return where they stood, and the scene
    /// that was on screen before comes into use again. One level only.
    func undoScene(announce: Bool = true) {
        if deferUntilFreshInventory({ [weak self] in guard let self else { return }; self.undoScene(announce: announce) }) { return }
        guard let undo = sceneUndo else {
            if announce { HUDController.shared.show("Nothing to undo", symbol: "arrow.uturn.backward") }
            return
        }
        sceneUndo = nil
        leaveScene()
        // The windows the transition had moved go back where they stood before.
        let live = actionableWindows()
        for (id, frame) in undo.frames {
            guard let window = live.first(where: { $0.id == id }) else { continue }
            applyFrame(frame, to: windowInfo(for: window), reason: "undo", animate: false)
            rememberArrangement(frame, of: window)
        }
        if let previous = undo.scene { restore(previous, announce: announce) }
        else if announce { HUDController.shared.show("Undone", symbol: "arrow.uturn.backward") }
    }

    /// Notes one step back (T17) before a transition moves anything: the scene
    /// as it is now, and where the windows it is about to move are standing.
    private func rememberStepBack(moving moved: [ActionableWindow] = []) {
        var frames: [String: CGRect] = [:]
        for window in moved {
            guard let frame = WindowController.frame(of: window.element),
                  !WindowController.isMinimized(window.element) else { continue }
            frames[window.id] = frame
        }
        sceneUndo = SceneUndo(scene: scene, frames: frames)
    }

    /// Puts the windows of a scene that was on screen back, in its places and
    /// with its layout (T17, and what an undo does).
    private func restore(_ previous: Scene, announce: Bool) {
        presentLive(ids: previous.members, like: previous, announce: announce)
    }

    /// Resolves window ids against the live windows and presents them the way
    /// `like` had them placed. An id whose window is gone is simply skipped: a
    /// scene is not a promise that a window still exists.
    private func presentLive(ids: [String], like previous: Scene, announce: Bool) {
        let live = actionableWindows()
        var resolved: [(ref: WindowRef, window: ActionableWindow)] = []
        var arrangement: [String: CGRect] = [:]
        for id in ids {
            guard let window = live.first(where: { $0.id == id }) else { continue }
            resolved.append((WindowRef(identity: identity(for: window)), window))
            if let frame = previous.frames[window.id] { arrangement[window.id] = frame }
        }
        guard !resolved.isEmpty else {
            if announce {
                HUDController.shared.show("\(previous.title) — no window left",
                                          symbol: "exclamationmark.triangle.fill")
            }
            return
        }
        present(source: previous.source, title: previous.title,
                resolved: resolved, arrangement: arrangement,
                missing: 0, announce: announce)
    }

    /// Empties a group, keeping its number and name. Its remembered arrangement
    /// goes with the members: a refilled group starts from a clean slate.
    func clearGroup(slot: Int) {
        guard var group = groups[slot] else { return }
        group.members.removeAll()
        group.frames.removeAll()
        commit(group)
        if activeGroupSlot == slot { leaveGroup(announce: false) }
        HUDController.shared.show("\(group.displayName) cleared", symbol: "trash.fill")
    }

    func groupName(_ slot: Int) -> String {
        groups[slot]?.displayName ?? "Group \(slot)"
    }

    /// Renames a group. A blank name clears the custom one, so the group goes
    /// back to being called "Group N" — there is no way to end up with a name
    /// that is only whitespace.
    func renameGroup(slot: Int, name: String) {
        guard (1...9).contains(slot) else { return }
        var group = groups[slot] ?? WindowGroup(slot: slot)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = trimmed.isEmpty ? nil : trimmed
        guard group.name != newName else { return }
        group.name = newName
        commit(group)
    }

    /// Whether group `slot` has no saved members (missing counts as empty).
    func groupIsEmpty(_ slot: Int) -> Bool {
        groups[slot]?.members.isEmpty ?? true
    }

    /// Menu label for `slot`: the group's name plus its member count when it has
    /// any, so the menu says up front what a recall would lay out.
    func groupMenuLabel(_ slot: Int) -> String {
        let members = groups[slot]?.members.count ?? 0
        let name = groupName(slot)
        return members > 0 ? "\(name) · \(members)" : name
    }

    private func count(_ value: Int) -> String {
        "\(value) window\(value == 1 ? "" : "s")"
    }

    /// Asks the window to close by pressing its close button, so the app keeps
    /// control of any unsaved-changes prompt.
    func close(_ window: ActionableWindow) {
        if WindowController.close(window.element) {
            status = "\(window.appName) · close requested"
        } else {
            status = "⚠︎ \(window.appName) · this window cannot be closed"
        }
    }

    func minimize(_ window: ActionableWindow) {
        do {
            try WindowController.setMinimized(true, for: window.element)
            status = "\(window.appName) · minimized"
        } catch {
            status = "⚠︎ \(window.appName) · \(error.localizedDescription)"
        }
    }

    /// Quits the window's application. `terminate()` is unforced, so the app
    /// still shows its own unsaved-changes prompt. MakiDesk never quits itself.
    func quit(_ window: ActionableWindow) {
        guard window.pid != ProcessInfo.processInfo.processIdentifier else {
            status = "⚠︎ Not quitting MakiDesk itself"
            return
        }
        guard let app = NSRunningApplication(processIdentifier: window.pid) else {
            status = "⚠︎ \(window.appName) · no longer running"
            return
        }
        app.terminate()
        status = "\(window.appName) · quit requested"
    }

    private func activate(_ window: ActionableWindow) {
        NSRunningApplication(processIdentifier: window.pid)?.activate()
        WindowController.raise(window.element)
        WindowController.focus(window.element)
    }

    /// Puts `windows` above the rest. A tiling command only *moves* windows, so
    /// a window of the same app that is not in the set — the app's last used
    /// sibling, most often — would otherwise sit right on top of a tile and the
    /// layout would look half-empty. `topmost` (the first one by default) is
    /// raised last, so it ends up on top; with `focusFirst` the keyboard focus
    /// follows it, which is what a deliberate group recall wants.
    private func raiseToFront(_ windows: [ActionableWindow],
                              topmost: ActionableWindow? = nil,
                              focusFirst: Bool = false) {
        let top = topmost ?? windows.first
        for window in windows.reversed() where window.id != top?.id {
            WindowController.raise(window.element)
        }
        if let top { WindowController.raise(top.element) }
        if focusFirst, let top { WindowController.focus(top.element) }
    }

    // MARK: - Peek (T16)

    /// Whether a window is designated for the peek.
    var peekIsDesignated: Bool { peekRef != nil }

    /// Designates the frontmost window for the peek — or takes the designation
    /// away, when it already is that window. The designated window is **put
    /// away** (its app hidden when nothing else of that app is on screen,
    /// otherwise the window minimised), so the peek is the only way to see it,
    /// and it is brought back when the designation goes. Session only: nothing is
    /// written to disk and quitting forgets which window it was.
    func togglePeekDesignation() {
        if deferUntilFreshInventory({ [weak self] in guard let self else { return }; self.togglePeekDesignation() }) { return }
        guard let target = WindowController.frontmostWindow() else {
            status = "No controllable frontmost window"
            return
        }
        let ref = WindowRef(identity: identity(for: target))
        if let current = peekRef, current.matches(ref) {
            clearPeek()
            return
        }
        // One designated window at a time: the previous one comes back before
        // this one goes away, so a designation is never lost in the Dock.
        if peekRef != nil { clearPeek(announce: false) }
        peekRef = ref
        peekName = target.appName
        peekLastImage = nil            // never show the previous window's image

        guard let live = liveWindow(for: ref) else {
            HUDController.shared.show("Peek · \(target.appName) — hold ⌃⌥H", symbol: "eye.fill")
            return
        }
        let putAway = putAwayForPeek(live)
        HUDController.shared.show(
            "Peek · \(target.appName) — hold ⌃⌥H",
            symbol: putAway ? "eye.fill" : "exclamationmark.triangle.fill"
        )
    }

    /// Takes the window out of sight for the peek: the app is hidden when there
    /// is nothing else of it to keep, otherwise the window is minimised.
    /// Returns whether it went away.
    private func putAwayForPeek(_ window: ActionableWindow) -> Bool {
        let siblingsOnScreen = actionableWindows().contains {
            $0.pid == window.pid && $0.id != window.id && !$0.minimized
        }
        if !siblingsOnScreen, let app = NSRunningApplication(processIdentifier: window.pid), app.hide() {
            return true
        }
        return (try? WindowController.setMinimized(true, for: window.element)) != nil
    }

    /// Brings a designated window back on screen, where the peek left it: it is
    /// un-minimised, and its app shown again when the peek hid it. Nothing is
    /// moved and nothing takes the focus — a designation is not a command.
    private func restorePeekWindow(_ ref: WindowRef) {
        guard let window = liveWindow(for: ref) else { return }
        if NSRunningApplication(processIdentifier: window.pid)?.isHidden == true {
            NSRunningApplication(processIdentifier: window.pid)?.unhide()
        }
        if WindowController.isMinimized(window.element) {
            try? WindowController.setMinimized(false, for: window.element)
        }
    }

    /// Takes the designation away, brings the window back and closes the overlay.
    func clearPeek(announce: Bool = true) {
        if let ref = peekRef { restorePeekWindow(ref) }
        peekRef = nil
        peekName = nil
        peekLastImage = nil
        hidePeek()
        if announce {
            HUDController.shared.show("Peek cleared", symbol: "eye.slash")
        }
    }

    /// Shows the designated window while ⌃⌥H is held. Read-only: nothing is
    /// moved, activated or written, and the overlay takes no focus.
    func showPeek() {
        guard let ref = peekRef else {
            HUDController.shared.show("No window designated — ⌃⌥⌘P on the one to peek at",
                                      symbol: "eye.slash")
            return
        }
        guard peekHold.press() else { return }        // already showing (key repeat)
        peekCaptureGeneration &+= 1
        let captureGeneration = peekCaptureGeneration
        guard WindowCapture.isAuthorized else {
            peekHold.cancel()
            HUDController.shared.show("Peek needs Screen Recording",
                                      symbol: "exclamationmark.triangle.fill")
            return
        }
        armPeekWatchdog()
        armPeekEscape()

        let found = liveWindow(for: ref)
        if let found, isOnScreen(found) {
            // Nothing to peek at: the window is right there on screen.
            HUDController.shared.show("\(found.appName) · already on screen", symbol: "eye")
            return
        }
        guard let found else {
            // Closed since it was designated: the last image from this session,
            // badged, and the way to drop the designation in the HUD.
            if let image = peekLastImage {
                PeekPanel.shared.show(image: image, appName: peekName ?? ref.appName,
                                      badge: "Non più aperta")
            }
            HUDController.shared.show("Non più aperta — ⌃⌥⌘P drops the designation",
                                      symbol: "eye.slash")
            return
        }
        // The overlay appears at once with the app name; the image replaces the
        // placeholder as the live capture comes back.
        let appName = found.appName
        let pid = found.pid
        let frame = found.frame
        PeekPanel.shared.show(image: nil, appName: appName, badge: nil)
        peekCaptureTask?.cancel()
        peekCaptureTask = Task { @MainActor [weak self] in
            let image = await WindowCapture.captureWindow(pid: pid, near: frame)
            guard let self, self.peekHold.isHolding,
                  self.peekCaptureGeneration == captureGeneration else { return }
            guard let image else {
                PeekPanel.shared.show(image: nil, appName: appName, badge: "Non disponibile")
                return
            }
            self.peekLastImage = image
            PeekPanel.shared.show(image: image, appName: appName, badge: nil)
        }
    }

    /// Closes the overlay and disarms everything that was watching the hold.
    func hidePeek() {
        peekCaptureTask?.cancel()
        peekCaptureTask = nil
        peekCaptureGeneration &+= 1
        peekHold.release()
        peekWatchdog?.invalidate()
        peekWatchdog = nil
        shortcutManager?.unregister(peekEscapeKey)
        peekEscapeKey = nil
        PeekPanel.shared.hide()
    }

    /// The live window behind a ref, if it is still around — minimised, or owned
    /// by a hidden app, which is exactly what the peek is for.
    private func liveWindow(for ref: WindowRef) -> ActionableWindow? {
        let live = actionableWindows()
        let match = GroupMatcher.match([ref], to: live.map { identity(for: $0) })
        guard let index = match.first ?? nil, live.indices.contains(index) else { return nil }
        return live[index]
    }

    /// Whether a window really is visible now: a normal state (not minimised)
    /// and its app not hidden.
    private func isOnScreen(_ window: ActionableWindow) -> Bool {
        guard window.state == .normal else { return false }
        return !(NSRunningApplication(processIdentifier: window.pid)?.isHidden ?? false)
    }

    /// Closes a hold whose release never came — the key let go while another app
    /// held it, a stuck modifier. Without it the overlay would sit there with no
    /// key down, looking like a window that cannot be dismissed.
    private func armPeekWatchdog() {
        peekWatchdog?.invalidate()
        peekWatchdog = Timer.scheduledTimer(withTimeInterval: peekHold.holdWatchdog + 0.5,
                                            repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.peekHold.hasExpired else { return }
                self.status = "Peek closed (the key release was lost)"
                self.hidePeek()
            }
        }
    }

    /// Esc closes the peek early. Registered only while the overlay is up: the
    /// key belongs to whatever else is on screen the rest of the time.
    private func armPeekEscape() {
        guard peekEscapeKey == nil else { return }
        peekEscapeKey = shortcutManager?.registerEscape { [weak self] in self?.hidePeek() }
    }

    // MARK: - Screen changes (B6)

    private func handleScreenChange() {
        hidePeek()
        WindowIndex.shared.refreshAsync { [weak self] discovered in
            guard let self else { return }
            self.rebuildModel(from: discovered, announce: false)
            self.recallOffscreenWindows()
            if self.showMiniMap { self.showMiniMapIfEnabled() }
            WindowOutlineController.shared.refresh()
        }
    }

    /// Pulls windows left on a detached monitor back into the primary screen.
    func recallOffscreenWindows() {
        let visibleFrames = NSScreen.screens.map { WindowController.axVisibleFrame(for: $0) }
        guard let primary = visibleFrames.first else { return }
        var moved = 0
        for index in windows.indices {
            let frame = CGRect(x: windows[index].x, y: windows[index].y,
                               width: windows[index].width, height: windows[index].height)
            guard frame.width > 0, frame.height > 0 else { continue }
            let onScreen = visibleFrames.contains { visible in
                let hit = visible.intersection(frame)
                return hit.width >= 2 && hit.height >= 2
            }
            if onScreen { continue }
            guard let element = elements[windows[index].id],
                  let identity = frameIdentity(for: windows[index]) else { continue }
            let width = min(frame.width, primary.width)
            let height = min(frame.height, primary.height)
            let x = min(max(frame.minX, primary.minX), primary.maxX - width)
            let y = min(max(frame.minY, primary.minY), primary.maxY - height)
            let rect = CGRect(x: x, y: y, width: width, height: height)
            WindowController.setFrameAsync(rect, for: element, identity: identity)
            rememberArrangement(rect, ofModelWindowAt: index)
            windows[index].x = rect.minX
            windows[index].y = rect.minY
            windows[index].width = rect.width
            windows[index].height = rect.height
            moved += 1
        }
        if moved > 0 { status = "Recalled \(moved) off-screen windows" }
    }

    // MARK: - Auto layout (golden spiral)

    /// Arranges the selected windows (or all of them when nothing is selected)
    /// into the golden-spiral positions, largest slot to the window with the most
    /// visual content. The score comes from asynchronous, downscaled captures so
    /// the main thread is never blocked. The spiral is capped at
    /// `TilingEngine.maxGoldenSpiralSlots` so the last slots never become sliver
    /// thin; any windows beyond the cap stay where they are.
    func autoLayout(selection: [ActionableWindow] = []) {
        if deferUntilFreshInventory({ [weak self] in guard let self else { return }; self.autoLayout(selection: selection) }) { return }
        clearPendingLayout()
        frameCommandEpoch &+= 1
        let area = WindowController.axVisibleFrame(for: NSScreen.main)
        let candidates = selection.isEmpty ? arrangeableWindows() : validatedSelection(selection)
        guard !candidates.isEmpty else { return }
        let slots = TilingEngine.goldenSpiralSlots(area: area, count: candidates.count)
        guard !slots.isEmpty else { return }
        let gapHalf = gap / 2

        let requests = candidates.compactMap { window -> WindowCapture.Request? in
            guard let id = window.windowID else { return nil }
            return WindowCapture.Request(key: window.id, windowID: id)
        }
        let commandEpoch = frameCommandEpoch

        contentAnalysisTask?.cancel()
        contentAnalysisTask = Task { @MainActor in
            let scores = await WindowCapture.scores(for: requests, maxDimension: 400)
            guard self.frameCommandEpoch == commandEpoch else { return }
            let scored = Self.byContentScore(candidates, scores: scores)
            Self.logContentOrder(scored, scores: scores, requested: requests.count)
            for (index, position) in slots.enumerated() where index < scored.count {
                let target = self.windowInfo(for: scored[index])
                self.applyFrame(position.insetBy(dx: gapHalf, dy: gapHalf).integral,
                                to: target, reason: "auto layout (golden spiral)")
            }
            self.raiseToFront(scored)
            if scored.count > slots.count {
                self.status = "Golden spiral placed \(slots.count) of \(scored.count) windows (limit \(slots.count))"
            }
        }
    }

    /// Orders windows by how much there is to look at, most first: the capture
    /// score when there is one, otherwise the window area — so with no Screen
    /// Recording permission the biggest window still wins the widest slot.
    /// Ties fall back to area and then to the window id, so the same set always
    /// produces the same order (a recall that runs twice must not shuffle).
    /// Pure, so the ordering is unit-tested without capturing anything.
    static func byContentScore(_ windows: [ActionableWindow], scores: [String: Double]) -> [ActionableWindow] {
        func area(_ window: ActionableWindow) -> Double { Double(window.frame.width * window.frame.height) }
        func score(_ window: ActionableWindow) -> Double { scores[window.id] ?? area(window) }
        return windows.sorted { lhs, rhs in
            let left = score(lhs), right = score(rhs)
            if left != right { return left > right }
            let leftArea = area(lhs), rightArea = area(rhs)
            if leftArea != rightArea { return leftArea > rightArea }
            return lhs.id < rhs.id
        }
    }

    /// Writes the golden order and the numbers behind it to the unified log, so
    /// the choice can be checked against what is actually on screen:
    ///
    ///     log show --last 10m --predicate 'process == "MakiDesk"'
    ///
    /// `requested` is how many windows we asked a score for; fewer scores mean
    /// some window fell back to its area (no Screen Recording permission, or a
    /// window that is not on this desktop).
    private static func logContentOrder(_ windows: [ActionableWindow], scores: [String: Double], requested: Int) {
        let parts = windows.enumerated().map { index, window -> String in
            let area = Int(window.frame.width * window.frame.height)
            let score = scores[window.id].map { String(format: "%.1f", $0) } ?? "area \(area)"
            return "#\(index + 1) \(window.appName) \(score)"
        }
        NSLog("MakiDesk golden order (%d/%d measured): %@",
              scores.count, requested, parts.joined(separator: " | "))
    }

    // MARK: - Intelligent layout (T18)

    /// Asks the advisor which of the two presets suits the windows and either
    /// offers the suggestion or applies it, per `layoutAsksFirst`. The measure
    /// comes from the same asynchronous captures the golden spiral uses, so the
    /// main thread is never blocked; without Screen Recording there is no
    /// measure and the advisor falls back to the grid.
    ///
    /// Asking twice is how an offer is accepted: while one is waiting, calling
    /// this again applies it rather than computing a new one, and so does
    /// `acceptPendingLayout()` from the menu.
    func suggestLayout(selection: [ActionableWindow] = []) {
        if deferUntilFreshInventory({ [weak self] in guard let self else { return }; self.suggestLayout(selection: selection) }) { return }
        if pendingLayout != nil {
            frameCommandEpoch &+= 1
            acceptPendingLayout()
            return
        }
        frameCommandEpoch &+= 1
        let set = selection.isEmpty ? arrangeableSet() : ArrangeableSet(windows: validatedSelection(selection))
        let candidates = set.windows
        guard !candidates.isEmpty else {
            HUDController.shared.show("No windows in view to arrange", symbol: "rectangle.on.rectangle.slash")
            return
        }
        let requests = candidates.compactMap { window -> WindowCapture.Request? in
            guard let id = window.windowID else { return nil }
            return WindowCapture.Request(key: window.id, windowID: id)
        }
        let subjects = candidates.map { layoutSubject(for: $0) }
        let commandEpoch = frameCommandEpoch

        contentAnalysisTask?.cancel()
        contentAnalysisTask = Task { @MainActor in
            let scores = await WindowCapture.scores(for: requests, maxDimension: 400)
            guard self.frameCommandEpoch == commandEpoch else { return }
            let measure = ContentMeasure(scores: scores)
            let advice = LayoutAdvisor.advise(subjects, measure: measure, priors: self.layoutPriors)
            Self.logLayoutAdvice(advice, measure: measure, requested: requests.count)
            if self.layoutAsksFirst {
                self.offer(advice, to: set)
            } else {
                self.apply(advice, to: set)
            }
        }
    }

    /// Applies the suggestion the advisor made, when one is still waiting (T18).
    func acceptPendingLayout() {
        guard let advice = pendingLayout else { return }
        let set = pendingLayoutSet
        clearPendingLayout()
        apply(advice, to: set)
    }

    /// Takes back the offer, without arranging anything.
    func dismissPendingLayout() {
        guard pendingLayout != nil else { return }
        clearPendingLayout()
    }

    private func clearPendingLayout() {
        pendingLayoutTimer?.invalidate()
        pendingLayoutTimer = nil
        pendingLayout = nil
        pendingLayoutSet = ArrangeableSet()
    }

    /// Shows what the advisor proposes, with the reason, and lets the offer
    /// lapse. Running the command again inside that time accepts it — the HUD is
    /// passive on purpose, so this is the one way to say yes without a click
    /// landing on a window that must not take focus.
    private func offer(_ advice: LayoutAdvice, to set: ArrangeableSet) {
        pendingLayout = advice
        pendingLayoutSet = set
        pendingLayoutTimer?.invalidate()
        pendingLayoutTimer = Timer.scheduledTimer(withTimeInterval: Self.layoutOfferSeconds, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.clearPendingLayout() }
        }
        HUDController.shared.show(
            "Suggested: \(advice.layout.label) · \(Self.layoutSummary(set))\n\(advice.reason)\nRun Auto again to apply",
            symbol: "wand.and.stars",
            overrideDuration: Self.layoutOfferSeconds
        )
    }

    /// How long a suggestion waits to be accepted (T18).
    static let layoutOfferSeconds: TimeInterval = 8

    /// Arranges the candidate windows the way `advice` says, the window the
    /// advisor picked in the largest slot. Every move goes through `applyFrame`,
    /// so the arrangement it makes is the one a recall restores (T15).
    private func apply(_ advice: LayoutAdvice, to set: ArrangeableSet) {
        let windows = set.windows
        guard !windows.isEmpty else { return }
        let area = WindowController.axVisibleFrame(for: NSScreen.main)
        var ordered = windows
        let frames: [CGRect]

        if advice.layout == .content, let weights = advice.weights {
            ordered = Self.orderedByWeight(windows, weights: weights)
            frames = TilingEngine.frames(for: .content, count: ordered.count, in: area, gap: gap,
                                         weights: ordered.map { weights[$0.id] ?? 1 })
        } else {
            if let lead = advice.leadID, let index = windows.firstIndex(where: { $0.id == lead }) {
                ordered.remove(at: index)
                ordered.insert(windows[index], at: 0)
            }
            frames = TilingEngine.frames(for: advice.layout, count: windows.count, in: area, gap: gap)
        }
        guard !frames.isEmpty else { return }
        for (index, frame) in frames.enumerated() where index < ordered.count {
            applyFrame(frame, to: windowInfo(for: ordered[index]),
                       reason: "auto layout (\(advice.layout.label.lowercased()))")
        }
        raiseToFront(ordered)
        HUDController.shared.show("\(advice.layout.label) · \(Self.layoutSummary(set))\n\(advice.reason)",
                                  symbol: "wand.and.stars")
    }

    /// Heaviest first, stable on the window id so the same set and weights give
    /// the same frames (T30).
    static func orderedByWeight(_ windows: [ActionableWindow],
                                weights: [String: Double]) -> [ActionableWindow] {
        windows.sorted { lhs, rhs in
            let left = weights[lhs.id] ?? 0, right = weights[rhs.id] ?? 0
            if left != right { return left > right }
            return lhs.id < rhs.id
        }
    }

    /// Everything the advisor may look at, gathered without reading the content:
    /// the app, the bundle, the title and how big the window is.
    private func layoutSubject(for window: ActionableWindow) -> LayoutSubject {
        LayoutSubject(
            id: window.id,
            appName: window.appName,
            bundleId: NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier,
            title: window.title,
            area: Double(window.frame.width * window.frame.height)
        )
    }

    /// Writes what the advisor decided, and why, to the unified log so a choice
    /// can be checked against what is on screen:
    ///
    ///     log show --last 10m --predicate 'process == "MakiDesk"'
    private static func logLayoutAdvice(_ advice: LayoutAdvice, measure: ContentMeasure, requested: Int) {
        NSLog("MakiDesk layout advice (%d/%d measured): %@ — %@",
              measure.scores.count, requested, advice.layout.label, advice.reason)
    }

    // MARK: - Content-weighted layout (T30)

    /// Lays the selected windows (or every window in view) out with areas
    /// proportional to their weight: the app kind's prior times a factor from
    /// the same content measure the golden spiral uses. Needs three windows;
    /// without Screen Recording it still works, from the priors alone.
    func contentLayout(selection: [ActionableWindow] = []) {
        if deferUntilFreshInventory({ [weak self] in guard let self else { return }; self.contentLayout(selection: selection) }) { return }
        clearPendingLayout()
        frameCommandEpoch &+= 1
        let set = selection.isEmpty ? arrangeableSet() : ArrangeableSet(windows: validatedSelection(selection))
        let targets = set.windows
        guard targets.count >= 3 else {
            status = "Content layout needs at least 3 windows"
            HUDController.shared.show("Content needs at least 3 windows",
                                      symbol: "rectangle.3.group")
            return
        }
        let area = WindowController.axVisibleFrame(for: NSScreen.main)
        let requests = targets.compactMap { window -> WindowCapture.Request? in
            guard let id = window.windowID else { return nil }
            return WindowCapture.Request(key: window.id, windowID: id)
        }
        let subjects = targets.map { layoutSubject(for: $0) }
        let commandEpoch = frameCommandEpoch

        contentAnalysisTask?.cancel()
        contentAnalysisTask = Task { @MainActor in
            let scores = await WindowCapture.scores(for: requests, maxDimension: 400)
            guard self.frameCommandEpoch == commandEpoch else { return }
            let measure = ContentMeasure(scores: scores)
            let weights = LayoutAdvisor.weights(subjects, measure: measure, priors: self.layoutPriors)
            let ordered = Self.orderedByWeight(targets, weights: weights)
            let frames = TilingEngine.frames(for: .content, count: ordered.count, in: area, gap: self.gap,
                                             weights: ordered.map { weights[$0.id] ?? 1 })
            guard frames.count == ordered.count else { return }
            for (index, window) in ordered.enumerated() {
                self.applyFrame(frames[index], to: self.windowInfo(for: window),
                                reason: "content layout")
            }
            if !selection.isEmpty { self.raiseToFront(ordered) }
            self.status = "Content layout: \(ordered.count) windows"
            HUDController.shared.show("Content · \(Self.layoutSummary(set))",
                                      symbol: "rectangle.3.group")
            Self.logContentWeights(ordered, weights: weights, scores: scores,
                                   requested: requests.count)
        }
    }

    /// Writes the weights to the unified log, so a treemap can be checked
    /// against what is actually on screen:
    ///
    ///     log show --last 10m --predicate 'process == "MakiDesk"'
    private static func logContentWeights(_ windows: [ActionableWindow],
                                          weights: [String: Double],
                                          scores: [String: Double],
                                          requested: Int) {
        let parts = windows.enumerated().map { index, window -> String in
            let weight = weights[window.id].map { String(format: "%.2f", $0) } ?? "-"
            let score = scores[window.id].map { String(format: "%.1f", $0) } ?? "no score"
            return "#\(index + 1) \(window.appName) w=\(weight) s=\(score)"
        }
        NSLog("MakiDesk content weights (%d/%d measured): %@",
              scores.count, requested, parts.joined(separator: " | "))
    }

    // MARK: - Direct manipulation (menu)

    func moveSelected(dx: Double, dy: Double, scale: CGFloat) {
        guard let id = selectedID, let index = windows.firstIndex(where: { $0.id == id }) else { return }
        move(windowAt: index, to: CGPoint(x: windows[index].x + dx / scale, y: windows[index].y + dy / scale))
    }

    func moveSelected(to point: CGPoint) {
        guard let id = selectedID, let index = windows.firstIndex(where: { $0.id == id }) else { return }
        move(windowAt: index, to: point)
    }

    func alignToGrid(size: Double, gap: Double) {
        let spacing = max(1, size + gap)
        for index in windows.indices {
            let x = (windows[index].x / spacing).rounded() * spacing
            let y = (windows[index].y / spacing).rounded() * spacing
            move(windowAt: index, to: CGPoint(x: x, y: y))
        }
        status = "Aligned \(windows.count) windows to \(Int(size)) px grid"
    }

    /// Tiles the selected windows — or every window **in view**, when nothing is
    /// selected — in a grid sized to the number of windows being placed, not to
    /// the total. Minimised, hidden and full-screen windows are left where they
    /// are (T18/T24), so a tile is never handed to a window nobody can see; the
    /// feedback says how many were placed and why there were not more.
    func tileOnScreen(gap: Double, selection: [ActionableWindow] = []) {
        if deferUntilFreshInventory({ [weak self] in guard let self else { return }; self.tileOnScreen(gap: gap, selection: selection) }) { return }
        // An explicit layout command settles the question: nothing the advisor
        // proposed is still waiting to be accepted.
        clearPendingLayout()
        let area = WindowController.axVisibleFrame(for: NSScreen.main)
        let set = selection.isEmpty ? arrangeableSet() : ArrangeableSet(windows: validatedSelection(selection))
        let targets = set.windows
        guard !targets.isEmpty else {
            HUDController.shared.show("No windows in view to arrange", symbol: "rectangle.on.rectangle.slash")
            return
        }
        let frames = TilingEngine.frames(for: .grid, count: targets.count, in: area, gap: gap)
        for (index, window) in targets.enumerated() where index < frames.count {
            // *Tile* is the explicit way to re-dispose: the arrangement it just
            // made is what a recall restores from now on (T15).
            applyFrame(frames[index], to: windowInfo(for: window), reason: "tiled")
        }
        if !selection.isEmpty { raiseToFront(targets) }
        status = "Tiled \(min(targets.count, frames.count)) windows with \(Int(gap)) px gap"
        HUDController.shared.show("Grid · \(Self.layoutSummary(set))", symbol: "square.grid.3x3.fill")
    }

    private func move(windowAt index: Int, to point: CGPoint) {
        guard index < windows.count else { return }
        windows[index].x = point.x
        windows[index].y = point.y
        guard let element = elements[windows[index].id],
              let identity = frameIdentity(for: windows[index]) else { return }
        // Serialized with keyboard animations for the same window; the write
        // happens off the pointer's event path.
        WindowController.setPositionAsync(point, for: element, identity: identity)
        // A drag on the mini map is a manual move like any other: it counts as
        // where the group's window is now (T15).
        rememberArrangement(CGRect(x: point.x, y: point.y,
                                   width: windows[index].width, height: windows[index].height),
                            ofModelWindowAt: index)
    }

    // MARK: - Colors

    /// Order in which apps first received a colour this session. Assigning in
    /// first-seen order (instead of hashing to a random hue) lets the hues be
    /// evenly spaced, so open apps never end up with near-identical tones.
    @ObservationIgnored private var appColorOrder: [String: Int] = [:]

    private func tint(for appName: String) -> String {
        let palette = ["blue", "purple", "green", "orange", "pink"]
        return palette[Self.stableIndex(appName, count: palette.count)]
    }

    /// A per-app colour. Hues are assigned in first-seen order on an evenly
    /// spaced wheel derived from the theme's accent, so **any two open apps are
    /// at least ~30° apart** (no more clusters of similar yellows). A second
    /// tier (lighter/desaturated) covers the rare case of more than 12 apps.
    func color(for appName: String) -> NSColor {
        let base = (NSColor(theme.accent).usingColorSpace(.deviceRGB)) ?? .systemBlue
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let hueSteps = 12
        let index = colorIndex(for: appName)
        let slot = index % hueSteps
        let tier = (index / hueSteps) % 2
        let shifted = (hue + CGFloat(slot) / CGFloat(hueSteps)).truncatingRemainder(dividingBy: 1)
        let baseSaturation = min(1, max(0.55, saturation))
        let baseBrightness = min(1, max(0.68, brightness))
        // Tier 1 is pale/faded, clearly distinct from tier 0 at the same hue.
        let saturationOut = tier == 0 ? baseSaturation : baseSaturation * 0.6
        let brightnessOut = tier == 0 ? baseBrightness : min(1, baseBrightness * 1.2)
        return NSColor(hue: shifted, saturation: saturationOut, brightness: brightnessOut, alpha: 1)
    }

    /// Stable per-app slot, handed out in first-seen order.
    private func colorIndex(for appName: String) -> Int {
        if let existing = appColorOrder[appName] { return existing }
        let index = appColorOrder.count
        appColorOrder[appName] = index
        return index
    }

    private static func stableIndex(_ text: String, count: Int) -> Int {
        var hash = 5381
        for scalar in text.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
        return abs(hash) % max(1, count)
    }

    // MARK: - Mini-map

    private func showMiniMapIfEnabled(motionFrom: [UUID: CGRect] = [:]) {
        guard showMiniMap else { return }
        let focusedID = mostRecentFocusedWindowID.flatMap { focusedSystemID in
            windows.first(where: { $0.systemID == focusedSystemID })?.id
        }
        MiniMapController.shared.show(
            windows: windows,
            highlightedIDs: Set(focusedID.map { [$0] } ?? []),
            motionFrom: motionFrom
        )
    }

    private func showMiniMapIfEnabled(for target: WindowController.WindowInfo, frame: CGRect) {
        guard showMiniMap else { return }
        var mapWindows = windows
        var highlightedID: UUID?
        if let index = mapWindows.firstIndex(where: { $0.systemID == target.id }) {
            highlightedID = mapWindows[index].id
            mapWindows[index].x = frame.minX
            mapWindows[index].y = frame.minY
            mapWindows[index].width = frame.width
            mapWindows[index].height = frame.height
        } else if let index = matchingIndex(for: target) {
            highlightedID = mapWindows[index].id
            mapWindows[index].x = frame.minX
            mapWindows[index].y = frame.minY
            mapWindows[index].width = frame.width
            mapWindows[index].height = frame.height
        } else {
            let mapped = WorkspaceWindow(title: target.title, appName: target.appName,
                                         x: frame.minX, y: frame.minY,
                                         width: frame.width, height: frame.height,
                                         systemID: target.id)
            highlightedID = mapped.id
            mapWindows.append(mapped)
        }
        MiniMapController.shared.show(windows: mapWindows, highlightedIDs: Set(highlightedID.map { [$0] } ?? []))
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
