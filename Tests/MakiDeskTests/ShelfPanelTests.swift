import XCTest
@testable import MakiDesk

@MainActor
final class ShelfPanelTests: XCTestCase {
    func testHeaderAcceptsTheFirstMouseSoAShakeOpenedShelfCanMoveImmediately() {
        // A shake opens the shelf without taking focus. The first click must
        // start the window drag instead of being consumed by activation.
        XCTAssertTrue(ShelfHeaderView().acceptsFirstMouse(for: nil))
    }

    func testRowAndHandleAcceptTheFirstMouseSoADragCanStartOnTheFirstClick() {
        // A row drag from a shelf that is visible but not key must start on the
        // first click, exactly like the second click does today.
        XCTAssertTrue(ShelfTableView().acceptsFirstMouse(for: nil))
        XCTAssertTrue(ShelfDragHandle().acceptsFirstMouse(for: nil))
    }
}
