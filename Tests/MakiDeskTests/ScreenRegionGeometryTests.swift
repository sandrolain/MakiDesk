import XCTest
@testable import MakiDesk

/// T49, the geometry behind the shared region selector. No desktop, no capture:
/// drag normalization, clamping, snapping, display choice and the point → pixel
/// conversion that decides the crop.
final class ScreenRegionGeometryTests: XCTestCase {
    private let primary = ScreenRegionDisplay(
        id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2
    )

    /// A display to the left of the primary one: negative origin, which is a
    /// normal layout, not a bug.
    private let left = ScreenRegionDisplay(
        id: 2, frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080), scale: 1
    )

    // MARK: - Drag

    func testRectNormalizesEveryDragDirection() {
        let expected = CGRect(x: 10, y: 20, width: 30, height: 40)
        for (start, end) in [
            (CGPoint(x: 10, y: 20), CGPoint(x: 40, y: 60)),
            (CGPoint(x: 40, y: 20), CGPoint(x: 10, y: 60)),
            (CGPoint(x: 10, y: 60), CGPoint(x: 40, y: 20)),
            (CGPoint(x: 40, y: 60), CGPoint(x: 10, y: 20))
        ] {
            XCTAssertEqual(ScreenRegionGeometry.rect(from: start, to: end), expected)
        }
    }

    func testRectBelowTheMinimumIsNotASelection() {
        let start = CGPoint(x: 100, y: 100)
        XCTAssertNil(ScreenRegionGeometry.rect(from: start, to: CGPoint(x: 103, y: 100)))
        XCTAssertNil(ScreenRegionGeometry.rect(from: start, to: CGPoint(x: 100, y: 103)))
        XCTAssertNotNil(ScreenRegionGeometry.rect(from: start, to: CGPoint(x: 104, y: 104)))
    }

    func testClampKeepsTheSelectionOnItsDisplay() {
        let rect = CGRect(x: -100, y: 800, width: 500, height: 300)
        let clamped = ScreenRegionGeometry.clamped(rect, to: primary)
        XCTAssertEqual(clamped, CGRect(x: 0, y: 800, width: 400, height: 100))
    }

    func testClampOnADisplayWithNegativeOrigin() {
        let rect = CGRect(x: -2000, y: -100, width: 200, height: 200)
        let clamped = ScreenRegionGeometry.clamped(rect, to: left)
        XCTAssertEqual(clamped, CGRect(x: -1920, y: -100, width: 120, height: 200))
    }

    // MARK: - Snapping

    func testSnapPullsTheNearestSideToAnEdge() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 120)
        let result = ScreenRegionGeometry.snapped(rect,
                                                  edgesX: [298], edgesY: [225],
                                                  tolerance: 6)
        XCTAssertEqual(result.rect, CGRect(x: 100, y: 100, width: 198, height: 125))
        XCTAssertTrue(result.snappedX)
        XCTAssertTrue(result.snappedY)
    }

    func testSnapIgnoresEdgesBeyondTheTolerance() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 120)
        let result = ScreenRegionGeometry.snapped(rect,
                                                  edgesX: [280], edgesY: [200],
                                                  tolerance: 6)
        XCTAssertEqual(result.rect, rect)
        XCTAssertFalse(result.snappedX)
        XCTAssertFalse(result.snappedY)
    }

    func testSnapNeverCollapsesTheRectangle() {
        // The nearest edge would move the top side past the bottom one: the
        // snap is refused instead of producing a 3-point sliver.
        let rect = CGRect(x: 100, y: 100, width: 4, height: 10)
        let result = ScreenRegionGeometry.snapped(rect,
                                                  edgesX: [102, 103],
                                                  edgesY: [500],
                                                  tolerance: 10)
        XCTAssertEqual(result.rect, rect)
        XCTAssertFalse(result.snappedX)
        XCTAssertFalse(result.snappedY)
    }

    func testEdgesAreSortedAndUnique() {
        let edges = ScreenRegionGeometry.edges(of: [
            CGRect(x: 0, y: 0, width: 100, height: 50),
            CGRect(x: 100, y: 50, width: 20, height: 20)
        ])
        XCTAssertEqual(edges.x, [0, 100, 120])
        XCTAssertEqual(edges.y, [0, 50, 70])
    }

    // MARK: - Displays

    func testDisplayUnderAPointIncludesNegativeOrigins() {
        let hit = ScreenRegionGeometry.display(containing: CGPoint(x: -100, y: 10),
                                               in: [primary, left])
        XCTAssertEqual(hit?.id, left.id)
    }

    func testPointInAGapFallsBackToTheNearestDisplay() {
        let lower = ScreenRegionDisplay(
            id: 3, frame: CGRect(x: 0, y: -1200, width: 800, height: 600), scale: 2
        )
        // Between the primary display and the one below it.
        let hit = ScreenRegionGeometry.display(containing: CGPoint(x: 400, y: -400),
                                               in: [primary, lower])
        XCTAssertEqual(hit?.id, lower.id)
    }

    // MARK: - Cropping

    func testDisplayLocalRectFlipsTheOriginToTopLeft() {
        let local = ScreenRegionGeometry.displayLocalRect(
            CGRect(x: 100, y: 700, width: 200, height: 100), in: primary
        )
        XCTAssertEqual(local, CGRect(x: 100, y: 100, width: 200, height: 100))
    }

    func testDisplayLocalRectOnASecondDisplay() {
        let local = ScreenRegionGeometry.displayLocalRect(
            CGRect(x: -1900, y: 100, width: 100, height: 50), in: left
        )
        XCTAssertEqual(local, CGRect(x: 20, y: 730, width: 100, height: 50))
    }

    func testPixelRectUsesTheCapturedImageScale() {
        let local = CGRect(x: 10, y: 20, width: 30, height: 40)
        let pixels = ScreenRegionGeometry.pixelRect(
            for: local, imageSize: CGSize(width: 2880, height: 1800),
            displaySize: CGSize(width: 1440, height: 900)
        )
        XCTAssertEqual(pixels, CGRect(x: 20, y: 40, width: 60, height: 80))
    }

    func testPixelRectClampsToTheImage() {
        let local = CGRect(x: 1400, y: 880, width: 100, height: 60)
        let pixels = ScreenRegionGeometry.pixelRect(
            for: local, imageSize: CGSize(width: 2880, height: 1800),
            displaySize: CGSize(width: 1440, height: 900)
        )
        XCTAssertEqual(pixels, CGRect(x: 2800, y: 1760, width: 80, height: 40))
    }

    func testPixelRectRoundsAHalfPixel() {
        let local = CGRect(x: 10.25, y: 10.4, width: 9.5, height: 9.6)
        let pixels = ScreenRegionGeometry.pixelRect(
            for: local, imageSize: CGSize(width: 100, height: 100),
            displaySize: CGSize(width: 100, height: 100)
        )
        XCTAssertEqual(pixels, CGRect(x: 10, y: 10, width: 10, height: 10))
    }

    // MARK: - Label

    func testSizeLabelShowsPointsAndPixelsOnRetina() {
        let label = ScreenRegionGeometry.sizeLabel(
            for: CGRect(x: 0, y: 0, width: 320, height: 180), scale: 2
        )
        XCTAssertEqual(label, "320 × 180 pt · 640 × 360 px")
    }

    func testSizeLabelShowsPointsOnlyAtOneX() {
        let label = ScreenRegionGeometry.sizeLabel(
            for: CGRect(x: 0, y: 0, width: 320.4, height: 180.6), scale: 1
        )
        XCTAssertEqual(label, "320 × 181 pt")
    }
}
