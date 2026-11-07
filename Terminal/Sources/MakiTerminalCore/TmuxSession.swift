import Foundation

/// The tmux preset (F3 L2): a session named after the workspace, attached or
/// created, so closing and reopening the pane returns to the same session.
public enum TmuxSession {
    public static func name(for workspaceID: UUID) -> String {
        "makidesk-" + workspaceID.uuidString.prefix(8).lowercased()
    }

    /// The tmux binary, if this Mac has one. Homebrew's two prefixes come
    /// first so the helper finds it even when the login shell's PATH is odd.
    public static func executableURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fixedPaths: [String] = defaultFixedPaths,
        fileManager: FileManager = .default
    ) -> URL? {
        for path in fixedPaths where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for component in path.split(separator: ":") {
            let url = URL(fileURLWithPath: String(component)).appendingPathComponent("tmux")
            if fileManager.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    public static let defaultFixedPaths = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux",
        "/bin/tmux",
    ]

    public static func command(sessionName: String, executable: String? = nil) -> String {
        let cleaned = sessionName.filter {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
        let safe = cleaned.isEmpty ? "makidesk" : cleaned
        let binary = executable ?? executableURL()?.path ?? "tmux"
        return "\(binary) new-session -A -s \(safe)"
    }
}
