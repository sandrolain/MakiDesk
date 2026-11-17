import XCTest
@testable import MakiTerminalCore

final class TmuxSessionTests: XCTestCase {
    func testTheNameFollowsTheWorkspace() {
        let id = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
        XCTAssertEqual(TmuxSession.name(for: id), "makidesk-abcdef01")
    }

    func testTheCommandCreatesOrAttaches() {
        XCTAssertEqual(TmuxSession.command(sessionName: "makidesk-abcdef01",
                                           executable: "/opt/homebrew/bin/tmux"),
                       "/opt/homebrew/bin/tmux new-session -A -s makidesk-abcdef01")
    }

    func testTheSessionNameIsSanitized() {
        XCTAssertEqual(TmuxSession.command(sessionName: "my session; rm -rf /",
                                           executable: "tmux"),
                       "tmux new-session -A -s mysessionrm-rf")
        XCTAssertEqual(TmuxSession.command(sessionName: "", executable: "tmux"),
                       "tmux new-session -A -s makidesk")
    }

    func testTheExecutableIsFoundOnThePath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiTmux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tmux = directory.appendingPathComponent("tmux")
        try "#!/bin/sh\n".write(to: tmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: tmux.path)

        let found = TmuxSession.executableURL(environment: ["PATH": directory.path],
                                              fixedPaths: [])
        XCTAssertEqual(found?.standardizedFileURL.path, tmux.standardizedFileURL.path)
    }

    func testCurrentPaneDirectoryUsesTheSessionTargetAndPreservesSpaces() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiTmux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tmux = directory.appendingPathComponent("tmux")
        try """
        #!/bin/sh
        [ "$1" = "display-message" ] || exit 1
        [ "$2" = "-p" ] || exit 1
        [ "$3" = "-t" ] || exit 1
        [ "$4" = "makidesk-pane-test" ] || exit 1
        [ "$5" = "#{pane_current_path}" ] || exit 1
        printf '%s\\n' '/tmp/project with spaces'
        """.write(to: tmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: tmux.path)

        XCTAssertEqual(
            TmuxSession.currentPaneDirectory(target: "makidesk-pane-test", executable: tmux),
            "/tmp/project with spaces"
        )
    }

    func testUnattachedSessionEnumerationDistinguishesEmptyFromFailure() throws {
        let empty = try makeTmux(script: "#!/bin/sh\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: empty.directory) }
        XCTAssertEqual(TmuxSession.unattachedSessions(executable: empty.executable),
                       .success([]))

        let failure = try makeTmux(script: """
        #!/bin/sh
        printf 'tmux is broken\\n' >&2
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: failure.directory) }
        XCTAssertEqual(TmuxSession.unattachedSessions(executable: failure.executable),
                       .failure(.commandFailed(exitCode: 1, diagnostic: "tmux is broken")))
    }

    func testUnattachedSessionEnumerationTreatsMissingServerAsEmpty() throws {
        let fixture = try makeTmux(script: """
        #!/bin/sh
        printf 'no server running on test socket\\n' >&2
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        XCTAssertEqual(TmuxSession.unattachedSessions(executable: fixture.executable),
                       .success([]))
    }

    func testUnattachedSessionEnumerationKeepsStableTargetsAndFiltersAttached() throws {
        let fixture = try makeTmux(script: """
        #!/bin/sh
        printf '$3\\tproject with spaces\\t0\\n'
        printf '$4\\tattached session\\t1\\n'
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        XCTAssertEqual(
            TmuxSession.unattachedSessions(executable: fixture.executable),
            .success([TmuxSession.UnattachedSession(target: "$3", name: "project with spaces")])
        )
    }

    func testExistingPaneEnumerationDistinguishesNoServerFromFailure() throws {
        let noServer = try makeTmux(script: """
        #!/bin/sh
        printf 'no server running on test socket\\n' >&2
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: noServer.directory) }
        XCTAssertEqual(TmuxSession.existingPaneSessions(executable: noServer.executable),
                       .success([]))

        let failure = try makeTmux(script: """
        #!/bin/sh
        printf 'tmux is broken\\n' >&2
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: failure.directory) }
        XCTAssertEqual(TmuxSession.existingPaneSessions(executable: failure.executable),
                       .failure(.commandFailed(exitCode: 1, diagnostic: "tmux is broken")))
    }

    func testLatestStatusPreferenceSupersedesFailedEarlierRequest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiTmux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("tmux")
        let log = directory.appendingPathComponent("calls.log")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(log.path)'
        [ "$5" = "on" ] && exit 1
        exit 0
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: executable.path)
        let sessionName = "makidesk-pane-\(UUID().uuidString)"
        let completed = expectation(description: "latest status preference completes")
        var result: Result<Void, TmuxCommandFailure>?

        TmuxSession.setStatusBarVisible(true, sessionName: sessionName, executable: executable)
        TmuxSession.setStatusBarVisible(false, sessionName: sessionName, executable: executable) {
            result = $0
            completed.fulfill()
        }

        wait(for: [completed], timeout: 3)
        if case .success? = result {
        } else {
            XCTFail("Expected the latest status preference to succeed")
        }
        let calls = try String(contentsOf: log, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        XCTAssertTrue(calls.last?.hasSuffix("status off") == true)
    }

    func testExternalAttachCommandIsRecognizedAndKeepsStableTarget() {
        let command = "exec /opt/homebrew/bin/tmux attach-session -t '$3'"
        XCTAssertTrue(TmuxSession.isAttachCommand(command))
        XCTAssertEqual(TmuxSession.attachedSessionName(in: command), "$3")
        XCTAssertEqual(TmuxSession.target(in: command), "$3")
    }

    private func makeTmux(script: String) throws -> (directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiTmux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("tmux")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: executable.path)
        return (directory, executable)
    }
}
