import Darwin
import Foundation
import MakiShared

// The helper's small agent-status CLI (F3 L2). It connects to the terminal
// socket, sends one closed message and exits; nothing is written to disk.

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let usage = """
usage: makidesk status working|waiting|done [--workspace <uuid>] [--title <text>]

The workspace defaults to $MAKIDESK_WORKSPACE_ID, which the terminal sets in
every pane. The title is an optional line shown as a tooltip in the sidebar.
"""

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.first == "status", arguments.count >= 2 else {
    print(usage)
    exit(2)
}
guard let state = AgentState(rawValue: arguments[1]) else {
    fail("unknown status '\(arguments[1])'; expected working, waiting or done", code: 2)
}

var workspace = ProcessInfo.processInfo.environment["MAKIDESK_WORKSPACE_ID"]
var title: String?
var index = 2
while index < arguments.count {
    switch arguments[index] {
    case "--workspace":
        index += 1
        guard index < arguments.count else { fail("--workspace needs a value", code: 2) }
        workspace = arguments[index]
    case "--title":
        index += 1
        guard index < arguments.count else { fail("--title needs a value", code: 2) }
        title = arguments[index]
    default:
        fail("unknown option '\(arguments[index])'\n\n\(usage)", code: 2)
    }
    index += 1
}

guard let raw = workspace, let id = UUID(uuidString: raw) else {
    fail("no workspace: set MAKIDESK_WORKSPACE_ID or pass --workspace", code: 2)
}

let message = TerminalMessage(
    kind: .agentStatus,
    body: .init(message: title, workspaceID: id.uuidString, agentState: state)
)
let frame = try TerminalWire.frame(message)

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
guard fd >= 0 else { fail("could not create the socket") }
defer { close(fd) }
var noSignal: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
           socklen_t(MemoryLayout<Int32>.size))

let connected = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else {
    fail("the terminal helper is not running")
}

frame.withUnsafeBytes { rawBuffer in
    guard let base = rawBuffer.baseAddress else { return }
    var offset = 0
    while offset < rawBuffer.count {
        let written = send(fd, base.advanced(by: offset), rawBuffer.count - offset, 0)
        if written <= 0 { break }
        offset += written
    }
}
