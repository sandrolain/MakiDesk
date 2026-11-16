import Foundation

/// The tmux preset (F3 L2): a session named after the workspace, attached or
/// created, so closing and reopening the pane returns to the same session.
public enum TmuxSession {
    public struct UnattachedSession: Equatable, Sendable, Identifiable {
        /// Stable tmux target (for example `$3`), safe even when a name has shell syntax.
        public let target: String
        public let name: String
        public var id: String { target }
    }

    private static let statusLock = NSLock()
    private static let statusQueue = DispatchQueue(label: "com.makidesk.terminal.tmux-status",
                                                   qos: .utility)
    private static var statusGenerations: [String: UInt64] = [:]

    /// Reads the active pane's current directory for a terminal attached to a
    /// tmux session. Call from a worker queue.
    public static func currentPaneDirectory(target: String,
                                            executable: URL? = executableURL()) -> String? {
        guard target.isEmpty == false, let executable else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["display-message", "-p", "-t", target, "#{pane_current_path}"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let timeout = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2,
                                                          execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            timeout.cancel()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let directory = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  directory.isEmpty == false else { return nil }
            return directory
        } catch {
            return nil
        }
    }

    /// Returns sessions without attached clients. Call away from the main queue.
    public static func unattachedSessions() -> [UnattachedSession] {
        guard let executable = executableURL() else { return [] }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["list-sessions", "-F", "#{session_id}\t#{session_name}\t#{session_attached}"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else { return [] }
            return text.split(whereSeparator: \.isNewline).compactMap { line in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count == 3, fields[2] == "0" else { return nil }
                return UnattachedSession(target: String(fields[0]), name: String(fields[1]))
            }
        } catch { return [] }
    }

    /// Applies the preference to a session attached by this terminal. Retries
    /// are invalidated when a newer settings value is requested.
    public static func setStatusBarVisible(_ visible: Bool, sessionName: String, attempt: Int = 0) {
        guard let executable = executableURL() else { return }
        statusLock.lock()
        let generation = (statusGenerations[sessionName] ?? 0) &+ 1
        statusGenerations[sessionName] = generation
        statusLock.unlock()
        statusQueue.async {
            applyStatusBar(visible, sessionName: sessionName, executable: executable,
                           attempt: attempt, generation: generation)
        }
    }

    private static func statusRequestIsCurrent(_ target: String, generation: UInt64) -> Bool {
        statusLock.lock()
        defer { statusLock.unlock() }
        return statusGenerations[target] == generation
    }

    private static func applyStatusBar(_ visible: Bool, sessionName: String,
                                       executable: URL, attempt: Int, generation: UInt64) {
        guard statusRequestIsCurrent(sessionName, generation: generation) else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["set-option", "-t", sessionName, "status", visible ? "on" : "off"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0, attempt < 10,
               statusRequestIsCurrent(sessionName, generation: generation) {
                statusQueue.asyncAfter(deadline: .now() + 0.4) {
                    applyStatusBar(visible, sessionName: sessionName, executable: executable,
                                   attempt: attempt + 1, generation: generation)
                }
            }
        } catch { }
    }
    public struct ExistingPaneSession: Equatable, Sendable {
        public let paneID: PaneID
        public let workspaceID: UUID?
    }

    public static func name(for workspaceID: UUID) -> String {
        "makidesk-" + workspaceID.uuidString.prefix(8).lowercased()
    }

    /// Stable name for an individual pane, so every split can reconnect to its
    /// own tmux session after the Terminal UI process exits.
    public static func name(for paneID: PaneID) -> String {
        "makidesk-pane-" + paneID.description.lowercased()
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

    public static func command(sessionName: String,
                               executable: String? = nil,
                               shellCommand: String? = nil,
                               environment: [String: String] = [:]) -> String {
        let cleaned = sessionName.filter {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
        let safe = cleaned.isEmpty ? "makidesk" : cleaned
        let binary = executable ?? executableURL()?.path ?? "tmux"
        let environmentArguments = environment.keys.sorted().map { key in
            let value = environment[key] ?? ""
            return "-e \(key)=\(value)"
        }.joined(separator: " ")
        let environmentSuffix = environmentArguments.isEmpty ? "" : " \(environmentArguments)"
        let attach = "\(binary) new-session -A\(environmentSuffix) -s \(safe)"
        guard let shellCommand,
              shellCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return attach
        }
        let quoted = "'" + shellCommand.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "\(attach) \(quoted)"
    }

    public static func command(for paneID: PaneID,
                               shellCommand: String? = nil,
                               environment: [String: String] = [:],
                               executable: String? = nil) -> String {
        command(sessionName: name(for: paneID), executable: executable,
                shellCommand: shellCommand, environment: environment)
    }

    public static func isAttachCommand(_ command: String) -> Bool {
        let parts = command.split(whereSeparator: \.isWhitespace)
        if parts.contains("new-session"), parts.contains("-A") { return sessionName(in: command) != nil }
        return parts.contains("attach-session") && attachedSessionName(in: command) != nil
    }

    public static func attachedSessionName(in command: String) -> String? {
        let parts = command.split(whereSeparator: \.isWhitespace)
        guard let flag = parts.firstIndex(of: "-t"), parts.indices.contains(flag + 1) else { return nil }
        return String(parts[flag + 1]).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }

    public static func target(in command: String) -> String? {
        sessionName(in: command) ?? attachedSessionName(in: command)
    }

    public static func sessionName(in command: String) -> String? {
        let parts = command.split(whereSeparator: \.isWhitespace)
        guard let flag = parts.firstIndex(of: "-s"),
              parts.indices.contains(flag + 1) else { return nil }
        let name = String(parts[flag + 1])
        guard name.hasPrefix("makidesk-"),
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return nil
        }
        return name
    }

    /// Ends a managed session after the user explicitly closes its pane.
    /// App termination and pane moves detach instead, so the session survives.
    public static func terminate(command: String) {
        guard let name = sessionName(in: command),
              let executable = executableURL() else { return }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["kill-session", "-t", name]
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                // A stale session is already gone; closing the pane remains complete.
            }
        }
    }

    /// Lists orphaned per-pane sessions so a crash before the layout's
    /// debounced write does not make a live tmux session unreachable. Call on
    /// a worker queue; launching or querying tmux may block.
    public static func existingPaneSessions() -> [ExistingPaneSession] {
        guard let executable = executableURL() else { return [] }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["list-sessions", "-F", "#{session_name}"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let names = String(data: data, encoding: .utf8) else { return [] }
            let paneIDs = names.split(whereSeparator: \.isNewline).compactMap { rawName -> PaneID? in
                let name = String(rawName)
                let prefix = "makidesk-pane-"
                guard name.hasPrefix(prefix),
                      let id = UUID(uuidString: String(name.dropFirst(prefix.count))) else {
                    return nil
                }
                return PaneID(raw: id)
            }
            return paneIDs.map { paneID in
                ExistingPaneSession(paneID: paneID,
                                    workspaceID: workspaceID(for: paneID,
                                                             executable: executable))
            }
        } catch {
            return []
        }
    }

    private static func workspaceID(for paneID: PaneID, executable: URL) -> UUID? {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["show-environment", "-t", name(for: paneID),
                             "MAKIDESK_WORKSPACE_ID"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let value = String(data: data, encoding: .utf8),
                  let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "=", maxSplits: 1).last else { return nil }
            return UUID(uuidString: String(raw))
        } catch {
            return nil
        }
    }
}
