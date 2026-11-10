import AppKit
import Darwin
import Foundation
import MakiShared

/// The helper side of the MakiDesk ↔ Docker socket. One listener, one client
/// (MakiDesk), length-prefixed JSON and a closed message set.
final class DockerIPCServer {
    private let queue = DispatchQueue(label: "com.makidesk.docker.ipc.server")
    private let socketURL: URL

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientFD: Int32 = -1
    private var clientSource: DispatchSourceRead?
    private var decoder = DockerFrameDecoder()
    private var running = false

    var onShowMain: (() -> Void)?
    var onHideMain: (() -> Void)?
    var onQuit: (() -> Void)?
    var onThemeChanged: (() -> Void)?

    init(socketURL: URL = DockerSocketLocation.socketURL) {
        self.socketURL = socketURL
    }

    var hasClient: Bool {
        queue.sync { clientFD >= 0 }
    }

    func start(completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            let started = self?.startLocked() ?? false
            DispatchQueue.main.async { completion(started) }
        }
    }

    func stop() {
        queue.sync { [weak self] in self?.stopLocked() }
    }

    /// Sends one event to MakiDesk. Returns false when MakiDesk is not
    /// connected; the caller shows the user what to do.
    @discardableResult
    func sendOpenExec(containerID: String, shell: String, title: String) -> Bool {
        queue.sync {
            guard clientFD >= 0,
                  DockerExecValidation.isValidContainerID(containerID),
                  DockerExecValidation.isValidShell(shell) else { return false }
            send(DockerMessage(
                kind: .openExec,
                body: .init(containerID: containerID, shell: shell, title: title)
            ))
            return true
        }
    }

    private func startLocked() -> Bool {
        guard running == false else { return true }
        try? FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: socketURL.path) {
            if canConnect(to: socketURL) { return false }
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

    private func acceptClient() {
        guard listenFD >= 0 else { return }
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        if let peer = peerPID(for: client), peerIsMakiDesk(peer) == false {
            close(client)
            return
        }
        if clientFD >= 0 { disconnectClient() }

        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                   socklen_t(MemoryLayout<Int32>.size))
        clientFD = client
        decoder.reset()

        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        source.setEventHandler { [weak self] in self?.readClient() }
        source.resume()
        clientSource = source
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

    private func handle(_ message: DockerMessage) {
        switch message.kind {
        case .hello:
            send(DockerMessage(
                kind: .welcome,
                body: .init(protocolVersion: DockerMessage.wireVersion,
                            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                            pid: getpid(),
                            bundleIdentifier: Bundle.main.bundleIdentifier),
                id: message.id
            ))
        case .ping:
            send(DockerMessage(kind: .pong, id: message.id))
        case .showMain:
            DispatchQueue.main.async { [weak self] in self?.onShowMain?() }
        case .hideMain:
            DispatchQueue.main.async { [weak self] in self?.onHideMain?() }
        case .quit:
            DispatchQueue.main.async { [weak self] in self?.onQuit?() }
        case .themeChanged:
            DispatchQueue.main.async { [weak self] in self?.onThemeChanged?() }
        case .welcome, .pong, .openExec, .state, .willTerminate:
            break
        }
    }

    private func send(_ message: DockerMessage) {
        guard clientFD >= 0, let data = try? DockerWire.frame(message) else { return }
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

    private func peerPID(for fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, 0, 2, &pid, &size) == 0, pid > 0 else { return nil }
        return pid
    }

    private func peerIsMakiDesk(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        if app.bundleIdentifier == "com.makidesk.app" { return true }
        return app.executableURL?.lastPathComponent == "MakiDesk"
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
