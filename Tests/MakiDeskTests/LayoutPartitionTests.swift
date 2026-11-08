import XCTest
import AppKit
@testable import MakiDesk

/// Splitting a layout command's windows by display. Pure: the display lookup is
/// passed in, so the rules are checked without a second monitor.
@MainActor
final class LayoutPartitionTests: XCTestCase {
    private let left = WorkspaceStore.LayoutScreen(
        id: 1, area: CGRect(x: 0, y: 0, width: 1000, height: 800))
    private let right = WorkspaceStore.LayoutScreen(
        id: 2, area: CGRect(x: 1000, y: 0, width: 800, height: 800))

    private func makeWindow(_ id: String, frame: CGRect) -> ActionableWindow {
        ActionableWindow(id: id, title: id, appName: "Example", frame: frame, pid: 0,
                         minimized: false, element: AXUIElementCreateSystemWide(),
                         color: .black, windowID: nil, icon: nil, state: .normal)
    }

    private func group(_ groups: [WorkspaceStore.LayoutGroup]) -> [[String]] {
        groups.map { $0.windows.map(\.id) }
    }

    func testOneScreenKeepsEveryWindowInOrder() {
        let windows = [
            makeWindow("a", frame: CGRect(x: 0, y: 0, width: 400, height: 300)),
            makeWindow("b", frame: CGRect(x: 500, y: 0, width: 400, height: 300)),
        ]
        let groups = WorkspaceStore.layoutGroups(for: windows, screens: [left]) { _ in 1 }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.screen.id, 1)
        XCTAssertEqual(groups.first?.windows.map(\.id), ["a", "b"])
    }

    func testTwoScreensSplitAndKeepScreenOrder() {
        let windows = [
            makeWindow("left-a", frame: CGRect(x: 0, y: 0, width: 300, height: 300)),
            makeWindow("right-a", frame: CGRect(x: 1200, y: 0, width: 300, height: 300)),
            makeWindow("left-b", frame: CGRect(x: 400, y: 0, width: 300, height: 300)),
        ]
        let groups = WorkspaceStore.layoutGroups(for: windows, screens: [left, right]) {
            $0.id.hasPrefix("left") ? 1 : 2
        }
        XCTAssertEqual(group(groups), [["left-a", "left-b"], ["right-a"]])
    }

    func testAnUnknownDisplayFallsBackToTheScreenItOverlapsMost() {
        let windows = [
            makeWindow("mostly-right", frame: CGRect(x: 900, y: 100, width: 600, height: 300)),
        ]
        let groups = WorkspaceStore.layoutGroups(for: windows, screens: [left, right]) { _ in nil }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.screen.id, 2)
    }

    func testAWindowOnNoScreenGoesToTheFirstScreen() {
        let windows = [
            makeWindow("parked", frame: CGRect(x: 5000, y: 5000, width: 200, height: 200)),
        ]
        let groups = WorkspaceStore.layoutGroups(for: windows, screens: [left, right]) { _ in nil }
        XCTAssertEqual(groups.first?.screen.id, 1)
    }

    func testAKnownDisplayWinsOverGeometry() {
        // Mirrored or overlapping screens: the frame would say "left", the
        // display identity says "right", and identity is the authority.
        let windows = [
            makeWindow("mirrored", frame: CGRect(x: 100, y: 100, width: 300, height: 300)),
        ]
        let groups = WorkspaceStore.layoutGroups(for: windows, screens: [left, right]) { _ in 2 }
        XCTAssertEqual(groups.map(\.screen.id), [2])
    }

    func testGroupsWithNoWindowsAreOmitted() {
        let windows = [
            makeWindow("only-left", frame: CGRect(x: 0, y: 0, width: 300, height: 300)),
        ]
        let groups = WorkspaceStore.layoutGroups(for: windows, screens: [left, right]) { _ in 1 }
        XCTAssertEqual(groups.map(\.screen.id), [1])
    }

    func testNoScreensMeansNoGroups() {
        let windows = [makeWindow("a", frame: CGRect(x: 0, y: 0, width: 300, height: 300))]
        XCTAssertTrue(WorkspaceStore.layoutGroups(for: windows, screens: []) { _ in 1 }.isEmpty)
    }

    func testTiesGoToTheEarlierScreen() {
        // A window split exactly between the two screens: the first screen
        // wins, so two identical runs cannot disagree.
        let windows = [
            makeWindow("straddle", frame: CGRect(x: 900, y: 0, width: 200, height: 300)),
        ]
        let groups = WorkspaceStore.layoutGroups(for: windows, screens: [left, right]) { _ in nil }
        XCTAssertEqual(groups.first?.screen.id, 1)
    }
}
