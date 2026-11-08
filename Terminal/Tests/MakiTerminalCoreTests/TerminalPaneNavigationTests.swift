import CoreGraphics
import XCTest
@testable import MakiTerminalCore

final class TerminalPaneNavigationTests: XCTestCase {
    private let topLeft = PaneID()
    private let topRight = PaneID()
    private let bottomLeft = PaneID()
    private let bottomRight = PaneID()

    private var grid: [PaneID: CGRect] {
        [
            topLeft: CGRect(x: 0, y: 300, width: 500, height: 300),
            topRight: CGRect(x: 500, y: 300, width: 500, height: 300),
            bottomLeft: CGRect(x: 0, y: 0, width: 500, height: 300),
            bottomRight: CGRect(x: 500, y: 0, width: 500, height: 300),
        ]
    }

    func testTheGridMovesToTheAlignedNeighbour() {
        XCTAssertEqual(TerminalPaneNavigation.neighbor(of: topLeft, in: grid, direction: .right),
                       topRight)
        XCTAssertEqual(TerminalPaneNavigation.neighbor(of: topLeft, in: grid, direction: .down),
                       bottomLeft)
        XCTAssertEqual(TerminalPaneNavigation.neighbor(of: bottomRight, in: grid, direction: .left),
                       bottomLeft)
        XCTAssertEqual(TerminalPaneNavigation.neighbor(of: bottomRight, in: grid, direction: .up),
                       topRight)
    }

    func testTheEdgePaneHasNoNeighbour() {
        XCTAssertNil(TerminalPaneNavigation.neighbor(of: topRight, in: grid, direction: .right))
        XCTAssertNil(TerminalPaneNavigation.neighbor(of: topLeft, in: grid, direction: .up))
    }

    func testUnequalSplitsStillPickTheNearestPane() {
        let narrow = PaneID()
        let wide = PaneID()
        let frames: [PaneID: CGRect] = [
            narrow: CGRect(x: 0, y: 0, width: 200, height: 600),
            wide: CGRect(x: 200, y: 0, width: 800, height: 600),
        ]
        XCTAssertEqual(TerminalPaneNavigation.neighbor(of: narrow, in: frames, direction: .right),
                       wide)
    }

    func testAPaneInTheDirectionIsReachedWithoutVerticalOverlap() {
        let left = PaneID()
        let right = PaneID()
        let frames: [PaneID: CGRect] = [
            left: CGRect(x: 0, y: 0, width: 400, height: 600),
            right: CGRect(x: 400, y: 500, width: 400, height: 100),
        ]
        XCTAssertEqual(TerminalPaneNavigation.neighbor(of: left, in: frames, direction: .right),
                       right)
    }

    func testATinyZeroSizedPaneHasNoNeighbour() {
        let zero = PaneID()
        let other = PaneID()
        let frames: [PaneID: CGRect] = [
            zero: CGRect(x: 10, y: 10, width: 0, height: 0),
            other: CGRect(x: 50, y: 50, width: 100, height: 100),
        ]
        XCTAssertNil(TerminalPaneNavigation.neighbor(of: zero, in: frames, direction: .right))
    }

    func testACandidateDirectlyAtTheSameCentreIsNotANeighbour() {
        let a = PaneID()
        let b = PaneID()
        let frames: [PaneID: CGRect] = [
            a: CGRect(x: 0, y: 0, width: 100, height: 100),
            b: CGRect(x: 0, y: 0, width: 100, height: 100),
        ]
        XCTAssertNil(TerminalPaneNavigation.neighbor(of: a, in: frames, direction: .right))
    }
}
