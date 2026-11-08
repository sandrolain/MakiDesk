import Foundation

/// Names both apps agree on for the terminal helper (F1/F3).
public enum TerminalIdentity {
    /// Bundle identifier of `MakiDeskTerminal.app`.
    public static let bundleIdentifier = "com.makidesk.app.terminal"

    /// The quake panel's Accessibility identifier. MakiDesk's window index uses
    /// it to leave that panel out of the switcher while still listing the
    /// helper's main window. The helper sets it in `makeQuakePanel`.
    public static let quakeAccessibilityIdentifier = "com.makidesk.terminal.quake"
}
