import Foundation
import AppKit
import ApplicationServices
import SwiftUI
import Observation
import os

let orbitLog = Logger(subsystem: "com.orbitdesk.app", category: "orbit")

/// A window the switcher / search can act on.
struct ActionableWindow: Identifiable {
    let id: String
    let title: String
    let appName: String
    let frame: CGRect
    let pid: pid_t
    let minimized: Bool
    let element: AXUIElement
    let color: NSColor
}

@Observable
final class WorkspaceStore {
    var windows: [WorkspaceWindow] = []
    var selectedID: UUID?
    var status = "Starting…"
    var isRealMode = false
    var accessibilityTrusted = AXIsProcessTrusted()
    var shortcutsRegistered = 0
    var shortcutsBlocked = 0
    var gap = (UserDefaults.standard.object(forKey: "windowGap") == nil
        ? 12
        : UserDefaults.standard.double(forKey: "windowGap")).clamped(to: 0...80)
    var showMiniMap = UserDefaults.standard.object(forKey: "showMiniMap") as? Bool ?? true
    var showPreview = UserDefaults.standard.object(forKey: "showPreview") as? Bool ?? true
    var miniMapPosition = PalettePosition(rawValue: UserDefaults.standard.string(forKey: "miniMapPosition") ?? "") ?? .topRight
    var themeID = UserDefaults.standard.string(forKey: "themeID") ?? "catppuccin-mocha"
    var overlayScale = UserDefaults.standard.object(forKey: "overlayScale") as? Double ?? 1.0
    var overlayOpacity = UserDefaults.standard.object(forKey: "overlayOpacity") as? Double ?? 0.94
    var paletteScale = UserDefaults.standard.object(forKey: "paletteScale") as? Double ?? 1.0
    var paletteOpacity = UserDefaults.standard.object(forKey: "paletteOpacity") as? Double ?? 0.9
    var setupCompleted = UserDefaults.standard.bool(forKey: "setupCompleted")

    var theme: PaletteTheme { PaletteTheme.named(themeID) }

    static let shared = WorkspaceStore()

    @ObservationIgnored private var elements: [UUID: AXUIElement] = [:]
    @ObservationIgnored private var shortcutManager: ShortcutManager?
    @ObservationIgnored private var trustTimer: Timer?
    @ObservationIgnored private var focusTimer: Timer?
    @ObservationIgnored private var frameTimer: Timer?
    @ObservationIgnored private var lastFrontmostKey: String?
    @ObservationIgnored private var promptedForTrust = false

    // Registers shortcuts and keeps permission state live; no manual "connect" needed.
    func start() {
        guard shortcutManager == nil else { return }
        startGlobalShortcuts()
        checkTrust()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.checkTrust()
        }
        // Reflect the active window on the mini-map whenever focus changes.
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.checkFrontmostChange()
        }
    }

    private func checkFrontmostChange() {
        guard showMiniMap, accessibilityTrusted else { return }
        guard let target = WindowController.frontmostWindow() else { return }
        let key = "\(target.id)|\(target.title)"
        guard key != lastFrontmostKey else { return }
        lastFrontmostKey = key
        showMiniMapIfEnabled(for: target, frame: target.frame)
    }

    func checkTrust() {
        let trusted = AXIsProcessTrusted()
        let changed = trusted != accessibilityTrusted
        accessibilityTrusted = trusted
        if changed { orbitLog.notice("trust changed -> \(trusted, privacy: .public)") }
        if trusted {
            if changed || !isRealMode { refreshRealWindows() }
        } else {
            isRealMode = false
            if !promptedForTrust {
                promptedForTrust = true
                _ = WindowController.requestAccessibilityPermission()
            }
            status = "Accessibility not granted · open Settings"
        }
    }

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let folder = base.appendingPathComponent("OrbitDesk", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder,
                                                 withIntermediateDirectories: true)
        return folder.appendingPathComponent("workspace.json")
    }

    func save() {
        do {
            let data = try JSONEncoder.pretty.encode(windows)
            try data.write(to: fileURL, options: .atomic)
            status = "Workspace saved"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    func load() {
        do {
            let data = try Data(contentsOf: fileURL)
            windows = try JSONDecoder().decode([WorkspaceWindow].self, from: data)
            if !windows.contains(where: { $0.id == selectedID }) {
                selectedID = windows.first?.id
            }
            status = "Workspace loaded"
        } catch {
            status = "No saved workspace yet"
        }
    }

    func openAccessibilitySettings() { WindowController.openAccessibilitySettings() }

    func startGlobalShortcuts() {
        let manager = ShortcutManager { [weak self] action in
            self?.applyShortcut(action)
        }
        manager.start()
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
    }

    func updateMiniMapPosition(_ value: PalettePosition) {
        miniMapPosition = value
        UserDefaults.standard.set(value.rawValue, forKey: "miniMapPosition")
    }

    func updateTheme(_ value: String) {
        themeID = value
        UserDefaults.standard.set(value, forKey: "themeID")
    }

    func updateOverlayScale(_ value: Double) {
        overlayScale = value.clamped(to: 0.7...1.6)
        UserDefaults.standard.set(overlayScale, forKey: "overlayScale")
    }

    func updateOverlayOpacity(_ value: Double) {
        overlayOpacity = value.clamped(to: 0.4...1.0)
        UserDefaults.standard.set(overlayOpacity, forKey: "overlayOpacity")
    }

    func updatePaletteScale(_ value: Double) {
        paletteScale = value.clamped(to: 0.8...1.4)
        UserDefaults.standard.set(paletteScale, forKey: "paletteScale")
    }

    func updatePaletteOpacity(_ value: Double) {
        paletteOpacity = value.clamped(to: 0.5...1.0)
        UserDefaults.standard.set(paletteOpacity, forKey: "paletteOpacity")
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
        NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        bringSettingsToFront()
    }

    /// Brings the Settings window to the front and keeps it above other windows.
    func bringSettingsToFront() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            for window in NSApp.windows where window.isVisible && !(window is NSPanel) {
                window.level = .floating
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: - Shortcuts

    func applyShortcut(_ action: WindowController.ShortcutAction) {
        let trusted = AXIsProcessTrusted()
        accessibilityTrusted = trusted
        orbitLog.notice("shortcut \(String(describing: action), privacy: .public) trusted=\(trusted, privacy: .public)")
        guard trusted else {
            status = "Accessibility not granted · open Settings"
            return
        }
        switch action {
        case .switchWindows:
            WindowPalette.shared.show(store: self, mode: .browse, backwards: false)
            return
        case .switchWindowsBack:
            WindowPalette.shared.show(store: self, mode: .browse, backwards: true)
            return
        case .searchWindows:
            WindowPalette.shared.show(store: self, mode: .search)
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
        let screen = WindowController.screen(forAXFrame: target.frame)
        let gapHalf = gap / 2
        let entry = matchingIndex(for: target)
        let visible = WindowController.axVisibleFrame(for: screen)
        let area = availableArea(visible, excluding: entry)
        let current = target.frame.insetBy(dx: -gapHalf, dy: -gapHalf)

        switch action {
        case .minimize:
            setMinimized(true, target: target)
            focusNextStack(after: target)
            return
        case .toggleFullScreen:
            let on = !WindowController.isFullScreen(target.element)
            WindowController.setFullScreen(on, for: target.element)
            status = "\(target.appName) · \(on ? "full screen" : "windowed")"
            return
        default:
            break
        }

        if let outcome = ladderStep(action, area: area, current: current) {
            switch outcome {
            case .frame(let logical):
                apply(logical: logical, target: target, entry: entry, gapHalf: gapHalf, action: action)
            case .park(let anchor):
                park(anchor: anchor, target: target, entry: entry, visible: visible)
            case .minimize:
                setMinimized(true, target: target)
            }
            return
        }

        let key = "\(target.appName)|\(target.title)"
        guard let logical = logicalFrame(for: action, area: area, current: current, key: key) else { return }
        apply(logical: logical, target: target, entry: entry, gapHalf: gapHalf, action: action)
    }

    private enum LadderOutcome {
        case frame(CGRect)
        case park(TilingEngine.Anchor)
        case minimize
    }

    /// Steps the ladder one position. At the start/end extremes the window is
    /// parked off the side (horizontal) or shrunk to the minimum / minimised
    /// (vertical).
    private func ladderStep(
        _ action: WindowController.ShortcutAction,
        area: CGRect,
        current: CGRect
    ) -> LadderOutcome? {
        guard let (axis, direction) = ladderAxisAndDirection(for: action) else { return nil }
        let orthogonal = orthogonalRange(of: current, axis: axis)
        let states = TilingEngine.ladderRects(area: area, axis: axis, orthogonal: orthogonal)
        let slot = slotIndex(for: current, in: area, axis: axis, states: states)
        let next = max(-1, min(states.count, slot + direction))
        if next < 0 {
            switch axis {
            case .horizontal: return .park(.start)
            case .vertical: return .frame(minHeightRect(area: area, orthogonal: orthogonal))
            }
        }
        if next >= states.count {
            switch axis {
            case .horizontal: return .park(.end)
            case .vertical: return .minimize
            }
        }
        return .frame(states[next])
    }

    /// The visible area minus the strip reserved by any window parked on the
    /// left or right, so the rest of the windows align inside what's left.
    private func availableArea(_ visible: CGRect, excluding entry: Int?) -> CGRect {
        let strip = WindowController.reservedStrip
        var left: CGFloat = 0
        var right: CGFloat = 0
        for (index, window) in windows.enumerated() where index != entry {
            let frame = CGRect(x: window.x, y: window.y, width: window.width, height: window.height)
            if frame.minX < visible.minX - 2, frame.maxX <= visible.minX + strip + 4 {
                left = max(left, frame.maxX - visible.minX)
            }
            if frame.maxX > visible.maxX + 2, frame.minX >= visible.maxX - strip - 4 {
                right = max(right, visible.maxX - frame.minX)
            }
        }
        return CGRect(x: visible.minX + left, y: visible.minY,
                      width: max(1, visible.width - left - right), height: visible.height)
    }

    private func minHeightRect(area: CGRect, orthogonal: ClosedRange<CGFloat>) -> CGRect {
        let height = min(TilingEngine.minimumHeight, area.height)
        return CGRect(x: orthogonal.lowerBound, y: area.minY,
                      width: orthogonal.upperBound - orthogonal.lowerBound, height: height)
    }

    /// Slot of the window: -1 or `states.count` mean parked / at the minimum.
    private func slotIndex(
        for window: CGRect,
        in area: CGRect,
        axis: TilingEngine.Axis,
        states: [CGRect]
    ) -> Int {
        switch axis {
        case .horizontal:
            let center = window.midX
            if center < area.minX { return -1 }
            if center >= area.maxX { return states.count }
            return TilingEngine.nearestIndex(to: window, among: states)
        case .vertical:
            if window.height <= TilingEngine.minimumHeight + 2 { return -1 }
            if window.midY >= area.maxY { return states.count }
            return TilingEngine.nearestIndex(to: window, among: states)
        }
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
        case .toggleFullScreen, .minimize, .switchWindows, .switchWindowsBack, .searchWindows:
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

    private func centeredFrame(area: CGRect, size: CGSize) -> CGRect {
        let width = min(size.width, area.width)
        let height = min(size.height, area.height)
        return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }

    private func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 12 && abs(a.minY - b.minY) < 12
            && abs(a.width - b.width) < 12 && abs(a.height - b.height) < 12
    }

    /// Focuses the next window behind `target` in the stacking order.
    private func focusNextStack(after target: WindowController.WindowInfo) {
        let all = WindowController.discoverWindows()
        guard !all.isEmpty else { return }
        let next: WindowController.WindowInfo
        if let index = all.firstIndex(where: { $0.appName == target.appName && $0.title == target.title }) {
            next = all[(index + 1) % all.count]
        } else {
            next = all[0]
        }
        NSRunningApplication(processIdentifier: next.pid)?.activate()
        WindowController.raise(next.element)
        WindowController.focus(next.element)
    }

    private func apply(
        logical: CGRect,
        target: WindowController.WindowInfo,
        entry: Int?,
        gapHalf: CGFloat,
        action: WindowController.ShortcutAction
    ) {
        let frame = logical.insetBy(dx: gapHalf, dy: gapHalf).integral
        if let entry {
            windows[entry].x = frame.minX
            windows[entry].y = frame.minY
            windows[entry].width = frame.width
            windows[entry].height = frame.height
        }
        animateFrame(to: frame, element: target.element) { [weak self] in
            guard let self else { return }
            // Warn when the app refused the requested size (min-size constraints).
            if let actual = WindowController.frame(of: target.element), !self.framesMatch(actual, frame) {
                self.status = "⚠︎ \(target.appName) · size limited by the app"
            } else {
                self.status = "\(target.appName) · \(self.label(for: action))"
            }
            self.showMiniMapIfEnabled(for: target, frame: frame)
            // Show the parking zones that are occupied so it's clear they can't
            // be used.
            // Flash only the parking side the window actually moved against.
            let visible = WindowController.axVisibleFrame(for: WindowController.screen(forAXFrame: frame))
            let strips = self.parkedStrips(in: visible).filter { strip in
                strip.midX < visible.midX
                    ? frame.minX <= visible.minX + strip.width + 6
                    : frame.maxX >= visible.maxX - strip.width - 6
            }
            if !strips.isEmpty { ParkedZoneOverlay.shared.flash(strips: strips) }
        }
    }

    /// The on-screen strip occupied by each parked window.
    private func parkedStrips(in visible: CGRect) -> [CGRect] {
        let strip = WindowController.reservedStrip
        var result: [CGRect] = []
        for window in windows {
            let frame = CGRect(x: window.x, y: window.y, width: window.width, height: window.height)
            if frame.minX < visible.minX - 2, frame.maxX <= visible.minX + strip + 4 {
                result.append(CGRect(x: visible.minX, y: frame.minY,
                                     width: max(1, frame.maxX - visible.minX), height: frame.height))
            }
            if frame.maxX > visible.maxX + 2, frame.minX >= visible.maxX - strip - 4 {
                result.append(CGRect(x: frame.minX, y: frame.minY,
                                     width: max(1, visible.maxX - frame.minX), height: frame.height))
            }
        }
        return result
    }

    /// Smoothly animates a window's frame (position + size), like macOS opt+drag.
    private func animateFrame(to target: CGRect, element: AXUIElement, completion: (() -> Void)? = nil) {
        frameTimer?.invalidate()
        let start = WindowController.frame(of: element) ?? target
        let startTime = Date()
        let duration = 0.18
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            let t = min(max(Date().timeIntervalSince(startTime) / duration, 0), 1)
            let eased = 1 - pow(1 - t, 3)
            let frame = CGRect(
                x: start.minX + (target.minX - start.minX) * eased,
                y: start.minY + (target.minY - start.minY) * eased,
                width: start.width + (target.width - start.width) * eased,
                height: start.height + (target.height - start.height) * eased
            )
            try? WindowController.setFrame(frame, for: element)
            if t >= 1 {
                timer.invalidate()
                self?.frameTimer = nil
                completion?()
            }
        }
    }

    /// Parks a window off the given side, leaving the smallest strip macOS keeps
    /// visible. Every parked window on a side sits at the same edge.
    private func park(anchor: TilingEngine.Anchor, target: WindowController.WindowInfo, entry: Int?, visible: CGRect) {
        let width = entry.map { windows[$0].width } ?? target.frame.width
        let height = entry.map { windows[$0].height } ?? target.frame.height
        let strip = WindowController.reservedStrip
        let x = anchor == .start ? visible.minX - width + strip : visible.maxX - strip
        let frame = CGRect(x: x, y: target.frame.minY, width: width, height: height)
        do {
            try WindowController.setFrame(frame, for: target.element)
            if let entry {
                windows[entry].x = frame.minX
                windows[entry].y = frame.minY
            }
            status = "\(target.appName) · parked \(anchor == .start ? "left" : "right")"
            showMiniMapIfEnabled(for: target, frame: frame)
            focusNextStack(after: target)
        } catch {
            status = "Park failed: \(error.localizedDescription)"
        }
    }

    private func setMinimized(_ minimized: Bool, target: WindowController.WindowInfo) {
        do {
            try WindowController.setMinimized(minimized, for: target.element)
            status = "\(target.appName) · \(minimized ? "minimized" : "restored")"
        } catch {
            status = "Minimize failed: \(error.localizedDescription)"
        }
    }

    private func matchingIndex(for target: WindowController.WindowInfo) -> Int? {
        windows.firstIndex { $0.appName == target.appName && $0.title == target.title }
    }

    private func directionName(for action: WindowController.ShortcutAction) -> String {
        switch action {
        case .leftHalf: return "left"
        case .rightHalf: return "right"
        case .topHalf: return "top"
        case .bottomHalf: return "bottom"
        default: return "next"
        }
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
        }
    }

    // MARK: - Discovery

    func refreshRealWindows() {
        accessibilityTrusted = AXIsProcessTrusted()
        guard accessibilityTrusted else {
            status = "Accessibility not granted · open Settings"
            return
        }

        let discovered = WindowController.discoverWindows()
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
        isRealMode = true
        orbitLog.notice("discovered windows=\(updated.count, privacy: .public) trusted=\(self.accessibilityTrusted, privacy: .public)")
        status = shortcutsBlocked > 0
            ? "Ready · \(shortcutsBlocked) shortcuts taken by another app"
            : "Ready · \(updated.count) windows"
    }

    /// Windows (including minimised) the switcher and search can act on.
    func actionableWindows() -> [ActionableWindow] {
        WindowController.discoverWindows(includeMinimized: true).map { info in
            ActionableWindow(id: info.id, title: info.title, appName: info.appName,
                             frame: info.frame, pid: info.pid, minimized: info.minimized,
                             element: info.element, color: color(for: info.appName))
        }
    }

    /// Brings a window back on screen (un-minimise + clamp inside the visible
    /// area) and focuses it.
    func bringOnScreen(_ window: ActionableWindow) {
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
        try? WindowController.setFrame(CGRect(x: x, y: y, width: width, height: height), for: window.element)
        activate(window)
        status = "\(window.appName) · brought on screen"
    }

    func focus(_ window: ActionableWindow) {
        if window.minimized { try? WindowController.setMinimized(false, for: window.element) }
        activate(window)
        status = "\(window.appName) · focused"
    }

    private func activate(_ window: ActionableWindow) {
        NSRunningApplication(processIdentifier: window.pid)?.activate()
        WindowController.raise(window.element)
        WindowController.focus(window.element)
    }

    // MARK: - Auto layout (golden spiral)

    /// Arranges the three windows with the most visual entropy into the three
    /// golden-spiral positions (largest window in the biggest slot).
    func autoLayout() {
        let area = WindowController.axVisibleFrame(for: NSScreen.main)
        let candidates = actionableWindows()
        guard !candidates.isEmpty else { return }
        let scored = candidates
            .map { (window: $0, entropy: entropy(of: $0)) }
            .sorted { $0.entropy > $1.entropy }
        let positions = goldenSpiral(area)
        let gapHalf = gap / 2
        for (index, position) in positions.enumerated() where index < scored.count {
            let target = scored[index].window
            try? WindowController.setFrame(position.insetBy(dx: gapHalf, dy: gapHalf).integral,
                                           for: target.element)
        }
        status = "Auto layout · golden spiral (\(min(positions.count, scored.count)) windows)"
        showMiniMapIfEnabled()
    }

    private func goldenSpiral(_ area: CGRect) -> [CGRect] {
        let phi = TilingEngine.phi
        let majorWidth = area.width / phi
        let minorWidth = area.width - majorWidth
        let majorHeight = area.height / phi
        let minorHeight = area.height - majorHeight
        return [
            CGRect(x: area.minX, y: area.minY, width: majorWidth, height: area.height),
            CGRect(x: area.minX + majorWidth, y: area.minY, width: minorWidth, height: majorHeight),
            CGRect(x: area.minX + majorWidth, y: area.minY + majorHeight, width: minorWidth, height: minorHeight)
        ]
    }

    private func entropy(of window: ActionableWindow) -> Double {
        guard let image = WindowController.previewImage(pid: window.pid, frame: window.frame) else {
            return Double(window.frame.width * window.frame.height)
        }
        return Self.edgeEnergy(image)
    }

    /// Mean absolute difference between neighbouring pixels (edge density).
    private static func edgeEnergy(_ image: NSImage) -> Double {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              bitmap.pixelsWide > 2, bitmap.pixelsHigh > 2 else { return 0 }
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let step = max(1, width / 64)
        var total = 0.0
        var count = 0
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: step, to: width, by: step) {
                guard let a = bitmap.colorAt(x: x, y: y),
                      let b = bitmap.colorAt(x: x - step, y: y) else { continue }
                let lumA = 0.299 * a.redComponent + 0.587 * a.greenComponent + 0.114 * a.blueComponent
                let lumB = 0.299 * b.redComponent + 0.587 * b.greenComponent + 0.114 * b.blueComponent
                total += abs(lumA - lumB)
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : 0
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

    func tileOnScreen(gap: Double) {
        guard !windows.isEmpty else { return }
        let screen = WindowController.axVisibleFrame(for: NSScreen.main).insetBy(dx: gap, dy: gap)
        let columns = max(1, Int(ceil(sqrt(Double(windows.count)))))
        let rows = Int(ceil(Double(windows.count) / Double(columns)))
        let cellWidth = max(180, (screen.width - gap * Double(columns - 1)) / Double(columns))
        let cellHeight = max(140, (screen.height - gap * Double(rows - 1)) / Double(rows))
        for (index, _) in windows.enumerated() {
            let column = index % columns
            let row = index / columns
            let frame = CGRect(x: screen.minX + Double(column) * (cellWidth + gap),
                               y: screen.minY + Double(row) * (cellHeight + gap),
                               width: cellWidth, height: cellHeight)
            resizeAndMove(windowAt: index, frame: frame)
        }
        status = "Tiled \(windows.count) windows with \(Int(gap)) px gap"
    }

    private func move(windowAt index: Int, to point: CGPoint) {
        guard index < windows.count else { return }
        windows[index].x = point.x
        windows[index].y = point.y
        guard let element = elements[windows[index].id] else { return }
        do {
            try WindowController.setPosition(point, for: element)
        } catch {
            status = "Move failed: \(error.localizedDescription)"
        }
    }

    private func resizeAndMove(windowAt index: Int, frame: CGRect) {
        guard index < windows.count else { return }
        windows[index].x = frame.minX
        windows[index].y = frame.minY
        windows[index].width = frame.width
        windows[index].height = frame.height
        guard let element = elements[windows[index].id] else { return }
        do {
            try WindowController.setFrame(frame, for: element)
        } catch {
            status = "Tile failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Colors

    private func tint(for appName: String) -> String {
        let palette = ["blue", "purple", "green", "orange", "pink"]
        return palette[Self.stableIndex(appName, count: palette.count)]
    }

    /// A per-app colour derived from the current theme's accent hue, so the
    /// window colours follow the chosen theme.
    func color(for appName: String) -> NSColor {
        let base = (NSColor(theme.accent).usingColorSpace(.deviceRGB)) ?? .systemBlue
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let index = Self.stableIndex(appName, count: 8)
        let shifted = (hue + CGFloat(index) / 8).truncatingRemainder(dividingBy: 1)
        return NSColor(hue: shifted,
                       saturation: min(1, max(0.5, saturation)),
                       brightness: min(1, max(0.65, brightness)),
                       alpha: 1)
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
        MiniMapController.shared.show(windows: windows, highlightedIDs: [], motionFrom: motionFrom)
    }

    private func showMiniMapIfEnabled(for target: WindowController.WindowInfo, frame: CGRect) {
        guard showMiniMap else { return }
        var mapWindows = windows
        let matchingIndex = mapWindows.firstIndex(where: {
            $0.appName == target.appName && $0.title == target.title
        })
        let highlightedID: UUID
        if let index = matchingIndex {
            highlightedID = mapWindows[index].id
            mapWindows[index].x = frame.minX
            mapWindows[index].y = frame.minY
            mapWindows[index].width = frame.width
            mapWindows[index].height = frame.height
        } else {
            let mappedWindow = WorkspaceWindow(title: target.title, appName: target.appName,
                                               x: frame.minX, y: frame.minY,
                                               width: frame.width, height: frame.height)
            highlightedID = mappedWindow.id
            mapWindows.append(mappedWindow)
        }
        MiniMapController.shared.show(windows: mapWindows, highlightedIDs: [highlightedID])
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
