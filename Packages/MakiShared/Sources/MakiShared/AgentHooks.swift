import Foundation

/// Installs MakiDesk's own lifecycle hooks into a coding agent's settings file
/// (F3 L2).
///
/// An agent running inside a terminal pane inherits `MAKIDESK_WORKSPACE_ID`, so
/// a few small hooks are enough to turn its lifecycle into the sidebar dot that
/// `makidesk status` already drives: a submitted prompt is `working`, a
/// permission prompt is `waiting`, a finished turn or a closed session is
/// `done`.
///
/// Installation is **opt-in and local**: it merges handlers into the user's
/// `~/.claude/settings.json` without touching anything else in the file, keeps
/// a one-time backup, and removal takes out only handlers that call
/// `makidesk hook`. Nothing is written until the user asks for it.
public enum AgentHooks {
    /// A supported agent, where it keeps its settings and what its lifecycle
    /// offers.
    public enum Agent: String, CaseIterable, Sendable {
        case claudeCode = "claude"
        case codex

        public var displayName: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .codex: return "Codex"
            }
        }

        /// The user-wide settings file the handlers live in.
        public var settingsURL: URL {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            switch self {
            case .claudeCode:
                return home.appendingPathComponent(".claude", isDirectory: true)
                    .appendingPathComponent("settings.json")
            case .codex:
                return home.appendingPathComponent(".codex", isDirectory: true)
                    .appendingPathComponent("hooks.json")
            }
        }

        /// `SessionEnd` has a three-second ceiling in Codex; the local socket
        /// answers in milliseconds, so the smaller timeout fits both.
        public var hookTimeout: Int {
            switch self {
            case .claudeCode: return 5
            case .codex: return 3
            }
        }

        public var events: [Event] {
            switch self {
            case .claudeCode:
                return [
                    Event(name: "UserPromptSubmit", state: .working),
                    Event(name: "Notification",
                          matcher: "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input",
                          state: .waiting),
                    Event(name: "Stop", state: .done),
                    Event(name: "StopFailure", state: .done),
                    Event(name: "SessionEnd", state: .done),
                ]
            case .codex:
                // Codex has no notification event: PermissionRequest is the
                // moment it is about to wait for the user, and PreModelRequest
                // is the resume after approval, which clears the orange dot.
                // Interrupt ends a turn without a Stop, so it must clear
                // working too.
                return [
                    Event(name: "UserPromptSubmit", state: .working),
                    Event(name: "PermissionRequest", state: .waiting),
                    Event(name: "PreModelRequest", state: .working),
                    Event(name: "Stop", state: .done),
                    Event(name: "Interrupt", state: .done),
                    Event(name: "SessionEnd", state: .done),
                ]
            }
        }
    }

    /// The state a hook reports. Mirrors `AgentState` without dragging the IPC
    /// envelope into a JSON merge.
    public enum ReportedState: String, CaseIterable, Sendable {
        case working
        case waiting
        case done
    }

    /// One lifecycle event, the matcher that narrows it and the state it
    /// reports. The order is the order a turn usually meets them.
    public struct Event: Equatable, Sendable {
        public let name: String
        public let matcher: String?
        public let state: ReportedState

        public init(name: String, matcher: String? = nil, state: ReportedState) {
            self.name = name
            self.matcher = matcher
            self.state = state
        }
    }

    /// The first argument every installed handler passes to `makidesk`. It is
    /// how an installation is recognised: a moved app still has stale handlers
    /// to replace, while a user's own hooks — even ones calling `makidesk
    /// status` — are left alone.
    public static let markerArgument = "hook"

    /// What the agent's settings currently contain.
    public struct Status: Equatable, Sendable {
        public enum State: Equatable, Sendable {
            case absent
            case partial
            case installed
            /// The file exists but is not readable JSON with a `hooks` object;
            /// nothing will be written over it.
            case unreadable
        }

        public let state: State
        public let present: Int
        public let expected: Int
        /// The CLI path found in the installed handlers, when there is one.
        public let command: String?
        /// A short reason for `.unreadable`, already suitable for the UI.
        public let problem: String?

        public init(state: State, present: Int, expected: Int,
                    command: String?, problem: String?) {
            self.state = state
            self.present = present
            self.expected = expected
            self.command = command
            self.problem = problem
        }
    }

    /// What an installation or removal did.
    public struct Result: Equatable, Sendable {
        public let changed: Bool
        /// Where the pre-change file was copied, on the first modification.
        public let backupURL: URL?

        public init(changed: Bool, backupURL: URL?) {
            self.changed = changed
            self.backupURL = backupURL
        }
    }

    public enum HookError: LocalizedError, Equatable {
        case unreadable(String)
        case invalidSettings(String)
        case invalidHooks(String)
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case let .unreadable(path):
                return "Unable to read \(path)"
            case let .invalidSettings(path):
                return "\(path) is not a JSON object; nothing was changed"
            case let .invalidHooks(path):
                return "\(path) has a \"hooks\" value that is not an object; nothing was changed"
            case let .writeFailed(message):
                return "Unable to write the settings: \(message)"
            }
        }
    }

    /// The one-time copy of the file as it was before MakiDesk first changed it.
    public static func backupURL(for settingsURL: URL) -> URL {
        settingsURL.deletingLastPathComponent()
            .appendingPathComponent(settingsURL.lastPathComponent + ".makidesk-backup")
    }

    /// Reads the installation state without modifying anything.
    public static func status(for agent: Agent = .claudeCode,
                              settingsURL: URL? = nil,
                              fileManager: FileManager = .default) -> Status {
        let url = settingsURL ?? agent.settingsURL
        let events = agent.events
        let expected = events.count
        do {
            guard let root = try readRoot(url, fileManager: fileManager) else {
                return Status(state: .absent, present: 0, expected: expected,
                              command: nil, problem: nil)
            }
            let hooks = try hooksObject(in: root, path: url.path)
            var present = 0
            var commands: Set<String> = []
            for event in events {
                let groups = try groups(for: event.name, in: hooks, path: url.path)
                var found = false
                for group in groups {
                    for handler in handlers(in: group) where
                        handlerState(handler) == event.state {
                        found = true
                        if let command = handler["command"] as? String {
                            commands.insert(command)
                        }
                    }
                }
                if found { present += 1 }
            }
            let state: Status.State = present == 0 ? .absent
                : (present == expected ? .installed : .partial)
            return Status(state: state, present: present, expected: expected,
                          command: commands.sorted().first, problem: nil)
        } catch {
            return Status(state: .unreadable, present: 0, expected: expected,
                          command: nil, problem: error.localizedDescription)
        }
    }

    /// Merges one handler per event and reports whether the file changed.
    ///
    /// `command` must be an absolute path to the `makidesk` CLI. The stable
    /// symlink under Application Support is the right choice: it survives an
    /// app that moves, so the hooks keep working after an update.
    @discardableResult
    public static func install(for agent: Agent = .claudeCode,
                               command: String,
                               settingsURL: URL? = nil,
                               fileManager: FileManager = .default) throws -> Result {
        guard command.hasPrefix("/") else {
            throw HookError.writeFailed("the hook command must be an absolute path")
        }
        let url = settingsURL ?? agent.settingsURL
        let original = try readRoot(url, fileManager: fileManager)
        var root = original ?? [:]
        var hooks = try hooksObject(in: root, path: url.path)
        pruneAll(&hooks)

        for event in agent.events {
            var groups = try groups(for: event.name, in: hooks, path: url.path)
            var group: [String: Any] = [:]
            if let matcher = event.matcher { group["matcher"] = matcher }
            group["hooks"] = [handler(for: event, command: command,
                                      title: agent.displayName,
                                      timeout: agent.hookTimeout)]
            groups.append(group)
            hooks[event.name] = groups
        }
        root["hooks"] = hooks

        guard changed(root, from: original) else {
            return Result(changed: false, backupURL: nil)
        }
        let backup = try backUpIfNeeded(url, fileManager: fileManager)
        try write(root, to: url, fileManager: fileManager)
        return Result(changed: true, backupURL: backup)
    }

    /// Removes every handler that calls `makidesk hook`, and the groups and
    /// event arrays that become empty. Other handlers and every other key in
    /// the file stay exactly as they were.
    @discardableResult
    public static func uninstall(from agent: Agent = .claudeCode,
                                 settingsURL: URL? = nil,
                                 fileManager: FileManager = .default) throws -> Result {
        let url = settingsURL ?? agent.settingsURL
        guard let original = try readRoot(url, fileManager: fileManager) else {
            return Result(changed: false, backupURL: nil)
        }
        var root = original
        guard let value = root["hooks"] else {
            return Result(changed: false, backupURL: nil)
        }
        guard var hooks = value as? [String: Any] else {
            throw HookError.invalidHooks(url.path)
        }
        pruneAll(&hooks)
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        guard changed(root, from: original) else {
            return Result(changed: false, backupURL: nil)
        }
        // The one-time backup belongs to the first install; removal writes the
        // file without replacing that copy.
        try write(root, to: url, fileManager: fileManager)
        return Result(changed: true, backupURL: nil)
    }

    // MARK: - JSON

    private static func handler(for event: Event, command: String,
                                title: String, timeout: Int) -> [String: Any] {
        [
            "type": "command",
            "command": command,
            "args": [markerArgument, event.state.rawValue, "--title", title],
            "timeout": timeout,
        ]
    }

    /// The state a handler reports when it is one of ours.
    private static func handlerState(_ handler: [String: Any]) -> ReportedState? {
        guard handler["type"] as? String == "command",
              let arguments = handler["args"] as? [String],
              arguments.count >= 2,
              arguments[0] == markerArgument else { return nil }
        return ReportedState(rawValue: arguments[1])
    }

    /// Drops our handlers from a group, and the group itself when it is left
    /// with no handlers.
    private static func prune(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group in
            guard var handlers = group["hooks"] as? [[String: Any]] else { return group }
            handlers.removeAll { handlerState($0) != nil }
            guard handlers.isEmpty == false else { return nil }
            var copy = group
            copy["hooks"] = handlers
            return copy
        }
    }

    /// Applies `prune` to every event, including events this version no longer
    /// installs, so an older installation leaves nothing behind. A value that
    /// is not an array of groups is left alone: it belongs to someone else.
    private static func pruneAll(_ hooks: inout [String: Any]) {
        for (name, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = prune(groups)
            if kept.isEmpty {
                hooks.removeValue(forKey: name)
            } else {
                hooks[name] = kept
            }
        }
    }

    private static func handlers(in group: [String: Any]) -> [[String: Any]] {
        group["hooks"] as? [[String: Any]] ?? []
    }

    private static func hooksObject(in root: [String: Any],
                                    path: String) throws -> [String: Any] {
        guard let value = root["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else {
            throw HookError.invalidHooks(path)
        }
        return hooks
    }

    private static func groups(for event: String, in hooks: [String: Any],
                               path: String) throws -> [[String: Any]] {
        guard let value = hooks[event] else { return [] }
        guard let groups = value as? [[String: Any]] else {
            throw HookError.invalidHooks(path)
        }
        return groups
    }

    private static func readRoot(_ url: URL,
                                 fileManager: FileManager) throws -> [String: Any]? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = fileManager.contents(atPath: url.path) else {
            throw HookError.unreadable(url.path)
        }
        guard data.isEmpty == false else { return [:] }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw HookError.invalidSettings(url.path)
        }
        guard let root = object as? [String: Any] else {
            throw HookError.invalidSettings(url.path)
        }
        return root
    }

    private static func write(_ root: [String: Any], to url: URL,
                              fileManager: FileManager) throws {
        let permissions = (try? fileManager.attributesOfItem(atPath: url.path))?[.posixPermissions]
        do {
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            var payload = data
            payload.append(0x0A)
            try payload.write(to: url, options: .atomic)
            if let permissions {
                // Atomic replacement would otherwise reset the mode.
                try? fileManager.setAttributes([.posixPermissions: permissions],
                                               ofItemAtPath: url.path)
            }
        } catch let error as HookError {
            throw error
        } catch {
            throw HookError.writeFailed(error.localizedDescription)
        }
    }

    private static func backUpIfNeeded(_ url: URL,
                                       fileManager: FileManager) throws -> URL? {
        let backup = backupURL(for: url)
        guard fileManager.fileExists(atPath: url.path),
              fileManager.fileExists(atPath: backup.path) == false else { return nil }
        do {
            try fileManager.copyItem(at: url, to: backup)
            return backup
        } catch {
            throw HookError.writeFailed(error.localizedDescription)
        }
    }

    private static func changed(_ root: [String: Any],
                                from original: [String: Any]?) -> Bool {
        guard let original else { return root.isEmpty == false }
        return NSDictionary(dictionary: root).isEqual(to: original) == false
    }
}
