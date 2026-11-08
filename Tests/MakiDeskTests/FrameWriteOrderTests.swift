import CoreGraphics
import XCTest
@testable import MakiDesk

/// Which AX writes a frame command makes, in which order. Pure decisions, so
/// the cross-screen cases are checked without two displays.
final class FrameWriteOrderTests: XCTestCase {
    private let target = CGRect(x: 100, y: 100, width: 800, height: 600)
    private let previous = CGRect(x: 0, y: 0, width: 400, height: 300)
    private let source = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testATargetThatFitsTheSourceWritesSizeMoveSize() {
        XCTAssertEqual(
            WorkspaceStore.frameWriteOrder(for: target, previous: previous,
                                           sourceArea: source, destinationArea: source),
            .sizePositionSize)
    }

    func testATargetBiggerThanTheSourceMovesFirst() {
        let big = CGRect(x: 100, y: 100, width: 1500, height: 600)
        XCTAssertEqual(
            WorkspaceStore.frameWriteOrder(for: big, previous: previous,
                                           sourceArea: source, destinationArea: source),
            .positionThenSize)
    }

    func testAnOffScreenWindowMovesFirstWhenItsOldSizeFitsAtTheTarget() {
        XCTAssertEqual(
            WorkspaceStore.frameWriteOrder(for: target, previous: previous,
                                           sourceArea: nil, destinationArea: source),
            .positionThenSize)
    }

    func testAnOffScreenWindowStagesWhenItsOldSizeWouldHangOff() {
        let bigPrevious = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let smallDestination = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let target = CGRect(x: 500, y: 300, width: 800, height: 600)
        XCTAssertEqual(
            WorkspaceStore.frameWriteOrder(for: target, previous: bigPrevious,
                                           sourceArea: nil,
                                           destinationArea: smallDestination),
            .staged(staging: CGPoint(x: 200, y: 100)))
    }

    func testAnOffScreenWindowBiggerThanTheDestinationJustMovesFirst() {
        let huge = CGRect(x: 0, y: 0, width: 2000, height: 900)
        XCTAssertEqual(
            WorkspaceStore.frameWriteOrder(for: target, previous: huge,
                                           sourceArea: nil, destinationArea: source),
            .positionThenSize)
    }

    func testAScaleHopIsDetected() {
        XCTAssertTrue(WorkspaceStore.crossesScale(1, 2))
        XCTAssertTrue(WorkspaceStore.crossesScale(2, 1))
        XCTAssertFalse(WorkspaceStore.crossesScale(2, 2))
        XCTAssertFalse(WorkspaceStore.crossesScale(nil, 2))
    }
}
