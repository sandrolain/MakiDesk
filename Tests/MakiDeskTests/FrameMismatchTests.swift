import CoreGraphics
import XCTest
@testable import MakiDesk

/// The readback classifier: what a frame difference means, and which cases
/// deserve another write. Pure, so every rule is a table entry.
final class FrameMismatchTests: XCTestCase {
    private let previous = CGRect(x: 100, y: 100, width: 400, height: 300)
    private let wanted = CGRect(x: 200, y: 150, width: 800, height: 600)

    func testAnExactFrameIsAccepted() {
        XCTAssertEqual(FrameMismatch.classify(wanted: wanted, previous: previous, actual: wanted),
                       .accepted)
    }

    func testAPointAndTwoPointsAreStillAccepted() {
        let actual = CGRect(x: 201, y: 149, width: 801, height: 598)
        XCTAssertEqual(FrameMismatch.classify(wanted: wanted, previous: previous, actual: actual),
                       .accepted)
        let chrome = CGRect(x: 202, y: 148, width: 800, height: 600)
        XCTAssertEqual(FrameMismatch.classify(wanted: wanted, previous: previous, actual: chrome),
                       .accepted)
    }

    func testACharacterCellOfRoundingIsAcceptedWithTheRealFrame() {
        let actual = CGRect(x: 200, y: 150, width: 800, height: 608)
        XCTAssertEqual(FrameMismatch.classify(wanted: wanted, previous: previous, actual: actual),
                       .rounded)
    }

    func testTwentyPointsOfSizeAreStillRounding() {
        let actual = CGRect(x: 200, y: 150, width: 820, height: 580)
        XCTAssertEqual(FrameMismatch.classify(wanted: wanted, previous: previous, actual: actual),
                       .rounded)
    }

    func testMoreThanTwentyPointsIsARefusal() {
        let actual = CGRect(x: 200, y: 150, width: 821, height: 600)
        XCTAssertEqual(FrameMismatch.classify(wanted: wanted, previous: previous, actual: actual),
                       .refused)
    }

    func testAPositionThatLandedButKeptTheOldSizeAsksForOneSizeFirstRetry() {
        let actual = CGRect(x: 200, y: 150, width: 400, height: 300)
        XCTAssertEqual(FrameMismatch.classify(wanted: wanted, previous: previous, actual: actual),
                       .sizeIgnored)
    }

    func testAnAppThatKeptOneLengthAndTookTheOtherIsARealRefusal() {
        let actual = CGRect(x: 200, y: 150, width: 400, height: 600)
        XCTAssertEqual(FrameMismatch.classify(wanted: wanted, previous: previous, actual: actual),
                       .refused)
    }

    func testAFrameBetweenWhereItWasAndTheTargetIsStillSettling() {
        let actual = CGRect(x: 200, y: 150, width: 600, height: 450)
        XCTAssertEqual(FrameMismatch.classify(wanted: wanted, previous: previous, actual: actual),
                       .settling)
    }

    func testAWindowThatHasNotMovedYetIsSettling() {
        XCTAssertEqual(FrameMismatch.classify(wanted: wanted, previous: previous, actual: previous),
                       .settling)
    }

    func testAFrameAwayFromTheTargetAndTheOriginIsARefusal() {
        let actual = CGRect(x: 600, y: 500, width: 800, height: 600)
        XCTAssertEqual(FrameMismatch.classify(wanted: wanted, previous: previous, actual: actual),
                       .refused)
    }

    func testAnUnreadableFrameSaysNothingAboutGeometry() {
        XCTAssertEqual(FrameMismatch.classify(wanted: wanted, previous: previous, actual: nil),
                       .unreadable)
        XCTAssertEqual(FrameMismatch.classify(
            wanted: wanted, previous: previous,
            actual: CGRect(x: 0, y: 0, width: 0, height: 0)), .unreadable)
    }
}
