import CoreGraphics
import XCTest
@testable import MakiDesk

/// Which AX writes a frame command makes, in which order. Pure decisions, so
/// the cross-screen cases are checked without two displays.
final class FrameWriteOrderTests: XCTestCase {
    private let target = CGRect(x: 100, y: 100, width: 800, height: 600)
    private let source = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testATargetThatFitsTheSourceWritesSizeMoveSize() {
        XCTAssertEqual(WorkspaceStore.frameWriteOrder(for: target, sourceArea: source),
                       .sizePositionSize)
    }

    func testATargetBiggerThanTheSourceMovesFirst() {
        let big = CGRect(x: 100, y: 100, width: 1500, height: 600)
        XCTAssertEqual(WorkspaceStore.frameWriteOrder(for: big, sourceArea: source),
                       .positionThenSize)
    }

    func testAnOffScreenWindowMovesFirst() {
        XCTAssertEqual(WorkspaceStore.frameWriteOrder(for: target, sourceArea: nil),
                       .positionThenSize)
    }

    func testAScaleHopIsDetected() {
        XCTAssertTrue(WorkspaceStore.crossesScale(1, 2))
        XCTAssertTrue(WorkspaceStore.crossesScale(2, 1))
        XCTAssertFalse(WorkspaceStore.crossesScale(2, 2))
        XCTAssertFalse(WorkspaceStore.crossesScale(nil, 2))
    }
}
