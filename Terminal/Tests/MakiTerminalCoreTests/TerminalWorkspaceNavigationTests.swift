import XCTest
@testable import MakiTerminalCore

final class TerminalWorkspaceNavigationTests: XCTestCase {
    func testMovingForwardWrapsToTheStart() {
        XCTAssertEqual(TerminalWorkspaceNavigation.cycledIndex(from: 0, count: 3, delta: 1), 1)
        XCTAssertEqual(TerminalWorkspaceNavigation.cycledIndex(from: 2, count: 3, delta: 1), 0)
    }

    func testMovingBackwardsWrapsToTheEnd() {
        XCTAssertEqual(TerminalWorkspaceNavigation.cycledIndex(from: 0, count: 3, delta: -1), 2)
        XCTAssertEqual(TerminalWorkspaceNavigation.cycledIndex(from: 1, count: 3, delta: -1), 0)
    }

    func testALargeStepStillLandsInside() {
        XCTAssertEqual(TerminalWorkspaceNavigation.cycledIndex(from: 0, count: 3, delta: 5), 2)
        XCTAssertEqual(TerminalWorkspaceNavigation.cycledIndex(from: 0, count: 3, delta: -5), 1)
    }

    func testAnEmptySidebarHasNoSelection() {
        XCTAssertNil(TerminalWorkspaceNavigation.cycledIndex(from: 0, count: 0, delta: 1))
    }

    func testAnOutOfRangeStartIsClamped() {
        XCTAssertEqual(TerminalWorkspaceNavigation.cycledIndex(from: 9, count: 3, delta: 1), 0)
        XCTAssertEqual(TerminalWorkspaceNavigation.cycledIndex(from: -9, count: 3, delta: -1), 2)
    }

    func testOneWorkspaceStaysSelected() {
        XCTAssertEqual(TerminalWorkspaceNavigation.cycledIndex(from: 0, count: 1, delta: 1), 0)
    }
}
