import AppKit
import SwiftUI

/// The preview of a rewrite, before it touches the note (T66).
///
/// One panel over the notes window: the Markdown grows while the model streams,
/// and nothing is written until Apply. Copy takes the text as it is, Cancel
/// leaves the note untouched.
@MainActor
final class NotesRewritePanelController {
    static let shared = NotesRewritePanelController()

    private var panel: RewritePanel?

    private init() {}

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Shows the preview. `onApply` receives the final Markdown; the caller
    /// decides which note and range it belongs to.
    func show(onApply: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        let view = NotesRewriteView(
            onApply: { [weak self] text in
                onApply(text)
                self?.hide()
            },
            onCancel: { [weak self] in
                NotesRewriteController.shared.cancel()
                self?.hide()
                onCancel()
            }
        )
        let panel = panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: view)
        self.panel = panel
        place(panel)
        guard let screen = panel.screen ?? NSScreen.main else { return }
        panel.setFrame(UtilityWindowPlacement.centeredFrame(
            size: CGSize(width: 640, height: 480), in: screen.visibleFrame
        ), display: false)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func place(_ panel: NSPanel) {
        // Above the notes panel, which is floating too.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    }

    private func makePanel() -> RewritePanel {
        let panel = RewritePanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless, .titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // The proposal is a scratch surface: never part of a capture.
        panel.sharingType = .none
        return panel
    }
}

private final class RewritePanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

private struct NotesRewriteView: View {
    let onApply: (String) -> Void
    let onCancel: () -> Void

    @State private var controller = NotesRewriteController.shared
    private var theme: PaletteTheme { WorkspaceStore.shared.theme }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.border.opacity(0.6))
            preview
            Divider().overlay(theme.border.opacity(0.6))
            footer
        }
        .background(theme.surface)
        .onExitCommand(perform: onCancel)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: controller.action.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.accent)
            Text(controller.action.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.text)
            Spacer()
            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(theme.subtext)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    private var preview: some View {
        ScrollView {
            Text(controller.preview.isEmpty ? placeholder : controller.preview)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(controller.preview.isEmpty ? theme.subtext : theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if controller.isRunning {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("Copy") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(controller.preview, forType: .string)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.subtext)
            .disabled(controller.preview.isEmpty)
            .help("Copy the proposal without touching the note")
            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .foregroundStyle(theme.subtext)
                .keyboardShortcut(.cancelAction)
            Button("Apply") { onApply(controller.preview) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(controller.phase != .ready || controller.preview.isEmpty)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private var status: String {
        switch controller.phase {
        case .idle: return "Ready"
        case .running: return "Writing…"
        case .ready: return "On-device model · nothing saved yet"
        case let .failed(reason): return reason
        }
    }

    private var placeholder: String {
        switch controller.phase {
        case .running: return "The on-device model is writing the proposal…"
        case let .failed(reason): return reason
        default: return "Nothing to show yet."
        }
    }
}
