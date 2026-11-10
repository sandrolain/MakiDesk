import AppKit
import Foundation
import MakiShared
import Observation

/// The MakiDesk side of the Docker helper. It keeps one socket connection,
/// launches the helper on demand and forwards the one cross-app request —
/// opening a container terminal — to the terminal helper.
final class DockerClient {
    private let queue = DispatchQueue(label: "com.makidesk.docker.ipc.client")

    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var decoder = DockerFrameDecoder()
    private var handshakeTimer: DispatchSourceTimer?
    private var retryWorkItem: DispatchWorkItem?
    private var retriesLeft = 0
    private var isLaunching = false
    private var pending: [DockerMessage] = []

    func open() {
        enqueue(DockerMessage(kind: .showMain))
    }

    func send(_ kind: DockerMessage.Kind, body: DockerMessage.Body? = nil) {
        enqueue(DockerMessage(kind: kind, body: body))
    }

    func notify(_ kind: DockerMessage.Kind) {
        queue.async { [weak self] in
            guard let self, self.fd >= 0 else { return }
            self.sendLocked(DockerMessage(kind: kind))
        }
    }

    private func enqueue(_ message: DockerMessage) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.fd >= 0 {
                self.sendLocked(message)
                return
            }
            self.pending.append(message)
            self.startLocked()
        }
    }

    // MARK: - Connection

    private func startLocked() {
        guard isLaunching == false else { return }
        if connectLocked() {
            beginHandshakeLocked()
            return
        }
        guard let helper = helperURL() else {
            pending.removeAll()
            report(.dockerNotInstalled())
            return
        }
        isLaunching = true
        launch(helper) { [weak self] launched in
            guard let self else { return }
            self.queue.async {
                self.isLaunching = false
                guard launched else {
                    self.pending.removeAll()
                    self.report(.dockerNotInstalled())
                    return
                }
                self.retriesLeft = 30
                self.retryConnectLocked()
            }
        }
    }

    private func retryConnectLocked() {
        if connectLocked() {
            beginHandshakeLocked()
            return
        }
        guard retriesLeft > 0 else {
            pending.removeAll()
            report(.dockerDidNotAnswer())
            return
        }
        retriesLeft -= 1
        let work = DispatchWorkItem { [weak self] in self?.retryConnectLocked() }
        retryWorkItem = work
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func connectLocked() -> Bool {
        let path = DockerSocketLocation.socketURL.path
        guard FileManager.default.fileExists(atPath: path) else { return false }

        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }

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

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(socketFD)
            return false
        }

        var noSignal: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                   socklen_t(MemoryLayout<Int32>.size))
        fd = socketFD
        decoder.reset()

        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in self?.readLocked() }
        source.resume()
        readSource = source
        return true
    }

    private func beginHandshakeLocked() {
        let body = DockerMessage.Body(
            protocolVersion: DockerMessage.wireVersion,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            pid: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
        sendLocked(DockerMessage(kind: .hello, body: body))

        handshakeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3)
        timer.setEventHandler { [weak self] in
            guard let self, self.fd >= 0 else { return }
            self.disconnectLocked()
            self.pending.removeAll()
            self.report(.dockerDidNotAnswer())
        }
        timer.resume()
        handshakeTimer = timer
    }

    // MARK: - Reading

    private func readLocked() {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else {
            disconnectLocked()
            return
        }
        do {
            let messages = try decoder.append(Data(buffer[0..<count]))
            for message in messages { handleLocked(message) }
        } catch {
            disconnectLocked()
        }
    }

    private func handleLocked(_ message: DockerMessage) {
        switch message.kind {
        case .welcome:
            handshakeTimer?.cancel()
            handshakeTimer = nil
            if let version = message.body?.protocolVersion,
               version != DockerMessage.wireVersion {
                disconnectLocked()
                pending.removeAll()
                report(.dockerVersionMismatch())
                return
            }
            let queued = pending
            pending.removeAll()
            if queued.isEmpty {
                sendLocked(DockerMessage(kind: .showMain))
            } else {
                for message in queued { sendLocked(message) }
            }
            sendLocked(DockerMessage(kind: .themeChanged))
        case .openExec:
            guard let containerID = message.body?.containerID,
                  let shell = message.body?.shell,
                  DockerExecValidation.isValidContainerID(containerID),
                  DockerExecValidation.isValidShell(shell) else { return }
            let title = message.body?.title
            DispatchQueue.main.async {
                TerminalController.shared.openDockerExec(
                    containerID: containerID,
                    shell: shell,
                    title: title
                )
            }
        case .state, .willTerminate:
            break
        case .hello, .pong, .showMain, .hideMain, .quit, .themeChanged, .ping:
            break
        }
    }

    private func sendLocked(_ message: DockerMessage) {
        guard fd >= 0, let data = try? DockerWire.frame(message) else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.send(fd, base.advanced(by: offset),
                                          raw.count - offset, 0)
                if written <= 0 {
                    disconnectLocked()
                    return
                }
                offset += written
            }
        }
    }

    private func disconnectLocked() {
        handshakeTimer?.cancel()
        handshakeTimer = nil
        retryWorkItem?.cancel()
        retryWorkItem = nil
        readSource?.cancel()
        readSource = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        decoder.reset()
    }

    // MARK: - Launch and errors

    private func helperURL() -> URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Applications/\(DockerIdentity.bundleName)")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }

        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("dist/\(DockerIdentity.bundleName)")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        return nil
    }

    private func launch(_ url: URL, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                completion(error == nil)
            }
        }
    }

    private func report(_ message: HUDMessage) {
        DispatchQueue.main.async {
            HUDController.shared.show(message)
        }
    }
}

@Observable
@MainActor
final class DockerController {
    static let shared = DockerController()

    @ObservationIgnored private let client = DockerClient()
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var lastFrontmost = false

    private init() {}

    func start() {
        syncTheme()
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.updateFrontmost(app)
            }
        }
        updateFrontmost(NSWorkspace.shared.frontmostApplication)
    }

    func open() {
        client.open()
    }

    func themeDidChange() {
        syncTheme()
        client.notify(.themeChanged)
    }

    private func syncTheme() {
        let document = TerminalThemeDocument(palette: WorkspaceStore.shared.theme)
        let store = TerminalThemeStore(
            fileURL: DockerSocketLocation.directory.appendingPathComponent("theme.json")
        )
        _ = store.save(document)
    }

    private func updateFrontmost(_ app: NSRunningApplication?) {
        let docker = isDockerHelper(app)
        guard docker != lastFrontmost else { return }
        lastFrontmost = docker
        WorkspaceStore.shared.setDockerFrontmost(docker)
    }

    private func isDockerHelper(_ app: NSRunningApplication?) -> Bool {
        guard let app else { return false }
        if app.bundleIdentifier == DockerIdentity.bundleIdentifier { return true }
        return app.executableURL?.lastPathComponent == DockerIdentity.executableName
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }
}
