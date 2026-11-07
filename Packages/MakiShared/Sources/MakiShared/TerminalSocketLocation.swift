import Foundation

/// Where the two apps meet (F1).
///
/// The socket lives in the user's Application Support because both apps are
/// unsandboxed and can read it. The directory is created `0700` and the socket
/// `0600`; the helper removes a stale file only after failing to connect to it.
public enum TerminalSocketLocation {
    /// `~/Library/Application Support/MakiDesk/Terminal`.
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("MakiDesk", isDirectory: true)
            .appendingPathComponent("Terminal", isDirectory: true)
    }

    /// `~/Library/Application Support/MakiDesk/Terminal/terminal.sock`.
    public static var socketURL: URL {
        directory.appendingPathComponent("terminal.sock")
    }
}
