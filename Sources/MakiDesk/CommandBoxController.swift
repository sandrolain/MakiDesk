import AppKit
import Observation
import SwiftUI

/// The state of the command box (T38): what has been typed, which suggestion is
/// chosen, and why the last attempt failed.
@Observable
@MainActor
final class CommandBoxModel {
    var text = ""
    var selection = 0
    var error: String?

    var suggestions: [CommandEntry] { CommandCatalog.suggestions(for: text) }

    /// Keeps the highlight inside the list, which changes as the user types.
    func clampSelection() {
        let count = suggestions.count
        selection = count == 0 ? 0 : min(max(selection, 0), count - 1)
    }

    func move(_ delta: Int) {
        let count = suggestions.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    /// `Tab`: the chosen phrase, with a space ready for its argument.
    func complete() {
        let list = suggestions
        guard list.indices.contains(selection) else { return }
        let entry = list[selection]
        text = entry.argument == nil ? entry.id : entry.id + " "
        error = nil
    }
}

/// A field of text with the actions a command palette needs, so the arrows and
/// Tab can be used while a text field has the keyboard (T38).
@MainActor
final class CommandBoxController {
    static let shared = CommandBoxController()

    let model = CommandBoxModel()
    private var window: CommandBoxPanel?
    private let focusReturn = PanelFocusReturn()

    private init() {}

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil { build() }
        guard let window else { return }
        model.text = ""
        model.selection = 0
        model.error = nil
        place(window)
        focusReturn.capture()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard let window, window.isVisible else { return }
        let restore = focusReturn.takeRestoreAction(ownsKeyboard: window.isKeyWindow)
        window.orderOut(nil)
        restore?()
    }

    /// Runs what has been typed. A wrong command or argument stays in the box
    /// with the reason, so it can be corrected instead of typed again.
    func run() {
        guard let match = CommandCatalog.match(model.text) else {
            model.error = model.text.trimmingCharacters(in: .whitespaces).isEmpty
                ? "Type a command"
                : "No command like that"
            return
        }
        guard let argument = CommandCatalog.validated(match.entry, argument: match.argument) else {
            let hint = match.entry.argument?.hint ?? ""
            model.error = "“\(match.argument)” is not valid here · expected \(hint)"
            return
        }
        deliver(match.entry.action, argument: argument)
    }

    /// Runs one suggestion directly, for a click in the list.
    func run(_ entry: CommandEntry) {
        guard entry.argument == nil else {
            model.text = entry.id + " "
            model.error = nil
            return
        }
        deliver(entry.action, argument: "")
    }

    /// Closes the box, waits for the keys to be back where they were, then
    /// runs the command.
    ///
    /// "The front window" is meaningful only once our panel has let go: while
    /// the box is key, MakiDesk itself is the frontmost app and every window
    /// command would answer "no window". Closing first makes a typed command
    /// behave exactly like its shortcut pressed in that app (T38).
    private func deliver(_ action: CommandAction, argument: String) {
        hide()
        waitForFocusThen {
            self.perform(action, argument: argument)
        }
    }

    /// Runs `work` once another app owns the keyboard again, or after half a
    /// second if none does (our own Settings window, for instance).
    private func waitForFocusThen(attempts: Int = 10, _ work: @escaping () -> Void) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if front != nil, front != ownPID {
            work()
            return
        }
        guard attempts > 0 else {
            work()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForFocusThen(attempts: attempts - 1, work)
        }
    }

    private func perform(_ action: CommandAction, argument: String) {
        let store = WorkspaceStore.shared
        switch action {
        case let .shortcut(shortcut):
            store.applyShortcut(shortcut)
        case .recallGroup:
            if let slot = Int(argument) { store.recallGroup(slot: slot) }
        case .toggleGroupMembership:
            if let slot = Int(argument) { store.toggleGroupMembership(slot: slot) }
        case .timer:
            guard let input = TimerText.parse(argument) else { return }
            if let message = TimerController.shared.start(input) {
                HUDController.shared.show(message, symbol: "exclamationmark.triangle.fill")
            }
        case .dismissNotices:
            HUDController.shared.hide()
        }
    }

    private func build() {
        let hosting = NSHostingView(rootView: CommandBoxView(model: model,
                                                            onSubmit: { [weak self] in self?.run() },
                                                            onCancel: { [weak self] in self?.hide() },
                                                            onPick: { [weak self] entry in self?.run(entry) }))
        let panel = CommandBoxPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        window = panel
    }

    private func place(_ window: NSWindow) {
        guard let screen = PaletteScreenLocation.focusedWindow.targetScreen() else { return }
        let size = window.frame.size
        let visible = screen.visibleFrame
        window.setFrame(CGRect(x: (visible.midX - size.width / 2).rounded(),
                               y: (visible.midY - size.height / 2).rounded(),
                               width: size.width, height: size.height),
                        display: false)
    }
}

private final class CommandBoxPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// The card: the field, the suggestions, and what the keys do.
private struct CommandBoxView: View {
    @Bindable var model: CommandBoxModel
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onPick: (CommandEntry) -> Void

    private var theme: PaletteTheme { WorkspaceStore.shared.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.accent)
                PaletteTextField(text: $model.text,
                                 placeholder: "Command",
                                 onSubmit: { _ in onSubmit() },
                                 onCancel: onCancel,
                                 onMove: { model.move($0); model.clampSelection() },
                                 onTab: { model.complete() })
                    .frame(height: 26)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if model.text.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("A command, in words: tile left, layout grid, group 3, timer 25m…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.subtext)
                    .padding(.horizontal, 12)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, entry in
                            suggestionRow(entry, selected: index == model.selection)
                                .id(entry.id)
                                .onTapGesture { onPick(entry) }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .onChange(of: model.selection) { _, selection in
                    let list = model.suggestions
                    if list.indices.contains(selection) {
                        proxy.scrollTo(list[selection].id, anchor: .center)
                    }
                }
            }

            HStack(spacing: 6) {
                if let error = model.error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else {
                    Text("↑↓ choose · Tab completes · ⏎ runs · esc closes")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.subtext)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(theme.border.opacity(0.6), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onChange(of: model.text) { _, _ in
            model.selection = 0
            model.error = nil
        }
    }

    private func suggestionRow(_ entry: CommandEntry, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Text(CommandCatalog.display(entry))
                .font(.system(size: 12.5, weight: selected ? .semibold : .regular,
                              design: .monospaced))
                .foregroundStyle(theme.text)
                .frame(width: 190, alignment: .leading)
                .lineLimit(1)
            Text(entry.summary)
                .font(.system(size: 12))
                .foregroundStyle(theme.subtext)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? theme.surfaceSelected : Color.clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(CommandCatalog.display(entry)): \(entry.summary)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
