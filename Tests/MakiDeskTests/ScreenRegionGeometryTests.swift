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
        // The guides are drawn on the candidate the side moved to.
        XCTAssertEqual(result.edgesX, [298])
        XCTAssertEqual(result.edgesY, [225])
    }

    func testSnapIgnoresEdgesBeyondTheTolerance() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 120)
        let result = ScreenRegionGeometry.snapped(rect,
                                                  edgesX: [280], edgesY: [200],
                                                  tolerance: 6)
        XCTAssertEqual(result.rect, rect)
        XCTAssertFalse(result.snappedX)
        XCTAssertFalse(result.snappedY)
        XCTAssertEqual(result.edgesX, [])
        XCTAssertEqual(result.edgesY, [])
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
        XCTAssertEqual(result.edgesX, [])
        XCTAssertEqual(result.edgesY, [])
    }

    // MARK: - Sticky snap and guides (T39)

    func testOnlyMovingSidesSnap() {
        // The anchor side is 2 pt from an edge; dragging up/right must not move
        // it, so the rectangle cannot jump back to the start.
        let rect = CGRect(x: 100, y: 100, width: 200, height: 120)
        let result = ScreenRegionGeometry.snapped(
            rect, edgesX: [98, 302], edgesY: [98, 225], tolerance: 6,
            movingX: (low: false, high: true),
            movingY: (low: false, high: true)
        )
        XCTAssertEqual(result.rect, CGRect(x: 100, y: 100, width: 202, height: 125))
        XCTAssertEqual(result.edgesX, [302])
        XCTAssertEqual(result.edgesY, [225])
        XCTAssertNil(result.stateX.lowEdge)
        XCTAssertEqual(result.stateX.highEdge, 302)
    }

    func testHysteresisKeepsASideSnappedUntilItPullsAway() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 120)
        let first = ScreenRegionGeometry.snapped(
            rect, edgesX: [302], edgesY: [], tolerance: 6,
            movingX: (low: false, high: true), movingY: (false, false),
            releaseTolerance: 10
        )
        XCTAssertEqual(first.stateX.highEdge, 302)

        // Still within the release distance: stay on the edge.
        let held = ScreenRegionGeometry.snapped(
            CGRect(x: 100, y: 100, width: 208, height: 120),
            edgesX: [302], edgesY: [], tolerance: 6,
            movingX: (low: false, high: true), movingY: (false, false),
            previousX: first.stateX, releaseTolerance: 10
        )
        XCTAssertEqual(held.rect.maxX, 302)

        // Pulled farther than the release distance: let go.
        let released = ScreenRegionGeometry.snapped(
            CGRect(x: 100, y: 100, width: 220, height: 120),
            edgesX: [302], edgesY: [], tolerance: 6,
            movingX: (low: false, high: true), movingY: (false, false),
            previousX: held.stateX, releaseTolerance: 10
        )
        XCTAssertEqual(released.rect.maxX, 320)
        XCTAssertNil(released.stateX.highEdge)
    }

    func testBothSidesCanSnapToDifferentEdges() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 120)
        let result = ScreenRegionGeometry.snapped(
            rect, edgesX: [98, 303], edgesY: [], tolerance: 6
        )
        XCTAssertEqual(result.rect, CGRect(x: 98, y: 100, width: 205, height: 120))
        XCTAssertEqual(result.edgesX, [98, 303])
    }

    func testCandidatesOutsideTheDisplayAreIgnored() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 120)
        let result = ScreenRegionGeometry.snapped(
            rect, edgesX: [98, 305], edgesY: [], tolerance: 6,
            limits: CGRect(x: 100, y: 0, width: 200, height: 400)
        )
        XCTAssertEqual(result.rect.minX, 100)
        XCTAssertEqual(result.edgesX, [])
    }

    func testRoundedSidesQuantiseTheRectangle() {
        let rect = CGRect(x: 10.4, y: 20.6, width: 100.2, height: 40.1)
        XCTAssertEqual(ScreenRegionGeometry.rounded(rect),
                       CGRect(x: 10, y: 21, width: 101, height: 40))
    }

    func testFrameOwningAnEdgePrefersTheWindowOverTheDisplay() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let window = CGRect(x: 0, y: 100, width: 200, height: 300)
        XCTAssertEqual(ScreenRegionGeometry.frame(owningEdge: 0, axis: .x,
                                                  in: [display, window]), window)
        XCTAssertEqual(ScreenRegionGeometry.frame(owningEdge: 800, axis: .y,
                                                  in: [display, window]), display)
        XCTAssertNil(ScreenRegionGeometry.frame(owningEdge: 42, axis: .x, in: [display, window]))
    }

    func testSnappedOriginLocksTheVisibleGuide() {
        let limits = CGRect(x: 0, y: 0, width: 400, height: 300)
        let both = ScreenRegionGeometry.snappedOrigin(
            CGPoint(x: 98, y: 202), edgesX: [100, 250], edgesY: [200, 280],
            tolerance: 6, limits: limits
        )
        XCTAssertEqual(both.point, CGPoint(x: 100, y: 200))
        XCTAssertEqual(both.edgeX, 100)
        XCTAssertEqual(both.edgeY, 200)

        let oneAxis = ScreenRegionGeometry.snappedOrigin(
            CGPoint(x: 120, y: 97), edgesX: [100], edgesY: [200], tolerance: 6, limits: limits
        )
        XCTAssertEqual(oneAxis.point, CGPoint(x: 120, y: 97))
        XCTAssertNil(oneAxis.edgeX)
        XCTAssertNil(oneAxis.edgeY)
    }

    func testSnappedOriginIgnoresCandidatesOutsideTheDisplay() {
        let limits = CGRect(x: 0, y: 0, width: 200, height: 200)
        let origin = ScreenRegionGeometry.snappedOrigin(
            CGPoint(x: 202, y: 100), edgesX: [210], edgesY: [],
            tolerance: 10, limits: limits
        )
        XCTAssertEqual(origin.point, CGPoint(x: 202, y: 100))
        XCTAssertNil(origin.edgeX)
    }

    func testNearestEdgeFindsTheHoverCandidateWithinTolerance() {
        XCTAssertEqual(ScreenRegionGeometry.nearestEdge(to: 100, in: [90, 104], tolerance: 6), 104)
        XCTAssertEqual(ScreenRegionGeometry.nearestEdge(to: 94, in: [90, 104], tolerance: 6), 90)
        XCTAssertNil(ScreenRegionGeometry.nearestEdge(to: 100, in: [90, 110], tolerance: 6))
        XCTAssertNil(ScreenRegionGeometry.nearestEdge(to: 100, in: [], tolerance: 6))
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
