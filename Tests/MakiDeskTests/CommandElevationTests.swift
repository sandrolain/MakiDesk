import XCTest
@testable import MakiDesk

/// T47: commands that would ask for an administrator password are refused
/// before a process exists.
final class CommandElevationTests: XCTestCase {
    private let workdir = FileManager.default.temporaryDirectory

    private func command(_ executable: String,
                         _ arguments: [String]) -> ResolvedCommand {
        ResolvedCommand(
            executable: URL(fileURLWithPath: executable),
            arguments: arguments,
            environment: [:],
            workingDirectory: workdir,
            workDirectory: workdir,
            outputDirectory: workdir.appendingPathComponent("output", isDirectory: true),
            stdinFile: nil,
            timeout: 5,
            keepWorkdir: false
        )
    }

    func testSudoExecutableIsRefused() {
        XCTAssertNotNil(CommandElevation.rejection(for: command("/usr/bin/sudo", ["true"])))
    }

    func testEnvSudoIsRefused() {
        XCTAssertNotNil(CommandElevation.rejection(for: command("/usr/bin/env", ["sudo", "true"])))
    }

    func testShellScriptBeginningWithSudoIsRefused() {
        XCTAssertNotNil(CommandElevation.rejection(
            for: command("/bin/zsh", ["-lc", "  sudo rm -rf /tmp/example"])))
        XCTAssertNotNil(CommandElevation.rejection(
            for: command("/bin/zsh", ["-lc", "/usr/bin/sudo id"])))
        XCTAssertNotNil(CommandElevation.rejection(
            for: command("/bin/zsh", ["-lc", "env -i sudo id"])))
    }

    func testOrdinaryCommandsAreAllowed() {
        XCTAssertNil(CommandElevation.rejection(for: command("/usr/bin/sips", ["-Z", "1600", "a.png"])))
        XCTAssertNil(CommandElevation.rejection(
            for: command("/bin/zsh", ["-lc", "printf '%s\\n' a | pbcopy"])))
    }

    /// `sudo` later in a pipeline is out of the check's scope: rejecting every
    /// occurrence would refuse benign text that merely mentions it.
    func testSudoMentionedLaterIsNotRefused() {
        XCTAssertNil(CommandElevation.rejection(
            for: command("/bin/zsh", ["-lc", "echo sudo"])))
    }
}
