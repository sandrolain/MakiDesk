import AppKit
import SwiftUI

/// A small, non-activating notification that confirms a group action (added /
/// removed / recalled), on the model of the system volume indicator. Purely
/// visual: it ignores the mouse and disappears on its own.
final class HUDController {
    static let shared = HUDController()

    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    private init() {}

    /// Shows `text` with `symbol` for a moment, replacing any notice on screen.
    /// `duration` is how long it stays; the couple of seconds a confirmation
    /// needs is the default, an offer waiting to be accepted asks for longer.
    func show(_ text: String, symbol: String = "checkmark.circle.fill", duration: TimeInterval = 1.4) {
        if Thread.isMainThread {
            present(text, symbol: symbol, duration: duration)
        } else {
            DispatchQueue.main.async { [weak self] in self?.present(text, symbol: symbol, duration: duration) }
        }
    }

    private func present(_ text: String, symbol: String, duration: TimeInterval) {
        guard let screen = NSScreen.main else { return }
        let hosting = NSHostingView(rootView: HUDView(text: text, symbol: symbol))
        let size = hosting.fittingSize
        guard size.width > 1, size.height > 1 else { return }

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = hosting

        let visible = screen.visibleFrame
        let origin = CGPoint(x: visible.midX - size.width / 2,
                             y: visible.minY + visible.height * 0.16)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()

        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }
}

private struct HUDView: View {
    let text: String
    let symbol: String

    /// In-theme so the notice never clashes with the palette.
    private var theme: PaletteTheme { WorkspaceStore.shared.theme }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.accent)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.text)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(theme.border, lineWidth: 1)
                )
        )
    }
}
