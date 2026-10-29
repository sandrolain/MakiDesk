import AppKit
import SwiftUI

/// The Settings window, owned by the app instead of a SwiftUI `Window` scene.
///
/// SwiftUI builds its windows with `.borderless` in the style mask and keeps the
/// titlebar container *behind* the hosted content, so on macOS 26 the standard
/// close / minimise / zoom buttons were drawn under the content: present, and
/// impossible to see or click (T58). An `NSWindow` created here has the standard
/// titlebar for real, like every other window of the app, and no chrome surgery
/// is needed to keep it.
@MainActor
final class SettingsController: NSObject, NSWindowDelegate {
    static let shared = SettingsController()

    private static let frameName = "MakiDeskSettingsWindow"

    private var settingsWindow: NSWindow?
    private var themeObserver: NSObjectProtocol?
    private let store = WorkspaceStore.shared

    private override init() {
        super.init()
        themeObserver = NotificationCenter.default.addObserver(
            forName: .makiDeskThemeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        }
    }

    var isVisible: Bool { settingsWindow?.isVisible == true }

    /// Opens the window, or brings it back, with the keyboard.
    func show() {
        if settingsWindow == nil { build() }
        guard let window = settingsWindow else { return }
        applyTheme()
        store.completeSetup()
        store.refreshPermissionState()
        store.refreshMacOSTiling()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let minimum = SettingsView.minimumSize
        let size = NSSize(width: max(900, minimum.width),
                          height: max(700, minimum.height))
        let panel = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        panel.title = "Settings"
        panel.isReleasedWhenClosed = false
        panel.minSize = minimum
        panel.contentMinSize = minimum
        // Above ordinary app windows, so the menu's Settings… is not lost
        // behind another app in an accessory process.
        panel.level = .floating
        panel.tabbingMode = .disallowed
        panel.isMovableByWindowBackground = false
        panel.identifier = NSUserInterfaceItemIdentifier(Self.frameName)

        let hosting = NSHostingView(rootView: SettingsView(store: store))
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting

        // AppKit restores the saved frame when the name is set; a first run
        // opens centered on the display the user is working on.
        let restored = panel.setFrameUsingName(Self.frameName)
        panel.setFrameAutosaveName(Self.frameName)
        if restored == false {
            place(panel)
        } else {
            keepOnScreen(panel)
        }

        settingsWindow = panel
        applyTheme()
    }

    private func place(_ window: NSWindow) {
        guard let screen = PaletteScreenLocation.focusedWindow.targetScreen() else {
            window.center()
            return
        }
        window.setFrame(UtilityWindowPlacement.centeredFrame(size: window.frame.size,
                                                             in: screen.visibleFrame),
                        display: false)
    }

    /// A frame saved on a display that is no longer connected would open the
    /// window off-screen.
    private func keepOnScreen(_ window: NSWindow) {
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) }
        guard visible == false else { return }
        place(window)
    }

    private func applyTheme() {
        guard let window = settingsWindow else { return }
        let theme = store.theme
        window.backgroundColor = NSColor(theme.background)
        window.appearance = theme.followsSystemAppearance
            ? nil
            : NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
    }
}
