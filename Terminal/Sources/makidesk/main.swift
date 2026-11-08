import Darwin
import Foundation
import MakiShared

// The helper's small CLI (F3 L2). It connects to the terminal socket, sends one
// closed message and exits; nothing is written to disk.
//
// `status` is the explicit command an agent or a person calls, and it reports
// its failures. `hook` is what the installed agent lifecycle hooks call: it
// must never fail the agent, so a session outside a MakiDesk pane, a missing
// helper or a malformed environment all end with exit code 0 and no output.
// `hooks` installs and removes those lifecycle hooks in the agent's settings.

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let usage = """
usage: makidesk status working|waiting|done [--workspace <uuid>] [--title <text>]
       makidesk hook working|waiting|done [--title <text>]
       makidesk hooks status|install|uninstall [--agent claude|codex] [--settings <path>] [--command <path>]

status  reports an agent state; the workspace defaults to
        $MAKIDESK_WORKSPACE_ID, which the terminal sets in every pane.
hook    is the quiet form used by installed agent hooks: same message, but it
        does nothing and exits 0 when there is no MakiDesk pane or helper.
hooks   installs (or removes) MakiDesk's lifecycle hooks in a coding agent's
        settings file (Claude Code by default, or Codex). Nothing is installed
        until you ask.
"""

/// Sends one frame to the running helper. Returns false when the socket is
/// missing, unreachable or the write stopped early.
func send(_ message: TerminalMessage) -> Bool {
    guard let frame = try? TerminalWire.frame(message) else { return false }

    let path = TerminalSocketLocation.socketURL.path
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    path.withCString { source in
        withUnsafeMutablePointer(to: &address.sun_path) { sunPath in
            sunPath.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
                _ = strncpy(destination, source, 103)
            }
        }
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
               socklen_t(MemoryLayout<Int32>.size))

    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return false }

    return frame.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return false }
        var offset = 0
        while offset < rawBuffer.count {
            let written = send(fd, base.advanced(by: offset), rawBuffer.count - offset, 0)
            if written <= 0 { return false }
            offset += written
        }
        return true
    }
}

func agentMessage(state: AgentState, workspace: UUID, title: String?) -> TerminalMessage {
    TerminalMessage(
        kind: .agentStatus,
        body: .init(message: title, workspaceID: workspace.uuidString, agentState: state)
    )
}

// MARK: - status

func runStatus(_ arguments: ArraySlice<String>) -> Never {
    guard let rawState = arguments.first, let state = AgentState(rawValue: rawState) else {
        print(usage)
        exit(2)
    }

    var workspace = ProcessInfo.processInfo.environment["MAKIDESK_WORKSPACE_ID"]
    var title: String?
    var index = arguments.startIndex + 1
    while index < arguments.endIndex {
        switch arguments[index] {
        case "--workspace":
            index += 1
            guard index < arguments.endIndex else { fail("--workspace needs a value", code: 2) }
            workspace = arguments[index]
        case "--title":
            index += 1
            guard index < arguments.endIndex else { fail("--title needs a value", code: 2) }
            title = arguments[index]
        default:
            fail("unknown option '\(arguments[index])'\n\n\(usage)", code: 2)
        }
        index += 1
    }

    guard let raw = workspace, let id = UUID(uuidString: raw) else {
        fail("no workspace: set MAKIDESK_WORKSPACE_ID or pass --workspace", code: 2)
    }
    guard send(agentMessage(state: state, workspace: id, title: title)) else {
        fail("the terminal helper is not running")
    }
    exit(0)
}

// MARK: - hook

func runHook(_ arguments: ArraySlice<String>) -> Never {
    guard let rawState = arguments.first, let state = AgentState(rawValue: rawState) else {
        exit(0)
    }
    var title: String?
    var index = arguments.startIndex + 1
    while index < arguments.endIndex {
        if arguments[index] == "--title" {
            index += 1
            if index < arguments.endIndex { title = arguments[index] }
        }
        index += 1
    }
    guard let raw = ProcessInfo.processInfo.environment["MAKIDESK_WORKSPACE_ID"],
          let id = UUID(uuidString: raw) else {
        // A Claude Code or Codex session started outside a MakiDesk pane must
        // not fail, and a hook's stdout on UserPromptSubmit would be added to
        // the model's context: stay silent even on success.
        exit(0)
    }
    _ = send(agentMessage(state: state, workspace: id, title: title))
    exit(0)
}

// MARK: - hooks

func commandPath(override: String?) -> String? {
    if let override { return override }
    if TerminalCLI.isAvailable() { return TerminalCLI.stableURL.path }
    // A direct run from the bundle: install that path, but the stable symlink
    // is what survives an app that moves.
    let running = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return FileManager.default.isExecutableFile(atPath: running.path) ? running.path : nil
}

func describe(_ status: AgentHooks.Status, agent: AgentHooks.Agent,
              settings: URL) -> String {
    switch status.state {
    case .absent:
        return "\(agent.displayName) hooks: not installed (\(settings.path))"
    case .partial:
        return "\(agent.displayName) hooks: \(status.present) of \(status.expected) events installed"
    case .installed:
        return "\(agent.displayName) hooks: installed (\(status.present) events) at \(status.command ?? "an unknown path")"
    case .unreadable:
        return "\(agent.displayName) hooks: cannot read \(settings.path) — \(status.problem ?? "unknown error")"
    }
}

func runHooks(_ arguments: ArraySlice<String>) -> Never {
    guard let action = arguments.first else {
        print(usage)
        exit(2)
    }
    var agent = AgentHooks.Agent.claudeCode
    var settings: URL?
    var override: String?
    var index = arguments.startIndex + 1
    while index < arguments.endIndex {
        switch arguments[index] {
        case "--agent":
            index += 1
            guard index < arguments.endIndex else { fail("--agent needs a value", code: 2) }
            guard let parsed = AgentHooks.Agent(rawValue: arguments[index])
                    ?? (arguments[index] == "claude-code" ? .claudeCode : nil) else {
                fail("unknown agent '\(arguments[index])'; expected claude or codex", code: 2)
            }
            agent = parsed
        case "--settings":
            index += 1
            guard index < arguments.endIndex else { fail("--settings needs a value", code: 2) }
            settings = URL(fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath)
        case "--command":
            index += 1
            guard index < arguments.endIndex else { fail("--command needs a value", code: 2) }
            override = arguments[index]
        default:
            fail("unknown option '\(arguments[index])'\n\n\(usage)", code: 2)
        }
        index += 1
    }
    let url = settings ?? agent.settingsURL

    switch action {
    case "status":
        let status = AgentHooks.status(for: agent, settingsURL: url)
        print(describe(status, agent: agent, settings: url))
        exit(0)
    case "install":
        guard let path = commandPath(override: override) else {
            fail("the makidesk CLI is not available; open the terminal once and retry")
        }
        do {
            let result = try AgentHooks.install(for: agent, command: path, settingsURL: url)
            if result.changed {
                print("Installed \(agent.events.count) \(agent.displayName) hooks in \(url.path)")
                if let backup = result.backupURL {
                    print("Kept the previous file at \(backup.path)")
                }
            } else {
                print("\(agent.displayName) hooks already installed in \(url.path)")
            }
            exit(0)
        } catch {
            fail(error.localizedDescription)
        }
    case "uninstall":
        do {
            let result = try AgentHooks.uninstall(from: agent, settingsURL: url)
            if result.changed {
                print("Removed MakiDesk hooks from \(url.path)")
                if let backup = result.backupURL {
                    print("Kept the previous file at \(backup.path)")
                }
            } else {
                print("No MakiDesk hooks in \(url.path)")
            }
            exit(0)
        } catch {
            fail(error.localizedDescription)
        }
    default:
        fail("unknown action '\(action)'\n\n\(usage)", code: 2)
    }
}

// MARK: - entry

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage)
    exit(2)
}

switch command {
case "status":
    runStatus(arguments.dropFirst())
case "hook":
    runHook(arguments.dropFirst())
case "hooks":
    runHooks(arguments.dropFirst())
default:
    fail("unknown command '\(command)'\n\n\(usage)", code: 2)
}
