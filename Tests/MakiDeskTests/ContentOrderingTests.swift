import XCTest
import AppKit
@testable import MakiDesk

/// The order the golden spiral hands out its slots in: the window with the most
/// visual content gets the widest one, and when no capture score is available
/// (no Screen Recording permission) the biggest window does.
final class ContentOrderingTests: XCTestCase {
    private func window(_ id: String, _ width: CGFloat, _ height: CGFloat) -> ActionableWindow {
        ActionableWindow(id: id, title: id, appName: "Example",
                         frame: CGRect(x: 0, y: 0, width: width, height: height),
                         pid: 0, minimized: false, element: AXUIElementCreateSystemWide(),
                         color: .black, windowID: nil, icon: nil, state: .normal)
    }

    func testTheBusiestWindowComesFirst() {
        let a = window("a", 900, 700)      // biggest, but the emptiest
        let b = window("b", 300, 200)
        let c = window("c", 800, 600)
        let ordered = WorkspaceStore.byContentScore([a, b, c], scores: ["a": 1, "b": 9, "c": 5])
        XCTAssertEqual(ordered.map(\.id), ["b", "c", "a"])
    }

    func testAMissingScoreFallsBackToTheWindowArea() {
        let small = window("small", 200, 200)      // 40 000
        let big = window("big", 800, 600)          // 480 000
        let medium = window("medium", 400, 300)    // 120 000
        // Only `small` was captured: the other two are ranked by area.
        let ordered = WorkspaceStore.byContentScore([small, big, medium], scores: ["small": 0.4])
        XCTAssertEqual(ordered.map(\.id), ["big", "medium", "small"])
    }

    func testNoScoresAtAllKeepsTheLargestWindowFirst() {
        let one = window("one", 100, 100)
        let two = window("two", 500, 500)
        XCTAssertEqual(WorkspaceStore.byContentScore([one, two], scores: [:]).map(\.id), ["two", "one"])
    }
}
