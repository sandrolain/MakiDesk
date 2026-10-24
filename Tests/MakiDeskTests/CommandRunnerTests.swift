import Darwin
import XCTest
@testable import MakiDesk

/// T38/T44: the shared command runner. These tests spawn real short-lived
/// processes with `/bin/sh`, so they also prove that arguments, environment,
/// stdin, timeout and cancellation behave as documented.
final class CommandRunnerTests: XCTestCase {
    private var workdir: URL!
    private let runner = CommandRunner()

    override func setUpWithError() throws {
        workdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDeskRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workdir { try? FileManager.default.removeItem(at: workdir) }
    }

    private func command(_ executable: String,
                         _ arguments: [String],
                         timeout: TimeInterval = 5,
                         stdin: URL? = nil,
                         environment: [String: String] = [:],
                         workingDirectory: URL? = nil) -> ResolvedCommand {
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for (key, value) in environment { env[key] = value }
        return ResolvedCommand(
            executable: URL(fileURLWithPath: executable),
            arguments: arguments,
            environment: env,
            workingDirectory: workingDirectory ?? workdir,
            workDirectory: workdir,
            outputDirectory: workdir.appendingPathComponent("output", isDirectory: true),
            stdinFile: stdin,
            timeout: timeout,
            keepWorkdir: true
        )
    }

    private func shell(_ script: String, timeout: TimeInterval = 5) -> ResolvedCommand {
        command("/bin/sh", ["-c", script], timeout: timeout)
    }

    /// `/var` is a firmlink to `/private/var`, and the shell reports the
    /// physical path from `getcwd`; Foundation does not resolve it.
    private func realPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        return String(cString: buffer)
    }

    // MARK: - Exit status and output

    func testRunsCommandAndCapturesStdout() async throws {
        let result = try await runner.run(shell("printf hello"), id: UUID(), includeStdout: true)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(result.termSignal)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdoutExcerpt, "hello")
        XCTAssertEqual(result.stderrExcerpt, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.stdoutFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.stderrFile.path))
    }

    func testNonZeroExitKeepsTheCodeAndStderr() async throws {
        let result = try await runner.run(shell("echo oops >&2; exit 3"), id: UUID(), includeStdout: true)
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.stderrExcerpt.contains("oops"))
    }

    func testStdoutExcerptIsOmittedUnlessRequested() async throws {
        let result = try await runner.run(shell("printf hello"), id: UUID(), includeStdout: false)
        XCTAssertNil(result.stdoutExcerpt)
    }

    func testOutputFilesAreCreatedInTheRunDirectory() async throws {
        let result = try await runner.run(shell("printf hi"), id: UUID(), includeStdout: true)
        XCTAssertEqual(result.workDirectory, workdir)
        XCTAssertEqual(result.stdoutFile.deletingLastPathComponent(), workdir)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: workdir.appendingPathComponent("output", isDirectory: true).path))
    }

    // MARK: - Arguments, environment, stdin, cwd

    func testArgumentsWithSpacesAndQuotesArriveIntact() async throws {
        let tricky = "a b'c\"d $HOME;rm"
        let result = try await runner.run(
            command("/bin/sh", ["-c", #"printf '%s' "$1""#, "sh", tricky]),
            id: UUID(), includeStdout: true)
        XCTAssertEqual(result.stdoutExcerpt, tricky)
    }

    func testEnvironmentAndWorkingDirectory() async throws {
        let subdirectory = workdir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let result = try await runner.run(
            command("/bin/sh", ["-c", #"printf '%s|%s' "$FOO" "$PWD""#],
                    environment: ["FOO": "bar"],
                    workingDirectory: subdirectory),
            id: UUID(), includeStdout: true)
        XCTAssertEqual(result.stdoutExcerpt, "bar|\(realPath(subdirectory.path))")
    }

    func testStdinFileIsRedirected() async throws {
        let file = workdir.appendingPathComponent("input.txt")
        try "from stdin".write(to: file, atomically: true, encoding: .utf8)
        let result = try await runner.run(command("/bin/cat", [], stdin: file),
                                          id: UUID(), includeStdout: true)
        XCTAssertEqual(result.stdoutExcerpt, "from stdin")
    }

    // MARK: - Timeout and cancellation

    func testTimeoutTerminatesTheCommand() async throws {
        let started = Date()
        let result = try await runner.run(shell("sleep 5", timeout: 0.2), id: UUID())
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testTimeoutZeroDisablesTheLimit() async throws {
        let result = try await runner.run(shell("printf ok", timeout: 0), id: UUID(), includeStdout: true)
        XCTAssertEqual(result.stdoutExcerpt, "ok")
        XCTAssertFalse(result.timedOut)
    }

    func testCancelStopsARunningCommand() async throws {
        let id = UUID()
        let task = Task { try await runner.run(self.shell("sleep 5"), id: id) }
        try await Task.sleep(nanoseconds: 300_000_000)
        await runner.cancel(id)
        let result = try await task.value
        XCTAssertTrue(result.cancelled)
        XCTAssertLessThan(result.duration, 1.5)
    }

    func testCancelKillsTheWholeProcessGroup() async throws {
        let id = UUID()
        let script = "sleep 30 & echo $! > child.pid; wait"
        let task = Task { try await runner.run(self.shell(script), id: id) }

        let childFile = workdir.appendingPathComponent("child.pid")
        var childPID: pid_t?
        for _ in 0..<40 where childPID == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
            if let text = try? String(contentsOf: childFile, encoding: .utf8),
               let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                childPID = pid_t(value)
            }
        }
        let grandchild = try XCTUnwrap(childPID, "the shell did not start its child")
        await runner.cancel(id)
        _ = try await task.value

        var stillThere = true
        for _ in 0..<40 where stillThere {
            if kill(grandchild, 0) == -1, errno == ESRCH { stillThere = false } else {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        XCTAssertFalse(stillThere, "the grandchild survived cancellation")
    }

    // MARK: - Failures

    func testMissingExecutableThrowsASpawnError() async {
        let missing = command("/definitely/not/a/binary", [])
        do {
            _ = try await runner.run(missing, id: UUID())
            XCTFail("expected a spawn error")
        } catch let error as CommandRunError {
            if case .spawn = error { return }
            XCTFail("unexpected error: \(error)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
