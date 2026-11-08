import XCTest
@testable import MakiTerminalCore

final class TerminalQuakePlacementTests: XCTestCase {
    func testTheQuakeSitsAtTheTopOfTheVisibleFrame() {
        let frame = TerminalQuakePlacement.frame(
            in: CGRect(x: 0, y: 0, width: 1440, height: 900),
            heightFraction: 0.45
        )
        XCTAssertEqual(frame, CGRect(x: 0, y: 495, width: 1440, height: 405))
    }

    func testANegativeDisplayOriginIsPreserved() {
        let frame = TerminalQuakePlacement.frame(
            in: CGRect(x: -1920, y: 200, width: 1920, height: 1080),
            heightFraction: 0.5
        )
        XCTAssertEqual(frame, CGRect(x: -1920, y: 740, width: 1920, height: 540))
    }

    func testATinyDisplayKeepsThePanelInside() {
        let frame = TerminalQuakePlacement.frame(
            in: CGRect(x: 0, y: 0, width: 800, height: 200),
            heightFraction: 0.5
        )
        XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 800, height: 200))
    }

    func testTheFractionIsClampedToTheSettingsRange() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        XCTAssertEqual(TerminalQuakePlacement.frame(in: visible, heightFraction: 0.1).height,
                       300)
        XCTAssertEqual(TerminalQuakePlacement.frame(in: visible, heightFraction: 2).height,
                       600)
    }

    func testTheMenuBarAndDockAreLeftAlone() {
        let visible = CGRect(x: 0, y: 80, width: 1200, height: 800)
        let frame = TerminalQuakePlacement.frame(in: visible, heightFraction: 0.4)
        XCTAssertEqual(frame.minY, 560)
        XCTAssertEqual(frame.maxY, 880)
        XCTAssertEqual(frame.maxY, visible.maxY)
    }
}
