import Foundation

/// macOS's own "Hold ⌥ while dragging windows to tile" behaviour
/// (System Settings ▸ Desktop & Dock ▸ Windows).
///
/// It lives in the private `com.apple.WindowManager` domain as
/// `EnableTilingOptionAccelerator`. The key is absent until the setting is
/// touched once, and the system default is **on**. MakiDesk's ⌥-drag is meant
/// to *replace* it, so we detect it and let the user switch it off from our
/// Settings instead of sending them hunting through System Settings.
///
/// Reading/writing goes through `/usr/bin/defaults` so it behaves exactly like
/// the documented Terminal command (and gives us the exit code that tells
/// whether the key exists at all).
enum MacOSTiling {
    static let domain = "com.apple.WindowManager"
    static let optionAcceleratorKey = "EnableTilingOptionAccelerator"

    /// `true` when macOS tiles windows dragged with `⌥` held.
    static var optionDragEnabled: Bool {
        get {
            // Key absent → system default, enabled. Reading the preference
            // through CFPreferences avoids spawning and waiting for `defaults`
            // on startup or whenever Settings refreshes this value.
            guard let preferences = UserDefaults(suiteName: domain),
                  preferences.object(forKey: optionAcceleratorKey) != nil else { return true }
            return preferences.bool(forKey: optionAcceleratorKey)
        }
        set {
            guard let preferences = UserDefaults(suiteName: domain) else { return }
            preferences.set(newValue, forKey: optionAcceleratorKey)
            preferences.synchronize()
        }
    }
}
