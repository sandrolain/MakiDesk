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
            // Key absent (`defaults` exits non-zero) → system default, enabled.
            guard let raw = read(optionAcceleratorKey) else { return true }
            return raw == "1"
        }
        set {
            _ = run(["/usr/bin/defaults", "write", domain, optionAcceleratorKey,
                     "-bool", newValue ? "true" : "false"])
        }
    }

    private static func read(_ key: String) -> String? {
        guard let output = run(["/usr/bin/defaults", "read", domain, key]) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Runs `/usr/bin/defaults …`; returns stdout on success, `nil` otherwise.
    @discardableResult
    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
