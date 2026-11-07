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
}
