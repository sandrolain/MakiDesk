import Foundation
import Darwin
import MakiTerminalCore

protocol AccountUsageProvider: AnyObject {
    func refresh(completion: @escaping (Result<CodexAccountUsage, Error>) -> Void)
    func cancel()
}

/// Owns one short-lived app-server process at a time. It uses only the two
/// documented, read-only account methods and never connects to the shared daemon.
final class CodexAccountUsageReader: AccountUsageProvider {
    private let queue = DispatchQueue(label: "com.makidesk.terminal.codex-account-usage", qos: .utility)
    private let lock = NSLock()
    private var process: Process?
    private var generation: UInt64 = 0
    private var timedOutGeneration: UInt64?
    private var workerRunning = false
    private var pendingRequest: RefreshRequest?

    private struct RefreshRequest {
        let generation: UInt64
        let completion: (Result<CodexAccountUsage, Error>) -> Void
    }

    func refresh(completion: @escaping (Result<CodexAccountUsage, Error>) -> Void) {
        lock.lock()
        generation &+= 1
        let request = RefreshRequest(generation: generation, completion: completion)
        let shouldStartWorker = workerRunning == false
        if shouldStartWorker {
            workerRunning = true
        } else {
            // Repeated visibility changes replace the queued refresh instead of
            // growing an unbounded serial DispatchQueue backlog.
            pendingRequest = request
        }
        lock.unlock()
        if shouldStartWorker {
            queue.async { [weak self] in self?.drain(request) }
        }
    }

    func cancel() {
        lock.lock()
        generation &+= 1
        pendingRequest = nil
        let active = process
        process = nil
        lock.unlock()
        guard let active, active.isRunning else { return }
        active.terminate()
        let pid = active.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            if active.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func drain(_ first: RefreshRequest) {
        var next: RefreshRequest? = first
        while let request = next {
            let result = Result { try readAccountUsage(generation: request.generation) }
            lock.lock()
            let isCurrent = generation == request.generation
            next = pendingRequest
            pendingRequest = nil
            if next == nil { workerRunning = false }
            lock.unlock()

            if isCurrent {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let stillCurrent = self.generation == request.generation
                    self.lock.unlock()
                    guard stillCurrent else { return }
                    request.completion(result)
                }
            }
        }
    }

    private func readAccountUsage(generation expected: UInt64) throws -> CodexAccountUsage {
        guard let executable = Self.codexExecutable() else { throw ReaderError.codexUnavailable }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var processWasLaunched = false

        lock.lock()
        guard generation == expected else { lock.unlock(); throw ReaderError.cancelled }
        self.process = process
        lock.unlock()
        defer {
            try? input.fileHandleForWriting.close()
            if processWasLaunched { Self.terminateAndWait(process) }
            lock.lock()
            if self.process === process { self.process = nil }
            lock.unlock()
        }

        do {
            try process.run()
            processWasLaunched = true
        } catch {
            throw ReaderError.launchFailed
        }
        let pid = process.processIdentifier
        lock.lock()
        let wasCancelledBeforeLaunch = generation != expected || self.process !== process
        lock.unlock()
        if wasCancelledBeforeLaunch {
            if process.isRunning { process.terminate() }
            throw ReaderError.cancelled
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) { [weak self, weak process] in
            guard let self, let process, process.isRunning else { return }
            self.lock.lock()
            let shouldStop = self.generation == expected && self.process === process
            self.lock.unlock()
            guard shouldStop else { return }
            self.lock.lock()
            self.timedOutGeneration = expected
            self.lock.unlock()
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }

        do {
            var reader = JSONLineReader(handle: output.fileHandleForReading)
            try send(["method": "initialize", "id": 1, "params": ["clientInfo": [
                "name": "makidesk_terminal", "title": "MakiDesk Terminal", "version": "1"
            ]]], to: input.fileHandleForWriting)
            let initialization = try response(id: 1, reader: &reader, input: input.fileHandleForWriting)
            if initialization["error"] != nil { throw ReaderError.protocolFailure }
            try send(["method": "initialized"], to: input.fileHandleForWriting)

            try send(["method": "account/rateLimits/read", "id": 2], to: input.fileHandleForWriting)
            let rateResponse = try response(id: 2, reader: &reader, input: input.fileHandleForWriting)
            guard let account = CodexAccountUsageParser.rateLimits(from: rateResponse) else {
                if rateResponse["error"] != nil { throw ReaderError.accountUnavailable }
                throw ReaderError.invalidResponse
            }

            try send(["method": "account/usage/read", "id": 3], to: input.fileHandleForWriting)
            let usageResponse = try response(id: 3, reader: &reader, input: input.fileHandleForWriting)
            if usageResponse["error"] == nil {
                return CodexAccountUsageParser.usage(from: usageResponse, into: account)
            }
            // Older servers may not expose token summaries. Rate-limit data remains valid.
            return account
        } catch {
            lock.lock()
            let timedOut = timedOutGeneration == expected
            lock.unlock()
            if timedOut { throw ReaderError.timeout }
            throw error
        }
    }

    private func response(id: Int, reader: inout JSONLineReader,
                          input: FileHandle) throws -> [String: Any] {
        while true {
            let object = try reader.nextObject()
            if let method = object["method"] as? String {
                // Refuse every server-initiated request; this client does not service tools,
                // approvals, login, thread or turn operations.
                if let requestID = object["id"] {
                    try send(["id": requestID, "error": ["code": -32601,
                                "message": "Method not supported by MakiDesk Terminal"]], to: input)
                }
                _ = method
                continue
            }
            guard (object["id"] as? Int) == id else { continue }
            return object
        }
    }

    private func send(_ object: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= 64 * 1024 else { throw ReaderError.invalidResponse }
        handle.write(data + Data([0x0A]))
    }

    /// Runs only on the reader worker. Give SIGTERM a short grace period, then
    /// kill the owned child before the final reap so `waitUntilExit` is bounded.
    private static func terminateAndWait(_ process: Process) {
        if process.isRunning {
            let pid = process.processIdentifier
            process.terminate()
            let grace = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                grace.signal()
            }
            _ = grace.wait(timeout: .now() + 0.55)
            if process.isRunning { kill(pid, SIGKILL) }
        }
        process.waitUntilExit()
    }

    private static func codexExecutable() -> String? {
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = String(directory) + "/codex"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private enum ReaderError: LocalizedError {
        case codexUnavailable, launchFailed, protocolFailure, accountUnavailable
        case invalidResponse, timeout, cancelled
        var errorDescription: String? {
            switch self {
            case .codexUnavailable: return "Codex CLI was not found."
            case .launchFailed: return "Codex app-server could not start."
            case .protocolFailure: return "Codex app-server initialization failed."
            case .accountUnavailable: return "Codex account limits are unavailable."
            case .invalidResponse: return "Codex app-server returned an invalid response."
            case .timeout: return "Codex app-server request timed out."
            case .cancelled: return "Codex account refresh was cancelled."
            }
        }
    }
}

private struct JSONLineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var totalBytes = 0

    init(handle: FileHandle) { self.handle = handle }

    mutating func nextObject() throws -> [String: Any] {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                else { throw ReaderFailure.invalidResponse }
                return object
            }
            let chunk = handle.availableData
            guard chunk.isEmpty == false else { throw ReaderFailure.closed }
            totalBytes += chunk.count
            guard totalBytes <= 256 * 1024, buffer.count + chunk.count <= 128 * 1024 else {
                throw ReaderFailure.tooLarge
            }
            buffer.append(chunk)
        }
    }

    private enum ReaderFailure: Error { case closed, invalidResponse, tooLarge }
}
