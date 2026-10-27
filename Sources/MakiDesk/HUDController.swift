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
        var hideWork: DispatchWorkItem?

        init(notice: HUDNotice, size: CGSize, panel: NSPanel) {
            self.notice = notice
            self.size = size
            self.panel = panel
        }
    }

    private let defaults: UserDefaults
    private var historyStore = HUDHistory()
    /// Transients on screen, newest first (nearest the anchor).
    private var visible: [Entry] = []
    private var pending: [HUDNotice] = []
    private var progress: Entry?
    private var maxVisible = 2

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Shows a notice. `kind` defaults to the severity carried by the symbol;
    /// `.progress` delegates to `showProgress` and stays until finished.
    func show(_ text: String, symbol: String = "checkmark.circle.fill",
              detail: String? = nil, kind: HUDKind? = nil,
              overrideDuration: TimeInterval? = nil) {
        let resolved = kind ?? HUDKind.inferred(for: symbol)
        if resolved == .progress {
            _ = showProgress(text, symbol: symbol, detail: detail)
            return
        }
        let notice = HUDNotice(id: UUID(), text: text, symbol: symbol, detail: detail,
                               kind: resolved, date: Date(),
                               overrideDuration: overrideDuration)
        record(notice)
        guard pending.isEmpty, visible.count < maxVisible else {
            pending.append(notice)
            return
        }
        presentTransient(notice)
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

    /// Takes every notice away at once. A command that captures the screen
    /// calls this first, so no notice can end up in the image.
    func hide() {
        for entry in visible {
            entry.hideWork?.cancel()
            entry.panel.orderOut(nil)
        }
        visible.removeAll()
        pending.removeAll()
        progress?.panel.orderOut(nil)
        progress = nil
    }

    func clearHistory() {
        historyStore.clear()
        history = []
    }

    // MARK: - Presentation

    private func presentTransient(_ notice: HUDNotice) {
        let entry = makeEntry(notice)
        visible.insert(entry, at: 0)
        layout()
        announce(notice)
        let duration = notice.overrideDuration
            ?? HUDTiming.duration(for: notice.kind,
                                  base: HUDSettings.baseDuration(defaults: defaults))
        if let duration {
            let work = DispatchWorkItem { [weak self] in self?.dismiss(notice.id) }
            entry.hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
    }

    private func dismiss(_ id: UUID) {
        guard let index = visible.firstIndex(where: { $0.notice.id == id }) else { return }
        let entry = visible.remove(at: index)
        entry.hideWork?.cancel()
        entry.panel.orderOut(nil)
        layout()
        while visible.count < maxVisible, pending.isEmpty == false {
            presentTransient(pending.removeFirst())
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
        return Entry(notice: notice, size: size, panel: panel)
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
        var entries: [Entry] = []
        if let progress { entries.append(progress) }
        entries.append(contentsOf: visible)
        guard entries.isEmpty == false else { return }
        let frames = HUDLayout.frames(
            anchor: HUDSettings.position(defaults: defaults),
            screen: screen.visibleFrame,
            sizes: entries.map(\.size)
        )
        for (entry, frame) in zip(entries, frames) where frame != .zero {
            entry.panel.setFrame(frame, display: true)
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
        case .confirmation, .progress: return theme.accent
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var borderColor: Color {
        switch notice.kind {
        case .confirmation, .progress: return theme.border
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
