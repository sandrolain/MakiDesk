import Foundation

/// The block "Copy diagnostics" puts on the clipboard (R11).
///
/// Counts, states and versions only — no window titles, note text, clipboard
/// payloads, file paths or screenshots — so the report can be pasted into an
/// issue as it stands. Every field is a value, so a test can pin the format
/// and nobody has to read the log to know what a machine is doing.
struct DiagnosticsReport: Equatable {
    var appVersion: String
    var macOS: String
    var accessibility: Bool
    var screenRecording: Bool
    var shortcutsRegistered: Int
    var shortcutsBlocked: Int
    var shortcutsModified: Int
    var shortcutFile: String
    var windows: Int
    var groups: Int

    var text: String {
        [
            "MakiDesk \(appVersion)",
            "macOS \(macOS)",
            "Accessibility: \(accessibility ? "on" : "off")",
            "Screen Recording: \(screenRecording ? "on" : "off")",
            "Shortcuts: \(shortcutsRegistered) active, \(shortcutsBlocked) taken, \(shortcutsModified) customised",
            "shortcuts.json: \(shortcutFile)",
            "Windows known: \(windows) · groups: \(groups)",
            "Capture budget: \(CaptureBudget.totalBytes / (1024 * 1024)) MiB",
        ].joined(separator: "\n")
    }
}
