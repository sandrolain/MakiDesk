import CoreGraphics
import XCTest
@testable import MakiDesk

/// Utility windows open on the display with the focused window and recenter
/// when they were last used on another one.
@MainActor
final class UtilityWindowPlacementTests: XCTestCase {
    func testCenteredFrameOnTheMainScreen() {
        let frame = UtilityWindowPlacement.centeredFrame(
            size: CGSize(width: 400, height: 300),
            in: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        XCTAssertEqual(frame, CGRect(x: 300, y: 250, width: 400, height: 300))
    }

    func testCenteredFrameOnADisplayWithNegativeOrigin() {
        let frame = UtilityWindowPlacement.centeredFrame(
            size: CGSize(width: 400, height: 300),
            in: CGRect(x: -1200, y: 0, width: 1200, height: 800)
        )
        XCTAssertEqual(frame, CGRect(x: -800, y: 250, width: 400, height: 300))
    }

    func testOversizedWindowIsClampedWithAMargin() {
        let frame = UtilityWindowPlacement.centeredFrame(
            size: CGSize(width: 2000, height: 1000),
            in: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        XCTAssertEqual(frame, CGRect(x: 20, y: 20, width: 960, height: 760))
    }

    func testARoundedPositionIsStable() {
        let visible = CGRect(x: 0.5, y: 0.25, width: 1000.5, height: 800.25)
        let frame = UtilityWindowPlacement.centeredFrame(size: CGSize(width: 401, height: 301),
                                                         in: visible)
        XCTAssertEqual(frame.minX, frame.minX.rounded())
        XCTAssertEqual(frame.minY, frame.minY.rounded())
        XCTAssertEqual(frame.width, 401)
        XCTAssertEqual(frame.height, 301)
    }
}
