import Foundation

/// Names both apps agree on for the Docker helper.
public enum DockerIdentity {
    /// Bundle identifier of `MakiDeskDocker.app`.
    public static let bundleIdentifier = "com.makidesk.app.docker"

    /// The executable inside the bundle.
    public static let executableName = "MakiDeskDocker"

    /// The app bundle name, used when MakiDesk looks for the helper.
    public static let bundleName = "MakiDeskDocker.app"
}

/// The closed set of values the terminal helper accepts for a container shell.
///
/// The Docker helper sends a shell name, never a command line: the terminal
/// composes `docker exec -it <container> <shell>` itself. Keeping the check in
/// one shared place means the app, the bridge and the terminal cannot drift.
public enum DockerExecValidation {
    public static let shells = ["sh", "bash", "ash", "zsh"]

    /// A hex container id (12–64 chars) or a Docker container name.
    public static func isValidContainerID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed.count <= 128 else { return false }
        let hex = trimmed.lowercased()
        if hex.count >= 12, hex.count <= 64,
           hex.allSatisfy({ $0.isHexDigit }) {
            return true
        }
        // Docker names: [a-zA-Z0-9][a-zA-Z0-9_.-]*
        guard let first = trimmed.first,
              first.isLetter || first.isNumber else { return false }
        return trimmed.dropFirst().allSatisfy { character in
            character.isLetter || character.isNumber
                || character == "_" || character == "." || character == "-"
        }
    }

    public static func isValidShell(_ value: String) -> Bool {
        shells.contains(value)
    }

    /// A shell-safe representation for the terminal's command string.
    public static func quoted(_ value: String) -> String {
        let safe = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%_-./:~")
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The exact command a terminal pane runs. Nil for an invalid request.
    public static func command(containerID: String, shell: String) -> String? {
        guard isValidContainerID(containerID), isValidShell(shell) else { return nil }
        return "docker exec -it \(quoted(containerID)) \(quoted(shell))"
    }
}
