import XCTest
import CoreGraphics
@testable import MakiDesk

final class FocusBorderTests: XCTestCase {
    func testWidthIsClampedToTheOfferedRange() {
        XCTAssertEqual(FocusBorder.clampedWidth(0), 1)
        XCTAssertEqual(FocusBorder.clampedWidth(3), 3)
        XCTAssertEqual(FocusBorder.clampedWidth(9), 8)
    }

    func testPanelSitsOutsideTheWindow() {
        let window = CGRect(x: 100, y: 80, width: 400, height: 300)
        let panel = FocusBorder.panelFrame(for: window, width: 3)
        XCTAssertEqual(panel, CGRect(x: 96, y: 76, width: 408, height: 308))
        XCTAssertEqual(FocusBorder.outwardReach(3), 4)
    }

    func testCornerRadiusNeverExceedsTheSmallFrame() {
        let roomy = CGRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertEqual(FocusBorder.cornerRadius(for: roomy, width: 3), 11)

        let tiny = CGRect(x: 0, y: 0, width: 6, height: 6)
        XCTAssertEqual(FocusBorder.cornerRadius(for: tiny, width: 3), 0.5)
    }
}
