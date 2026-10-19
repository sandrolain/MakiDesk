import AppKit
import SwiftUI

/// The peek overlay (T16): what ⌃⌥H shows while it is held, and nothing more.
///
/// Read-only by construction — the panel never becomes key, takes no click and
/// no keystroke, and the mouse passes straight through — so the window on
/// screen, and the app in use, keep everything they had. Modelled on
/// `HUDController`'s non-activating panel.
final class PeekPanel {
    static let shared = PeekPanel()

    private var panel: NSPanel?

    /// How much of the screen the image may take, at most.
    private static let screenFraction: CGFloat = 0.7
    /// Size of the placeholder shown while the live capture is on its way.
    private static let placeholder = CGSize(width: 360, height: 220)

    private init() {}

    /// Shows `image` (or a placeholder, when the capture has not come back yet)
    /// for `appName`, centred on the screen the pointer is on. `badge` marks the
    /// state the window is in — "Non più aperta" when it has since been closed.
    func show(image: NSImage?, appName: String, badge: String?) {
        guard let screen = screenUnderPointer() else { return }
        let visible = WindowController.axVisibleFrame(for: screen)
        let imageSize = fitting(image?.size, in: visible)
        let hosting = NSHostingView(rootView: PeekView(
            image: image, imageSize: imageSize, appName: appName, badge: badge
        ))
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = hosting
        let size = hosting.fittingSize
        guard size.width > 1, size.height > 1 else { return }
        panel.setFrame(CGRect(x: visible.midX - size.width / 2,
                              y: visible.midY - size.height / 2,
                              width: size.width, height: size.height),
                       display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// The largest the image may be drawn: never enlarged past its own pixels,
    /// never more than `screenFraction` of the screen, proportions kept.
    private func fitting(_ size: CGSize?, in visible: CGRect) -> CGSize {
        guard let size, size.width > 1, size.height > 1 else {
            return CGSize(width: min(Self.placeholder.width, visible.width * Self.screenFraction),
                          height: min(Self.placeholder.height, visible.height * Self.screenFraction))
        }
        let scale = min(1,
                        visible.width * Self.screenFraction / size.width,
                        visible.height * Self.screenFraction / size.height)
        return CGSize(width: (size.width * scale).rounded(),
                      height: (size.height * scale).rounded())
    }

    private func screenUnderPointer() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
    }

    private func makePanel() -> NSPanel {
        let panel = PeekPanelWindow(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Never in a screen share: the peek shows a window that is hidden from
        // the desktop, and putting it on the wire would give it away.
        panel.sharingType = .none
        return panel
    }
}

/// A borderless panel that can never become key or main: showing it takes
/// nothing away from the app in use.
private final class PeekPanelWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct PeekView: View {
    let image: NSImage?
    let imageSize: CGSize
    let appName: String
    let badge: String?

    /// In-theme, so the overlay belongs with the palette and the HUD.
    private var theme: PaletteTheme { WorkspaceStore.shared.theme }

    var body: some View {
        VStack(spacing: 10) {
            preview
            footer
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(theme.border, lineWidth: 1)
                )
        )
    }

    private var preview: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                // Waveform of a window still being captured: the overlay appears
                // at once rather than a beat after the key.
                ZStack {
                    Rectangle().fill(theme.background.opacity(0.55))
                    Image(systemName: "eye")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(theme.subtext)
                }
            }
        }
        .frame(width: imageSize.width, height: imageSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.accent)
            Text(appName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            if let badge {
                Text(badge)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.background)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.accent))
            }
            Spacer(minLength: 0)
        }
        .frame(width: imageSize.width)
    }
}
