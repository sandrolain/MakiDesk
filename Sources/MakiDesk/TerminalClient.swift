import AppKit
import Foundation
import MakiShared

/// The MakiDesk side of the terminal boundary (F1).
///
/// It launches the helper when needed, keeps one connection open and sends the
/// closed set of commands. All socket work is on a private queue; anything that
/// touches AppKit is dispatched to the main queue. A failed launch or timeout
/// is reported through the HUD, never by blocking a shortcut.
final class TerminalClient {
    private let queue = DispatchQueue(label: "com.makidesk.terminal.ipc.client")

    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var decoder = TerminalFrameDecoder()
    private var handshakeTimer: DispatchSourceTimer?
    private var retryWorkItem: DispatchWorkItem?
    private var retriesLeft = 0
    private var isLaunching = false

    // MARK: - Commands

    func open() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.fd >= 0 {
                self.sendLocked(TerminalMessage(kind: .showMain))
                return
            }
            self.startLocked()
        }
    }

    func send(_ kind: TerminalMessage.Kind) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.fd >= 0 {
                self.sendLocked(TerminalMessage(kind: kind))
            } else {
                self.startLocked()
            }
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
            report(.terminalNotInstalled())
            return
        }
        isLaunching = true
        launch(helper) { [weak self] launched in
            guard let self else { return }
            self.queue.async {
                self.isLaunching = false
                guard launched else {
                    self.report(.terminalNotInstalled())
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
            report(.terminalDidNotAnswer())
            return
        }
        retriesLeft -= 1
        let work = DispatchWorkItem { [weak self] in self?.retryConnectLocked() }
        retryWorkItem = work
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func connectLocked() -> Bool {
        let path = TerminalSocketLocation.socketURL.path
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
        let body = TerminalMessage.Body(
            protocolVersion: TerminalMessage.wireVersion,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            pid: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
        sendLocked(TerminalMessage(kind: .hello, body: body))

        handshakeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3)
        timer.setEventHandler { [weak self] in
            guard let self, self.fd >= 0 else { return }
            self.disconnectLocked()
            self.report(.terminalDidNotAnswer())
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

    private func handleLocked(_ message: TerminalMessage) {
        switch message.kind {
        case .welcome:
            handshakeTimer?.cancel()
            handshakeTimer = nil
            if let version = message.body?.protocolVersion,
               version != TerminalMessage.wireVersion {
                disconnectLocked()
                report(.terminalVersionMismatch())
                return
            }
            sendLocked(TerminalMessage(kind: .showMain))
        case .ping, .pong, .state, .attention, .settingsRequested, .willTerminate:
            break
        case .hello, .showMain, .hideMain, .toggleQuake, .quit:
            break
        }
    }

    private func sendLocked(_ message: TerminalMessage) {
        guard fd >= 0, let data = try? TerminalWire.frame(message) else { return }
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
            .appendingPathComponent("Contents/Applications/MakiDeskTerminal.app")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }

        // Development: `swift run` has no app bundle, so look beside the
        // repository's dist directory.
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("dist/MakiDeskTerminal.app")
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

/// The small entry point the shortcut, menu and command box call.
@MainActor
final class TerminalController {
    static let shared = TerminalController()
    private let client = TerminalClient()

    private init() {}

    func open() {
        client.open()
    }

    func toggleQuake() {
        client.send(.toggleQuake)
    }
}
