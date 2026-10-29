import AppKit
import Observation
import SwiftUI

/// Notices with a queue, severity-based durations, an in-memory history and a
/// governed position (T52).
///
/// The surface stays the same as before: a borderless, non-activating panel per
/// notice that ignores the mouse. What changes is that two notices can be read
/// at once (the rest wait), progress updates in place, and errors stay long
/// enough to be read.
@Observable
@MainActor
final class HUDController {
    static let shared = HUDController()

    /// The last notices, newest first, in memory only.
    private(set) var history: [HUDNotice] = []

    private final class Entry {
        var notice: HUDNotice
        var size: CGSize
        let panel: NSPanel
        /// Only for a sticky notice: the small panel that carries ✕, so the
        /// rest of the notice keeps passing clicks through (T60).
        var closePanel: NSPanel?
        /// `NSControl.target` is not retained: the entry keeps the target alive.
        var closeTarget: CloseTarget?
        var hideWork: DispatchWorkItem?

        init(notice: HUDNotice, size: CGSize, panel: NSPanel) {
            self.notice = notice
            self.size = size
            self.panel = panel
        }
    }

    /// Bridges the ✕ button to the notice it belongs to.
    private final class CloseTarget: NSObject {
        private let handler: () -> Void

        init(handler: @escaping () -> Void) {
            self.handler = handler
        }

        @objc func fire() {
            handler()
        }
    }

    private let defaults: UserDefaults
    private var historyStore = HUDHistory()
    /// What is on screen, by id: sticky notices and transients in two lanes.
    private var entries: [UUID: Entry] = [:]
    private var stack = HUDStack()
    private var pending: [HUDNotice] = []
    private var progress: Entry?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether anything is showing or waiting, for the menu's Dismiss All.
    var hasNotices: Bool { !stack.isEmpty || !pending.isEmpty || progress != nil }

    /// Shows a notice. `kind` defaults to the severity carried by the symbol;
    /// `.progress` delegates to `showProgress` and stays until finished.
    /// `sticky` defaults to the Settings policy for errors (off), so every
    /// existing call site keeps its behaviour.
    func show(_ text: String, symbol: String = "checkmark.circle.fill",
              detail: String? = nil, kind: HUDKind? = nil,
              overrideDuration: TimeInterval? = nil,
              sticky: Bool? = nil) {
        let resolved = kind ?? HUDKind.inferred(for: symbol)
        if resolved == .progress {
            _ = showProgress(text, symbol: symbol, detail: detail)
            return
        }
        let isSticky = sticky ?? HUDStickyPolicy.isSticky(
            kind: resolved,
            keepErrors: HUDSettings.errorsSticky(defaults: defaults)
        )
        let notice = HUDNotice(id: UUID(), text: text, symbol: symbol, detail: detail,
                               kind: resolved, date: Date(),
                               overrideDuration: overrideDuration,
                               sticky: isSticky)
        record(notice)
        if isSticky {
            presentSticky(notice)
            return
        }
        guard pending.isEmpty else {
            pending.append(notice)
            return
        }
        present(notice)
    }

    /// Starts (or updates) the one persistent progress notice. It does not
    /// queue and does not expire.
    @discardableResult
    func showProgress(_ text: String, symbol: String = "hourglass",
                      detail: String? = nil) -> UUID {
        // A new operation replaces the visible progress and gets its own id, so
        // an older operation finishing late cannot close the newer one.
        let notice = HUDNotice(id: UUID(), text: text, symbol: symbol, detail: detail,
                               kind: .progress, date: Date())
        if let current = progress {
            current.notice = notice
            rebuild(current)
            layout()
            return notice.id
        }
        let entry = makeEntry(notice)
        progress = entry
        layout()
        return notice.id
    }

    func updateProgress(_ id: UUID, text: String, detail: String? = nil) {
        guard let entry = progress, entry.notice.id == id else { return }
        let notice = HUDNotice(id: id, text: text, symbol: entry.notice.symbol,
                               detail: detail, kind: .progress, date: entry.notice.date)
        entry.notice = notice
        rebuild(entry)
        layout()
    }

    func finishProgress(_ id: UUID) {
        guard let entry = progress, entry.notice.id == id else { return }
        entry.panel.orderOut(nil)
        progress = nil
        layout()
    }

    /// Takes every notice away at once, sticky ones included. A command that
    /// captures the screen calls this first, and the menu's **Dismiss All
    /// Notices** runs it. Sticky notices stay in the history.
    func hide() {
        for entry in entries.values {
            entry.hideWork?.cancel()
            entry.panel.orderOut(nil)
            entry.closePanel?.orderOut(nil)
        }
        entries.removeAll()
        stack.clear()
        pending.removeAll()
        progress?.panel.orderOut(nil)
        progress = nil
    }

    /// Takes one notice away, from either lane (the ✕ and the timer).
    func dismiss(_ id: UUID) {
        guard stack.remove(id) else { return }
        if let entry = entries.removeValue(forKey: id) {
            entry.hideWork?.cancel()
            entry.panel.orderOut(nil)
            entry.closePanel?.orderOut(nil)
        }
        layout()
        fillTransientSlots()
    }

    func clearHistory() {
        historyStore.clear()
        history = []
    }

    /// Shows a sample of one state, for the Preview buttons in Settings. A
    /// progress preview finishes by itself after two seconds, so pressing it
    /// cannot leave a spinner on screen with no work behind it; an error
    /// preview follows the sticky option like a real one.
    func preview(_ kind: HUDKind) {
        let sample = HUDPreview.sample(for: kind)
        guard kind == .progress else {
            show(sample.text, symbol: sample.symbol, detail: sample.detail, kind: kind)
            return
        }
        let id = showProgress(sample.text, symbol: sample.symbol, detail: sample.detail)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.finishProgress(id)
        }
    }

    // MARK: - Presentation

    private func present(_ notice: HUDNotice) {
        guard stack.addTransient(notice.id) else {
            pending.append(notice)
            return
        }
        let entry = makeEntry(notice)
        entries[notice.id] = entry
        layout()
        announce(notice)
        if let duration = HUDTiming.duration(
            for: notice,
            base: HUDSettings.baseDuration(defaults: defaults)
        ) {
            let work = DispatchWorkItem { [weak self] in self?.dismiss(notice.id) }
            entry.hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
    }

    /// A sticky notice has no timer: only ✕ or Dismiss All take it away. When
    /// the lane is full the oldest one leaves; it stays in the history.
    private func presentSticky(_ notice: HUDNotice) {
        let entry = makeEntry(notice)
        entries[notice.id] = entry
        if let evicted = stack.addSticky(notice.id),
           let old = entries.removeValue(forKey: evicted) {
            old.panel.orderOut(nil)
            old.closePanel?.orderOut(nil)
        }
        layout()
        announce(notice)
    }

    /// Starts the next waiting notice once a transient has gone.
    private func fillTransientSlots() {
        while stack.hasTransientRoom, pending.isEmpty == false {
            present(pending.removeFirst())
        }
    }

    private func makeEntry(_ notice: HUDNotice) -> Entry {
        let hosting = makeHosting(notice)
        let size = fittingSize(hosting)
        let panel = makePanel()
        panel.contentView = hosting
        panel.setContentSize(size)
        panel.orderFrontRegardless()
        if WorkspaceStore.shared.effectiveAnimationsEnabled {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        let entry = Entry(notice: notice, size: size, panel: panel)
        if notice.sticky { attachClose(to: entry) }
        return entry
    }

    /// Puts ✕ in its own click-taking panel over the notice's corner. The
    /// notice itself keeps ignoring the mouse, so a click meant for the app
    /// under it still reaches the app.
    private func attachClose(to entry: Entry) {
        let id = entry.notice.id
        let target = CloseTarget { [weak self] in self?.dismiss(id) }
        let side = HUDLayout.closeControlSize
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: side, height: side))
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        button.contentTintColor = NSColor(WorkspaceStore.shared.theme.subtext)
        button.target = target
        button.action = #selector(CloseTarget.fire)
        button.setAccessibilityLabel("Dismiss notice")
        button.setAccessibilityHelp("Takes this notice away. It stays in the notification history.")
        button.autoresizingMask = [.width, .height]

        let container = NSView(frame: button.frame)
        container.addSubview(button)

        let panel = NSPanel(contentRect: button.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.sharingType = .none
        panel.contentView = container
        panel.orderFrontRegardless()
        if WorkspaceStore.shared.effectiveAnimationsEnabled {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }

        entry.closePanel = panel
        entry.closeTarget = target
    }

    private func rebuild(_ entry: Entry) {
        let hosting = makeHosting(entry.notice)
        let size = fittingSize(hosting)
        entry.size = size
        entry.panel.contentView = hosting
        entry.panel.setContentSize(size)
    }

    private func makeHosting(_ notice: HUDNotice) -> NSHostingView<HUDView> {
        NSHostingView(rootView: HUDView(
            notice: notice,
            compact: HUDSettings.compact(defaults: defaults),
            textSize: HUDSettings.textSize(defaults: defaults)
        ))
    }

    private func fittingSize(_ hosting: NSHostingView<HUDView>) -> CGSize {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        return size.width > 1 && size.height > 1 ? size : CGSize(width: 240, height: 44)
    }

    private func layout() {
        guard let screen = targetScreen() else { return }
        var ordered: [Entry] = []
        if let progress { ordered.append(progress) }
        ordered.append(contentsOf: stack.ordered.compactMap { entries[$0] })
        guard ordered.isEmpty == false else { return }
        let frames = HUDLayout.frames(
            anchor: HUDSettings.position(defaults: defaults),
            screen: screen.visibleFrame,
            sizes: ordered.map(\.size)
        )
        for (entry, frame) in zip(ordered, frames) where frame != .zero {
            entry.panel.setFrame(frame, display: true)
            entry.closePanel?.setFrame(HUDLayout.closeFrame(for: frame), display: true)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Notices never belong in a screenshot or a recording, even when a
        // caller forgets to hide them first (T41/T36).
        panel.sharingType = .none
        return panel
    }

    /// The display chosen in Settings, with the palette's rule and fallback.
    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard screens.isEmpty == false else { return nil }
        let location = HUDSettings.screenLocation(defaults: defaults)
        let focusedID = NSScreen.main.flatMap(Self.displayID)
        let focusedIndex = focusedID.flatMap { id in
            screens.firstIndex { Self.displayID($0) == id }
        }
        let index = location.screenIndex(frames: screens.map(\.frame),
                                         focusedIndex: focusedIndex,
                                         mouse: NSEvent.mouseLocation)
        return index.map { screens[$0] } ?? NSScreen.main ?? screens.first
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    // MARK: - History and accessibility

    private func record(_ notice: HUDNotice) {
        guard HUDSettings.historyEnabled(defaults: defaults) else { return }
        historyStore.add(notice)
        history = historyStore.notices
    }

    private func announce(_ notice: HUDNotice) {
        guard HUDSettings.voiceOverEnabled(defaults: defaults) else { return }
        let text = [notice.text, notice.detail].compactMap { $0 }
            .filter { $0.isEmpty == false }
            .joined(separator: ". ")
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}

/// One notice, in-theme so it never clashes with the palette. The severity
/// tints the icon and the border; progress shows an indeterminate spinner.
private struct HUDView: View {
    let notice: HUDNotice
    var compact = false
    var textSize: CGFloat = HUDSettings.defaultTextSize

    /// In-theme so the notice never clashes with the palette.
    private var theme: PaletteTheme { WorkspaceStore.shared.theme }

    private var type: HUDTypography { HUDTypography(textSize: textSize, compact: compact) }

    private var tint: Color {
        switch notice.kind {
        case .info: return theme.subtext
        case .confirmation, .progress: return theme.accent
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var borderColor: Color {
        switch notice.kind {
        case .info: return theme.border
        case .confirmation, .progress: return theme.border
        case .success: return .green.opacity(0.55)
        case .warning: return .orange.opacity(0.65)
        case .error: return .red.opacity(0.7)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: type.spacing) {
            HStack(spacing: 8) {
                if notice.kind == .progress {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: type.iconSize, height: type.iconSize)
                } else {
                    Image(systemName: notice.symbol)
                        .font(.system(size: type.iconSize, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text(notice.text)
                    .font(.system(size: type.titleSize, weight: .medium))
                    .foregroundStyle(theme.text)
                    .fixedSize()
            }
            if compact == false, let detail = notice.detail, detail.isEmpty == false {
                Text(detail)
                    .font(.system(size: type.detailSize, design: .monospaced))
                    .foregroundStyle(theme.subtext)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460, alignment: .leading)
            }
        }
        .padding(.horizontal, type.horizontalPadding)
        .padding(.vertical, type.verticalPadding)
        // Room for the ✕ panel on the right edge of a sticky notice.
        .padding(.trailing, notice.sticky ? 26 : 0)
        .background(
            RoundedRectangle(cornerRadius: type.cornerRadius, style: .continuous)
                .fill(theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: type.cornerRadius, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(notice.kind.label)
        .accessibilityValue([notice.text, notice.detail].compactMap { $0 }.joined(separator: ". "))
    }
}
