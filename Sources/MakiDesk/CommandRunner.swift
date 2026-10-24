import Darwin
import Foundation

/// What one command produced. Output is written to files inside the run's work
/// directory — never read through a pipe — and only a bounded excerpt is kept
/// in memory, so a chatty command cannot flood the app.
struct CommandResult: Equatable, Sendable {
    let exitCode: Int32?
    let termSignal: Int32?
    let timedOut: Bool
    let cancelled: Bool
    let duration: TimeInterval
    let workDirectory: URL
    let stdoutFile: URL
    let stderrFile: URL
    let stdoutExcerpt: String?
    let stderrExcerpt: String

    var succeeded: Bool { exitCode == 0 && timedOut == false && cancelled == false }
}

enum CommandRunError: Error, Equatable, LocalizedError {
    case spawn(code: Int32, reason: String)
    case outputUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .spawn(code, reason):
            return "Could not start the command (\(reason), error \(code))."
        case let .outputUnavailable(path):
            return "Could not create the output file: \(path)."
        }
    }
}

protocol CommandRunning: Sendable {
    func run(_ command: ResolvedCommand, id: UUID, includeStdout: Bool) async throws -> CommandResult
    func cancel(_ id: UUID) async
}

/// Runs a `ResolvedCommand` off the main thread, in its own process group.
///
/// Why `posix_spawn` instead of `Process`: `Process` cannot put the child in a
/// new process group, so cancelling a pipeline (`sh -c 'a | b'`) would leave
/// the grandchildren running. A new process group lets `kill(-pid, …)` reach
/// the whole tree, while the timeout escalates from `SIGTERM` to `SIGKILL`.
///
/// The runner owns no UI: it reports the exit status, the signal, the flags and
/// an excerpt of stderr. The caller owns the work directory and decides when to
/// delete it.
actor CommandRunner: CommandRunning {
    static let shared = CommandRunner()

    static let stdoutName = "stdout.log"
    static let stderrName = "stderr.log"
    static let stderrExcerptBytes = 8 * 1024
    static let stdoutExcerptBytes = 64 * 1024
    /// How long a terminated command gets before `SIGKILL`.
    static let killGrace: TimeInterval = 2

    private var running: [UUID: ProcessRun] = [:]
    private let waiterQueue = DispatchQueue(label: "MakiDesk.CommandRunner.wait", qos: .utility,
                                            attributes: .concurrent)
    private let timerQueue = DispatchQueue(label: "MakiDesk.CommandRunner.timer", qos: .utility)

    func run(_ command: ResolvedCommand, id: UUID, includeStdout: Bool = false) async throws -> CommandResult {
        try prepareDirectories(command)
        let stdoutFile = command.workDirectory.appendingPathComponent(Self.stdoutName)
        let stderrFile = command.workDirectory.appendingPathComponent(Self.stderrName)

        let pid = try spawn(command, stdout: stdoutFile, stderr: stderrFile)
        let process = ProcessRun(pid: pid)
        running[id] = process
        let started = DispatchTime.now().uptimeNanoseconds

        let timeoutItem = scheduleTimeout(command: command, process: process)

        let result: CommandResult = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiterQueue.async {
                    var status: Int32 = 0
                    var waited: pid_t
                    repeat {
                        waited = waitpid(pid, &status, 0)
                    } while waited == -1 && errno == EINTR

                    let exitCode = waited == -1 ? nil : Self.exitCode(status)
                    let termSignal = waited == -1 ? nil : Self.termSignal(status)
                    // Mark the child finished before doing any slow work, so a
                    // cancel that arrives in between cannot report a completed
                    // command as cancelled.
                    let flags = process.finish()
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000

                    continuation.resume(returning: CommandResult(
                        exitCode: exitCode,
                        termSignal: termSignal,
                        timedOut: flags.timedOut,
                        cancelled: flags.cancelled,
                        duration: elapsed,
                        workDirectory: command.workDirectory,
                        stdoutFile: stdoutFile,
                        stderrFile: stderrFile,
                        stdoutExcerpt: includeStdout ? Self.excerpt(of: stdoutFile,
                                                                    limit: Self.stdoutExcerptBytes) : nil,
                        stderrExcerpt: Self.excerpt(of: stderrFile,
                                                    limit: Self.stderrExcerptBytes) ?? ""
                    ))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }

        timeoutItem?.cancel()
        running[id] = nil
        return result
    }

    func cancel(_ id: UUID) async {
        guard let process = running[id] else { return }
        process.terminate(.cancelled, grace: Self.killGrace)
    }

    // MARK: - Spawn

    private func prepareDirectories(_ command: ResolvedCommand) throws {
        let manager = FileManager.default
        for directory in [command.workDirectory, command.outputDirectory] {
            do {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw CommandRunError.outputUnavailable(directory.path)
            }
        }
    }

    private func scheduleTimeout(command: ResolvedCommand, process: ProcessRun) -> DispatchWorkItem? {
        guard command.timeout > 0 else { return nil }
        let item = DispatchWorkItem { [weak process] in
            process?.terminate(.timedOut, grace: Self.killGrace)
        }
        timerQueue.asyncAfter(deadline: .now() + command.timeout, execute: item)
        return item
    }

    private func spawn(_ command: ResolvedCommand, stdout: URL, stderr: URL) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw CommandRunError.spawn(code: 0, reason: "file actions")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw CommandRunError.spawn(code: 0, reason: "attributes")
        }
        defer { posix_spawnattr_destroy(&attributes) }

        if let stdin = command.stdinFile {
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, stdin.path, O_RDONLY, 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, stdout.path,
                                         O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, stderr.path,
                                         O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if #available(macOS 26.0, *) {
            posix_spawn_file_actions_addchdir(&actions, command.workingDirectory.path)
        } else {
            posix_spawn_file_actions_addchdir_np(&actions, command.workingDirectory.path)
        }

        // Own process group (pgroup 0 means "the child's pid"), so cancel and
        // timeout reach the whole tree. Close everything the child should not
        // inherit, and give it a clean signal state: a GUI app or a test
        // harness may have SIGTERM blocked or ignored in the spawning thread,
        // and the child would inherit that and ignore our own timeout.
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGPIPE] {
            sigaddset(&defaults, signal)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setflags(&attributes,
                                 Int16(POSIX_SPAWN_SETPGROUP
                                       | POSIX_SPAWN_CLOEXEC_DEFAULT
                                       | POSIX_SPAWN_SETSIGMASK
                                       | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes, 0)

        var argv = Self.cStrings(command.arguments, prepending: command.executable.path)
        var envp = Self.cStrings(command.environment.map { "\($0.key)=\($0.value)" }, prepending: nil)
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }

        var pid: pid_t = 0
        let code = posix_spawn(&pid, command.executable.path, &actions, &attributes, &argv, &envp)
        guard code == 0 else {
            throw CommandRunError.spawn(code: code, reason: String(cString: strerror(code)))
        }
        return pid
    }

    private static func cStrings(_ values: [String], prepending first: String?) -> [UnsafeMutablePointer<CChar>?] {
        var result: [UnsafeMutablePointer<CChar>?] = []
        if let first { result.append(strdup(first)) }
        for value in values { result.append(strdup(value)) }
        result.append(nil)
        return result
    }

    // MARK: - Status

    /// `waitpid` returns a wait status, not an exit code: the low seven bits
    /// are the terminating signal, the next eight the exit status.
    private static func exitCode(_ status: Int32) -> Int32? {
        termSignal(status) == nil ? (status >> 8) & 0xFF : nil
    }

    private static func termSignal(_ status: Int32) -> Int32? {
        let signal = status & 0x7F
        return signal == 0 ? nil : signal
    }

    // MARK: - Output

    private static func excerpt(of url: URL, limit: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit), data.isEmpty == false else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// One live child. The lock protects the flags read by the waiter and written
/// by the timeout/cancel paths on other queues.
private final class ProcessRun: @unchecked Sendable {
    enum Termination { case timedOut, cancelled }

    let pid: pid_t
    private let lock = NSLock()
    private var isFinished = false
    private var timedOut = false
    private var cancelled = false
    private var terminating = false

    init(pid: pid_t) {
        self.pid = pid
    }

    /// Marks the child finished and returns the final flags. Only the first
    /// call wins, so a timeout that fires exactly as the child exits keeps the
    /// real exit status meaningful.
    func finish() -> (timedOut: Bool, cancelled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        isFinished = true
        return (timedOut, cancelled)
    }

    var running: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isFinished == false
    }

    /// Sends `SIGTERM` to the process group once, then `SIGKILL` after the
    /// grace period if the group is still there.
    func terminate(_ reason: Termination, grace: TimeInterval) {
        lock.lock()
        guard isFinished == false, terminating == false else {
            lock.unlock()
            return
        }
        terminating = true
        switch reason {
        case .timedOut: timedOut = true
        case .cancelled: cancelled = true
        }
        let finishedFlag = { [weak self] in self?.running == false }
        lock.unlock()

        kill(-pid, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            if finishedFlag() == false {
                kill(-self.pid, SIGKILL)
            }
        }
    }
}
