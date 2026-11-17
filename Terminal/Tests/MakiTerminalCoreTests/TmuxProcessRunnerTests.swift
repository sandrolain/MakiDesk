import Foundation
import XCTest
@testable import MakiTerminalCore

final class TmuxProcessRunnerTests: XCTestCase {
    func testStopsACommandAtItsTimeout() throws {
        let fixture = try makeExecutable(script: "#!/bin/sh\nexec /bin/sleep 10\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let start = Date()

        XCTAssertEqual(
            TmuxProcessRunner.run(executable: fixture.executable,
                                  arguments: [],
                                  timeout: 0.1,
                                  maximumOutputBytes: 1024),
            .failure(.timedOut)
        )
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testStopsReadingWhenOutputExceedsItsLimit() throws {
        let fixture = try makeExecutable(script: "#!/bin/sh\nprintf '0123456789'\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        XCTAssertEqual(
            TmuxProcessRunner.run(executable: fixture.executable,
                                  arguments: [],
                                  timeout: 1,
                                  maximumOutputBytes: 4),
            .failure(.outputTooLarge)
        )
    }

    func testReturnsBoundedFailureDiagnostics() throws {
        let fixture = try makeExecutable(script: """
        #!/bin/sh
        printf 'no server running on test socket\\n' >&2
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        XCTAssertEqual(
            TmuxProcessRunner.run(executable: fixture.executable,
                                  arguments: [],
                                  timeout: 1,
                                  maximumOutputBytes: 1024),
            .failure(.commandFailed(exitCode: 1,
                                    diagnostic: "no server running on test socket"))
        )
    }

    private func makeExecutable(script: String) throws -> (directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TmuxProcessRunner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("tmux")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: executable.path)
        return (directory, executable)
    }
}
