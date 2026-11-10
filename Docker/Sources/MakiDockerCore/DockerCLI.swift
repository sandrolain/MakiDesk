import Darwin
import Foundation

public struct DockerCommandResult: Equatable, Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let duration: TimeInterval

    public init(stdout: String, stderr: String, exitCode: Int32, duration: TimeInterval) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.duration = duration
    }
}

public enum DockerCLIError: Error, Equatable, LocalizedError, Sendable {
    case executableNotFound
    case launchFailed(String)
    case timedOut
    case cancelled
    case nonZero(Int32, String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "The docker command was not found."
        case let .launchFailed(detail):
            return "Could not start docker: \(detail)"
        case .timedOut:
            return "Docker did not answer in time."
        case .cancelled:
            return "The Docker command was cancelled."
        case let .nonZero(code, detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Docker exited with code \(code)." : trimmed
        }
    }
}

/// A stateless runner for the Docker CLI. Every command is a separate process;
/// blocking pipe reads happen on a global queue, never on the main actor or a
/// cooperative thread.
public struct DockerCLI: Sendable {
    public let executableURL: URL
    public let context: String?
    public let environment: [String: String]

    public init(executableURL: URL,
                context: String? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executableURL = executableURL
        self.context = context
        var merged = environment
        merged["DOCKER_CLI_HINTS"] = "false"
        self.environment = merged
    }

    public func withContext(_ context: String?) -> DockerCLI {
        DockerCLI(executableURL: executableURL, context: context, environment: environment)
    }

    @discardableResult
    public func run(_ arguments: [String],
                    timeout: TimeInterval = 15) async throws -> DockerCommandResult {
        let handle = ProcessHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let result = try Self.runBlocking(
                            executableURL: executableURL,
                            arguments: arguments,
                            context: context,
                            environment: environment,
                            timeout: timeout,
                            handle: handle
                        )
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    public func runChecked(_ arguments: [String],
                           timeout: TimeInterval = 15) async throws -> String {
        let result = try await run(arguments, timeout: timeout)
        guard result.exitCode == 0 else {
            throw DockerCLIError.nonZero(result.exitCode, result.stderr)
        }
        return result.stdout
    }

    private static func runBlocking(executableURL: URL,
                                    arguments: [String],
                                    context: String?,
                                    environment: [String: String],
                                    timeout: TimeInterval,
                                    handle: ProcessHandle) throws -> DockerCommandResult {
        let process = Process()
        process.executableURL = executableURL
        var args: [String] = []
        if let context, context.isEmpty == false {
            args.append(contentsOf: ["--context", context])
        }
        args.append(contentsOf: arguments)
        process.arguments = args
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try handle.attach(process)
            try process.run()
        } catch {
            throw DockerCLIError.launchFailed(error.localizedDescription)
        }

        let started = Date()
        let group = DispatchGroup()
        var stdout = Data()
        var stderr = Data()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdout = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderr = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let timeoutWork = DispatchWorkItem {
            handle.timeout()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout,
                                                       execute: timeoutWork)

        group.wait()
        process.waitUntilExit()
        handle.markFinished()
        timeoutWork.cancel()

        let result = DockerCommandResult(
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self),
            exitCode: process.terminationStatus,
            duration: Date().timeIntervalSince(started)
        )

        if handle.wasCancelled {
            throw DockerCLIError.cancelled
        }
        if handle.didTimeOut {
            throw DockerCLIError.timedOut
        }
        return result
    }
}

/// Thread-safe handle used by cancellation and the timeout timer. `Process` is
/// not Sendable, so it stays behind this lock.
private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    private var finished = false

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    var didTimeOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut
    }

    func attach(_ process: Process) throws {
        lock.lock()
        if cancelled { lock.unlock(); throw DockerCLIError.cancelled }
        self.process = process
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = finished ? nil : self.process
        lock.unlock()
        terminate(process, forceAfter: 2)
    }

    func timeout() {
        lock.lock()
        guard finished == false else { lock.unlock(); return }
        timedOut = true
        let process = self.process
        lock.unlock()
        terminate(process, forceAfter: 2)
    }

    func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    private func terminate(_ process: Process?, forceAfter: TimeInterval) {
        guard let process, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + forceAfter) {
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }
}

/// Finds the Docker CLI in the places a GUI app can see. A GUI launch has a
/// short PATH, so the common install locations and the login shell are checked
/// before giving up.
public enum DockerExecutableLocator {
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) async -> URL? {
        await Task.detached(priority: .utility) {
            locateBlocking(environment: environment)
        }.value
    }

    public static func locateBlocking(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let home = NSHomeDirectory()
        var candidates: [String] = []
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                "\($0)/docker"
            })
        }
        candidates.append(contentsOf: [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/usr/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
            "\(home)/.docker/bin/docker",
            "\(home)/.rd/bin/docker",
            "\(home)/.orbstack/bin/docker",
        ])
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return loginShellLookup()
    }

    private static func loginShellLookup() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v docker"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        if semaphore.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, path.isEmpty == false,
              FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }
}
