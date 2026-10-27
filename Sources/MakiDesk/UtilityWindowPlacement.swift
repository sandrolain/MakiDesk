import AppKit

/// Opens utility windows on the display where the focused window is.
///
/// `NSScreen.main` is the screen with the key window: while another app is in
/// front that is the app's focused window, and while one of our panels is key
/// it is that panel's screen. When the window was last used on another display
/// it is centered there instead of restoring its old position.
@MainActor
enum UtilityWindowPlacement {
    static func focusedScreen() -> NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }

    static func screen(containing frame: CGRect) -> NSScreen? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    static func sameDisplay(_ lhs: NSScreen, _ rhs: NSScreen) -> Bool {
        lhs.frame == rhs.frame
    }

    /// Centers `window` on the focused display only when it currently lives on
    /// another one; a position on the same display is kept.
    static func placeOnFocusedScreen(_ window: NSWindow) {
        guard let target = focusedScreen(),
              let current = screen(containing: window.frame),
              sameDisplay(current, target) == false else { return }
        center(window, on: target)
    }

    static func center(_ window: NSWindow, on screen: NSScreen) {
        window.setFrame(centeredFrame(size: window.frame.size, in: screen.visibleFrame),
                        display: false)
    }

    /// A centered frame clamped to the visible frame, with a margin so the
    /// window never touches the menu bar, the Dock or a screen edge. Works
    /// with negative origins.
    static func centeredFrame(size: CGSize, in visible: CGRect,
                              margin: CGFloat = 20) -> CGRect {
        let width = min(size.width, max(1, visible.width - margin * 2))
        let height = min(size.height, max(1, visible.height - margin * 2))
        return CGRect(x: (visible.midX - width / 2).rounded(),
                      y: (visible.midY - height / 2).rounded(),
                      width: width.rounded(),
                      height: height.rounded())
    }
}
