import AppKit
import Observation
import SwiftUI

/// The checklist's contents, shared by the panel, the menu and the tests (T59).
///
/// Writes are coalesced: a burst of ticks costs one file write, and the write
/// itself runs on its own queue so a slow disk never holds the panel.
@Observable
@MainActor
final class ChecklistStore {
    static let shared = ChecklistStore()

    private(set) var checklist = Checklist()
    /// Called after every change, so the panel can re-measure and re-place.
    @ObservationIgnored var onChange: (() -> Void)?

    private let file: ChecklistFile
    private let queue = DispatchQueue(label: "MakiDesk.checklist", qos: .utility)
    private var loaded = false
    private var saveWork: DispatchWorkItem?

    init(file: ChecklistFile = ChecklistFile()) {
        self.file = file
    }

    var items: [ChecklistItem] { checklist.items }
    var remaining: Int { checklist.remaining }
    var completed: Int { checklist.completed }
    var isFull: Bool { checklist.isFull }

    /// Reads the file once, on first use, off the main thread: launch and the
    /// first opening of the card never wait on the disk.
    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let file = self.file
        queue.async { [weak self] in
            let items = file.load()
            Task { @MainActor [weak self] in
                guard let self else { return }
                // An item typed while the file was being read wins.
                if self.checklist.items.isEmpty {
                    self.checklist = Checklist(items: items)
                }
                self.onChange?()
            }
        }
    }

    @discardableResult
    func add(_ text: String) -> Bool {
        guard checklist.add(text) != nil else { return false }
        changed()
        return true
    }

    func toggle(_ id: UUID) {
        checklist.toggle(id)
        changed()
    }

    func remove(_ id: UUID) {
        checklist.remove(id)
        changed()
    }

    func move(_ id: UUID, by offset: Int) {
        guard checklist.move(id, by: offset) else { return }
        changed()
    }

    func clearCompleted() {
        guard checklist.clearCompleted() > 0 else { return }
        changed()
    }

    /// Writes now instead of after the debounce, without waiting: for a hide.
    func flushAsync() {
        saveWork?.cancel()
        saveWork = nil
        write()
    }

    /// Waits for the write: the termination fence, so a tick made a moment
    /// before quitting is on disk.
    func flushBlocking() {
        saveWork?.cancel()
        saveWork = nil
        let items = checklist.items
        let file = self.file
        queue.sync { _ = file.save(items) }
    }

    private func changed() {
        onChange?()
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.saveWork = nil
            self.write()
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func write() {
        let items = checklist.items
        let file = self.file
        queue.async { _ = file.save(items) }
    }
}

/// Owns the checklist panel: one small, always-available card, shown and hidden
/// with `⌃⌥L` or the menu (T59).
@MainActor
final class ChecklistController: NSObject, NSWindowDelegate {
    static let shared = ChecklistController()

    private var window: ChecklistPanel?
    private let store = ChecklistStore.shared
    private let focusReturn = PanelFocusReturn()
    private var refreshWork: DispatchWorkItem?
    /// The pointer is over the card, or the card has the keys: either way it
    /// shows at full opacity while it is being used (T59).
    private var hovering = false
    private var started = false

    private override init() {
        super.init()
    }

    var isVisible: Bool { window?.isVisible == true }

    /// The card's frame in screen coordinates while it is on screen, so other
    /// panels can keep clear of it (the mini map does).
    var panelFrame: CGRect? {
        guard let window, window.isVisible else { return nil }
        return window.frame
    }

    func start() {
        guard !started else { return }
        started = true
        store.onChange = { [weak self] in self?.scheduleRefresh() }
        applySettings()
    }

    /// Applies the settings: shown or hidden, how solid, how wide, where.
    func applySettings() {
        guard WorkspaceStore.shared.checklistVisible else {
            hide()
            return
        }
        store.loadIfNeeded()
        show()
        scheduleRefresh()
    }

    func show() {
        if window == nil { build() }
        guard let window else { return }
        if !window.isVisible { refresh() }
        window.orderFrontRegardless()
        updateAppearance()
    }

    func hide() {
        guard let window, window.isVisible else { return }
        let restore = focusReturn.takeRestoreAction(ownsKeyboard: window.isKeyWindow)
        hovering = false
        store.flushAsync()
        window.orderOut(nil)
        restore?()
    }

    /// Esc while typing in the add field: the panel stays, the keys go back to
    /// the app the user came from.
    func endEditing() {
        guard let window, window.isKeyWindow else { return }
        focusReturn.takeRestoreAction(ownsKeyboard: true)?()
    }

    /// The add field has the cursor: typing needs MakiDesk active. The keys are
    /// remembered first, so Esc or hiding the card gives them back. A ticked
    /// box never comes through here, which is why ticking leaves the keyboard
    /// where it was.
    func beginEditing() {
        guard let window else { return }
        if !NSApp.isActive {
            focusReturn.capture()
            NSApp.activate(ignoringOtherApps: true)
        }
        if !window.isKeyWindow { window.makeKey() }
    }

    private func build() {
        let width = CGFloat(WorkspaceStore.shared.checklistWidth)
        let hosting = ChecklistHostingView(rootView: ChecklistView(store: store))
        hosting.onHover = { [weak self] inside in
            guard let self, self.hovering != inside else { return }
            self.hovering = inside
            self.updateAppearance()
        }
        let panel = ChecklistPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.tabbingMode = .disallowed
        // The checklist is a viewing aid for the user, not part of what they
        // capture: it never enters a screenshot, a recording or a share.
        panel.sharingType = .none
        panel.delegate = self
        window = panel
        refresh()
    }

    /// Measures the card, clamps it to the display and puts it in its corner.
    private func refresh() {
        guard let window, let hosting = window.contentView else { return }
        let settings = WorkspaceStore.shared
        let width = CGFloat(settings.checklistWidth)
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width < 1 || size.height < 1 {
            size = CGSize(width: width, height: 240)
        }
        size.width = width
        let screen = targetScreen()
        if let screen {
            size.height = min(size.height,
                              screen.visibleFrame.height * ChecklistSettings.maximumHeightShare)
        }
        window.setContentSize(size)
        guard let screen else { return }
        let frame = ChecklistSettings.frame(for: size,
                                            position: settings.checklistPosition,
                                            screen: screen.visibleFrame,
                                            margin: ChecklistSettings.edgeMargin(forGap: settings.gap))
        if window.frame != frame { window.setFrame(frame, display: false) }
        updateAppearance()
    }

    /// The resting opacity is the setting; a card the user is pointing at or
    /// typing in is always solid, so what is written there is readable without
    /// changing the setting every time.
    private func updateAppearance() {
        guard let window else { return }
        let target = ChecklistSettings.alpha(
            opacity: WorkspaceStore.shared.checklistOpacity,
            revealed: hovering || window.isKeyWindow,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
        guard abs(window.alphaValue - target) > 0.01 else { return }
        guard WorkspaceStore.shared.effectiveAnimationsEnabled else {
            window.alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.allowsImplicitAnimation = true
            window.animator().alphaValue = target
        }
    }

    /// Re-measures on the next run-loop turn: the SwiftUI view has not laid
    /// itself out yet when the model change is published.
    private func scheduleRefresh() {
        guard isVisible else { return }
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// The display chosen in Settings, with the palette's rule and fallback.
    private func targetScreen() -> NSScreen? {
        WorkspaceStore.shared.checklistScreen.targetScreen()
    }

    // MARK: - Typing

    /// Ticking a box must not activate MakiDesk; typing does. SwiftUI reports
    /// the field's focus directly; this covers the case where the field already
    /// had the cursor when the panel lost and regained the keys, by checking a
    /// turn later that a field editor is what holds them.
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window, notification.object as? NSWindow === window else { return }
        updateAppearance()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window,
                  window.isKeyWindow, !NSApp.isActive,
                  window.firstResponder is NSTextView else { return }
            self.beginEditing()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window, notification.object as? NSWindow === window else { return }
        updateAppearance()
    }
}

/// A panel that may sit anywhere on any display; a plain `NSPanel` clamps its
/// frame to the screen with a margin and would drift away from the corner.
private final class ChecklistPanel: NSPanel {
    /// Typing the first item needs a key window; it becomes key without
    /// activating the app, and the controller activates only when a field asks.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// The first click on a box must tick it, not just wake the panel: the card is
/// used while another app has the keyboard. The same view reports the pointer,
/// so the card can turn solid while it is being read.
private final class ChecklistHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // `.activeAlways`: the pointer matters while another app is active.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }
}

/// The card itself: a short list, an add field and the count. Nothing is
/// interpreted, so a line is a line.
private struct ChecklistView: View {
    let store: ChecklistStore
    @State private var draft = ""
    @FocusState private var adding: Bool

    private var theme: PaletteTheme { WorkspaceStore.shared.theme }
    private var width: CGFloat { CGFloat(WorkspaceStore.shared.checklistWidth) }

    private var canAdd: Bool {
        store.isFull == false
            && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if store.items.isEmpty {
                Text("Nothing to do.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.subtext)
                    .padding(.vertical, 3)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(store.items) { item in
                            ChecklistRow(item: item, theme: theme, store: store)
                        }
                    }
                }
                .frame(maxHeight: 420)
            }

            addRow

            if store.completed > 0 {
                Button("Clear completed (\(store.completed))") {
                    store.clearCompleted()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(theme.subtext)
                .help("Takes every ticked item away")
            }
            // The limit note stays even when there is something to clear: a
            // full list with ticked items is exactly when both matter.
            if store.isFull {
                Text("\(Checklist.maxItems) items is the limit.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.subtext)
            }
        }
        .padding(11)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(theme.border.opacity(0.6), lineWidth: 1)
                )
        )
        // The card is the interactive part: outside it there is nothing to
        // click, so the app under the panel keeps its own clicks.
        .onExitCommand { ChecklistController.shared.endEditing() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "checklist")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.accent)
            Text("Checklist")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.text)
            Spacer(minLength: 4)
            Text("\(store.remaining) left")
                .font(.system(size: 11))
                .foregroundStyle(theme.subtext)
                .help(store.completed > 0
                      ? "\(store.completed) done · ⌃⌥L hides the checklist"
                      : "⌃⌥L hides the checklist")
            Button {
                WorkspaceStore.shared.updateChecklistVisible(false)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.subtext)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide the checklist")
            .help("Hide the checklist (⌃⌥L brings it back)")
        }
    }

    private var addRow: some View {
        HStack(spacing: 4) {
            TextField("Add an item…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.background.opacity(0.55))
                )
                .focused($adding)
                .onChange(of: adding) { _, focused in
                    if focused { ChecklistController.shared.beginEditing() }
                }
                .onSubmit(add)
                .disabled(store.isFull)
                .accessibilityLabel("New checklist item")
            Button(action: add) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(canAdd ? theme.accent : theme.subtext.opacity(0.5))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
            .accessibilityLabel("Add the item")
        }
        .padding(.top, 2)
    }

    private func add() {
        guard store.add(draft) else { return }
        draft = ""
    }
}

/// One line: the box, the text and the three small controls. Reordering is two
/// buttons rather than a drag, so it works with the keyboard and VoiceOver.
private struct ChecklistRow: View {
    let item: ChecklistItem
    let theme: PaletteTheme
    let store: ChecklistStore
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Button {
                store.toggle(item.id)
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(item.done ? theme.accent : theme.subtext)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.text)
            .accessibilityValue(item.done ? "Done" : "Not done")
            .help(item.done ? "Mark as not done" : "Mark as done")

            Text(item.text)
                .font(.system(size: 12.5))
                .foregroundStyle(item.done ? theme.subtext : theme.text)
                .strikethrough(item.done, color: theme.subtext)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)

            HStack(spacing: 1) {
                icon("chevron.up", "Move up") { store.move(item.id, by: -1) }
                icon("chevron.down", "Move down") { store.move(item.id, by: 1) }
                icon("xmark", "Delete") { store.remove(item.id) }
            }
            .opacity(hovering ? 1 : 0.35)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func icon(_ symbol: String, _ help: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(theme.subtext)
                .frame(width: 15, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("\(help): \(item.text)")
    }
}
