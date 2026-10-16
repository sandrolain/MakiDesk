import XCTest
@testable import OrbitDesk

final class GeometryTests: XCTestCase {
    private let area = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private let minor = 1 - 1 / TilingEngine.phi

    func testLadderHasSevenStates() {
        let rects = TilingEngine.ladderRects(area: area, axis: .horizontal, orthogonal: 0...600)
        XCTAssertEqual(rects.count, 7)
    }

    func testHorizontalLadderFractions() {
        let rects = TilingEngine.ladderRects(area: area, axis: .horizontal, orthogonal: 0...600)
        XCTAssertEqual(rects[0].minX, 0, accuracy: 0.5)
        XCTAssertEqual(rects[0].width, minor * area.width, accuracy: 0.5)
        XCTAssertEqual(rects[2].width, area.width / TilingEngine.phi, accuracy: 0.5)
        XCTAssertEqual(rects[3].width, area.width, accuracy: 0.5)
        XCTAssertEqual(rects[6].maxX, area.width, accuracy: 0.5)
        XCTAssertEqual(rects[6].width, minor * area.width, accuracy: 0.5)
    }

    func testLadderKeepsOrthogonalBand() {
        let rects = TilingEngine.ladderRects(area: area, axis: .horizontal, orthogonal: 100...400)
        for rect in rects {
            XCTAssertEqual(rect.minY, 100, accuracy: 0.01)
            XCTAssertEqual(rect.height, 300, accuracy: 0.01)
        }
    }

    func testVerticalLadderFitsHeight() {
        let rects = TilingEngine.ladderRects(area: area, axis: .vertical, orthogonal: 0...1000)
        XCTAssertEqual(rects[0].height, minor * area.height, accuracy: 0.5)
        XCTAssertEqual(rects[3].height, area.height, accuracy: 0.5)
        for rect in rects {
            XCTAssertEqual(rect.minX, 0, accuracy: 0.01)
            XCTAssertEqual(rect.width, area.width, accuracy: 0.01)
        }
    }

    func testNearestIndexSnapsToExactState() {
        let rects = TilingEngine.ladderRects(area: area, axis: .horizontal, orthogonal: 0...600)
        for (index, rect) in rects.enumerated() {
            XCTAssertEqual(TilingEngine.nearestIndex(to: rect, among: rects), index)
        }
    }

    func testRegionRectNormalised() {
        let rect = TilingEngine.regionRect(area: area, relative: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        XCTAssertEqual(rect, CGRect(x: 500, y: 300, width: 500, height: 300))
    }

    func testPalettePositions() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 200, height: 100)
        XCTAssertEqual(PalettePosition.topLeft.origin(size: size, in: frame), CGPoint(x: 24, y: 676))
        XCTAssertEqual(PalettePosition.topRight.origin(size: size, in: frame), CGPoint(x: 776, y: 676))
        XCTAssertEqual(PalettePosition.center.origin(size: size, in: frame), CGPoint(x: 400, y: 350))
        XCTAssertEqual(PalettePosition.bottomLeft.origin(size: size, in: frame), CGPoint(x: 24, y: 24))
    }

    func testThemeLookup() {
        XCTAssertEqual(PaletteTheme.named("dracula").name, "Dracula")
        XCTAssertEqual(PaletteTheme.named("does-not-exist").id, PaletteTheme.all[0].id)
        XCTAssertFalse(PaletteTheme.named("catppuccin-mocha").background == PaletteTheme.named("catppuccin-latte").background)
    }
}
