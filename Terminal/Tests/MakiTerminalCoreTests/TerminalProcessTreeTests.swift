import XCTest
@testable import MakiTerminalCore

final class TerminalProcessTreeTests: XCTestCase {
    private let helper: pid_t = 100

    private func tree(_ parents: [pid_t: pid_t],
                      _ paths: [pid_t: String]) -> ((pid_t) -> pid_t, (pid_t) -> String) {
        ({ parents[$0] ?? 0 }, { paths[$0] ?? "" })
    }

    func testAnIdleShellBehindLoginIsTheBaseline() {
        let (parent, path) = tree([102: 101, 101: 100],
                                  [101: "/usr/bin/login", 102: "/bin/zsh"])
        XCTAssertEqual(TerminalProcessTree.baselinePID(foreground: 102, helper: helper,
                                                       parent: parent, path: path), 102)
        XCTAssertFalse(TerminalProcessTree.shouldConfirmClose(
            configuredCommand: false, ghosttySaysConfirm: true,
            foreground: 102, baseline: 102))
    }

    func testACommandBehindTheShellIsDeeperThanTheBaseline() {
        let (parent, path) = tree([103: 102, 102: 101, 101: 100],
                                  [101: "/usr/bin/login", 102: "/bin/zsh", 103: "/usr/bin/git"])
        XCTAssertEqual(TerminalProcessTree.baselinePID(foreground: 103, helper: helper,
                                                       parent: parent, path: path), 102)
        XCTAssertTrue(TerminalProcessTree.shouldConfirmClose(
            configuredCommand: false, ghosttySaysConfirm: false,
            foreground: 103, baseline: 102))
    }

    func testAnIdleShellWithoutLoginIsTheBaseline() {
        let (parent, path) = tree([102: 100], [102: "/bin/zsh"])
        XCTAssertEqual(TerminalProcessTree.baselinePID(foreground: 102, helper: helper,
                                                       parent: parent, path: path), 102)
    }

    func testACommandWithoutLoginIsDeeperThanTheBaseline() {
        let (parent, path) = tree([103: 102, 102: 100],
                                  [102: "/bin/zsh", 103: "/usr/bin/git"])
        XCTAssertEqual(TerminalProcessTree.baselinePID(foreground: 103, helper: helper,
                                                       parent: parent, path: path), 102)
        XCTAssertTrue(TerminalProcessTree.shouldConfirmClose(
            configuredCommand: false, ghosttySaysConfirm: false,
            foreground: 103, baseline: 102))
    }

    func testAnUnknownTreeFallsBackToGhostty() {
        XCTAssertTrue(TerminalProcessTree.shouldConfirmClose(
            configuredCommand: false, ghosttySaysConfirm: true,
            foreground: nil, baseline: nil))
        XCTAssertFalse(TerminalProcessTree.shouldConfirmClose(
            configuredCommand: false, ghosttySaysConfirm: false,
            foreground: nil, baseline: nil))
    }

    func testAConfiguredSessionAlwaysAsks() {
        XCTAssertTrue(TerminalProcessTree.shouldConfirmClose(
            configuredCommand: true, ghosttySaysConfirm: false,
            foreground: 102, baseline: 102))
    }

    func testTheHelperItselfIsNotACommand() {
        let (parent, path) = tree([:], [:])
        XCTAssertNil(TerminalProcessTree.baselinePID(foreground: helper, helper: helper,
                                                     parent: parent, path: path))
    }

    func testACycleStopsWithoutHanging() {
        let (parent, path) = tree([200: 201, 201: 200],
                                  [200: "/bin/zsh", 201: "/bin/zsh"])
        XCTAssertNil(TerminalProcessTree.baselinePID(foreground: 200, helper: helper,
                                                     parent: parent, path: path))
    }

    func testARealProcessHasAParentAndAPath() {
        let pid = getpid()
        XCTAssertGreaterThan(TerminalProcessTree.parentPID(of: pid), 0)
        XCTAssertNotEqual(TerminalProcessTree.parentPID(of: pid), pid)
        XCTAssertFalse(TerminalProcessTree.executablePath(of: pid).isEmpty)
    }
}
