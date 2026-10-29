import CoreGraphics
import XCTest
@testable import MakiDesk

/// The small panels keep their corner unless the checklist card is already
/// there; then they step out of the way, with a margin, without leaving the
/// display.
final class CornerPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let mapSize = CGSize(width: 240, height: 160)

    private func card(top: Bool = true, height: CGFloat = 200) -> CGRect {
        // The checklist at half the window gap (6 pt) in the top-right corner.
        CGRect(x: screen.maxX - 320 - 6,
               y: top ? screen.maxY - height - 6 : screen.minY + 6,
               width: 320, height: height)
    }

    private func frame(_ position: PalettePosition, avoiding obstacle: CGRect?) -> CGRect {
        CornerPlacement.frame(size: mapSize, position: position, screen: screen,
                               avoiding: obstacle)
    }

    func testWithoutACardTheCornerIsUntouched() {
        for position in PalettePosition.allCases {
            let base = position.origin(size: mapSize, in: screen)
            let placed = frame(position, avoiding: nil)
            XCTAssertEqual(placed.origin, base, position.label)
            XCTAssertEqual(placed.size, mapSize)
        }
    }

    func testACornerFarFromTheCardIsUntouched() {
        let placed = frame(.topLeft, avoiding: card())
        XCTAssertEqual(placed.origin, PalettePosition.topLeft.origin(size: mapSize, in: screen))
    }

    func testTheMapStepsBelowTheCardInATopCorner() {
        let obstacle = card(top: true)
        let placed = frame(.topRight, avoiding: obstacle)
        XCTAssertFalse(placed.intersects(obstacle))
        // Below it, still in the same column, with the margin between. The map
        // keeps its own corner margin, so the columns only roughly line up.
        XCTAssertEqual(placed.maxY, obstacle.minY - CornerPlacement.spacing)
        XCTAssertEqual(placed.maxX,
                       PalettePosition.topRight.origin(size: mapSize, in: screen).x + mapSize.width)
        XCTAssertTrue(screen.contains(placed))
    }

    func testTheMapStepsAboveTheCardInABottomCorner() {
        let obstacle = card(top: false)
        let placed = frame(.bottomRight, avoiding: obstacle)
        XCTAssertFalse(placed.intersects(obstacle))
        XCTAssertEqual(placed.minY, obstacle.maxY + CornerPlacement.spacing)
        XCTAssertTrue(screen.contains(placed))
    }

    func testACentredCornerAlsoClearsTheCard() {
        let obstacle = card(top: true)
        for position in [PalettePosition.topCenter, .topRight, .topLeft] {
            let placed = frame(position, avoiding: obstacle)
            XCTAssertFalse(placed.intersects(obstacle), position.label)
            XCTAssertTrue(screen.contains(placed), position.label)
        }
    }

    func testWithNoRoomBelowTheMapMovesToTheSide() {
        // A tall card leaves no space under it on this display.
        let obstacle = CGRect(x: screen.maxX - 326, y: 100, width: 320, height: 794)
        let placed = frame(.topRight, avoiding: obstacle)
        XCTAssertFalse(placed.intersects(obstacle))
        XCTAssertTrue(screen.contains(placed))
        XCTAssertLessThanOrEqual(placed.maxX, obstacle.minX - CornerPlacement.spacing)
    }

    func testANegativeOriginDisplayIsHandled() {
        let left = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let obstacle = CGRect(x: left.maxX - 320 - 6, y: left.maxY - 206,
                              width: 320, height: 200)
        let placed = CornerPlacement.frame(size: mapSize, position: .topRight,
                                            screen: left, avoiding: obstacle)
        XCTAssertFalse(placed.intersects(obstacle))
        XCTAssertTrue(left.contains(placed))
    }

    func testAMiddlePositionStaysOnTheDisplay() {
        let obstacle = card(top: false)
        for position in [PalettePosition.bottomLeft, .center, .middleRight] {
            let placed = frame(position, avoiding: obstacle)
            XCTAssertTrue(screen.contains(placed), position.label)
            XCTAssertFalse(placed.intersects(obstacle), position.label)
        }
    }
}
