import AppKit
import Darwin
import Foundation
import MakiShared

/// The helper side of the MakiDesk ↔ Terminal socket (F1).
///
/// One listener, one client (MakiDesk), length-prefixed JSON. All socket work
/// runs on a private serial queue; the closures that touch AppKit are called on
/// the main queue. The socket is `0600` inside a `0700` directory, and the peer
/// is checked to be MakiDesk (bundle id, or the development binary by name).
final class TerminalIPCServer {
    private let queue = DispatchQueue(label: "com.makidesk.terminal.ipc.server")
    private let socketURL: URL

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientFD: Int32 = -1
    private var clientSource: DispatchSourceRead?
    private var decoder = TerminalFrameDecoder()
    private var running = false

    /// Main-queue callbacks. The app delegate wires them to its windows.
    var onShowMain: (() -> Void)?
    var onHideMain: (() -> Void)?
    var onToggleQuake: (() -> Void)?
    var onQuit: (() -> Void)?
    var onSettingsChanged: (() -> Void)?
    var onThemeChanged: (() -> Void)?
    var onAgentStatus: ((UUID, AgentState, String?) -> Void)?
    var onPeerConnected: (() -> Void)?

    init(socketURL: URL = TerminalSocketLocation.socketURL) {
        self.socketURL = socketURL
    }

    // MARK: - Lifecycle

    /// Binds and starts accepting. The completion is on the main queue and is
    /// false when another helper already owns the socket.
    func start(completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            let started = self?.startLocked() ?? false
            DispatchQueue.main.async { completion(started) }
        }
    }

    func stop() {
        queue.sync { [weak self] in
            self?.stopLocked()
        }
    }

    /// Sends a shell desktop notification to MakiDesk, which turns it into a
    /// notice. Dropped when no client is connected: the terminal keeps working.
    func sendAttention(title: String, detail: String) {
        queue.async { [weak self] in
            guard let self, self.clientFD >= 0 else { return }
            self.send(TerminalMessage(kind: .attention,
                                      body: .init(message: title, detail: detail)))
        }
    }

    private func startLocked() -> Bool {
        guard running == false else { return true }

        try? FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])

        if FileManager.default.fileExists(atPath: socketURL.path) {
            if canConnect(to: socketURL) {
                return false
            }
            try? FileManager.default.removeItem(at: socketURL)
        }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { sunPath in
                sunPath.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
                    _ = strncpy(destination, source, 103)
                }
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                   socklen_t(MemoryLayout<Int32>.size))

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            return false
        }
        chmod(path, 0o600)

        listenFD = fd
        running = true

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.resume()
        acceptSource = source
        return true
    }

    private func stopLocked() {
        guard running else { return }
        running = false
        disconnectClient()
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        try? FileManager.default.removeItem(at: socketURL)
    }

    // MARK: - Accepting

    private func acceptClient() {
        guard listenFD >= 0 else { return }
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }

        if let peer = peerPID(for: client), peerIsMakiDesk(peer) == false {
            close(client)
            return
        }

        if clientFD >= 0 {
            // One client at a time: MakiDesk is the only one that should be here.
            disconnectClient()
        }

        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                   socklen_t(MemoryLayout<Int32>.size))
        clientFD = client
        decoder.reset()

        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        source.setEventHandler { [weak self] in self?.readClient() }
        source.resume()
        clientSource = source

        DispatchQueue.main.async { [weak self] in self?.onPeerConnected?() }
    }

    private func readClient() {
        guard clientFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let count = recv(clientFD, &buffer, buffer.count, 0)
        guard count > 0 else {
            disconnectClient()
            return
        }
        do {
            let messages = try decoder.append(Data(buffer[0..<count]))
            for message in messages { handle(message) }
        } catch {
            disconnectClient()
        }
    }

    private func disconnectClient() {
        let fd = clientFD
        clientFD = -1
        clientSource?.cancel()
        clientSource = nil
        if fd >= 0 { close(fd) }
        decoder.reset()
    }

    // MARK: - Messages

    private func handle(_ message: TerminalMessage) {
        switch message.kind {
        case .hello:
            let body = TerminalMessage.Body(
                protocolVersion: TerminalMessage.wireVersion,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                pid: getpid(),
                bundleIdentifier: Bundle.main.bundleIdentifier
            )
            send(TerminalMessage(kind: .welcome, body: body, id: message.id))
        case .ping:
            send(TerminalMessage(kind: .pong, id: message.id))
        case .showMain:
            DispatchQueue.main.async { [weak self] in self?.onShowMain?() }
        case .hideMain:
            DispatchQueue.main.async { [weak self] in self?.onHideMain?() }
        case .toggleQuake:
            DispatchQueue.main.async { [weak self] in self?.onToggleQuake?() }
        case .quit:
            DispatchQueue.main.async { [weak self] in self?.onQuit?() }
        case .settingsChanged:
            DispatchQueue.main.async { [weak self] in self?.onSettingsChanged?() }
        case .themeChanged:
            DispatchQueue.main.async { [weak self] in self?.onThemeChanged?() }
        case .agentStatus:
            guard let raw = message.body?.workspaceID,
                  let id = UUID(uuidString: raw),
                  let state = message.body?.agentState else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onAgentStatus?(id, state, message.body?.message)
            }
        case .welcome, .pong, .state, .attention, .settingsRequested, .willTerminate:
            break
        }
    }

    private func send(_ message: TerminalMessage) {
        guard clientFD >= 0, let data = try? TerminalWire.frame(message) else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.send(clientFD, base.advanced(by: offset),
                                          raw.count - offset, 0)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    // MARK: - Peer

    private func peerPID(for fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        // LOCAL_PEERPID is 2 in <sys/un.h>; SOL_LOCAL is 0 on Darwin.
        guard getsockopt(fd, 0, 2, &pid, &size) == 0, pid > 0 else { return nil }
        return pid
    }

    private func peerIsMakiDesk(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        if app.bundleIdentifier == "com.makidesk.app" { return true }
        // `swift run` has no app bundle; the executable name is still MakiDesk.
        if app.executableURL?.lastPathComponent == "MakiDesk" { return true }
        // The helper's own CLI: the closed status message is all it can send.
        return app.executableURL?.lastPathComponent == "makidesk"
    }

    private func canConnect(to url: URL) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        url.path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { sunPath in
                sunPath.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
                    _ = strncpy(destination, source, 103)
                }
            }
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
    }
}
