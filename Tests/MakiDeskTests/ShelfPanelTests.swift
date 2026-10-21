import XCTest
@testable import MakiDesk

@MainActor
final class ShelfPanelTests: XCTestCase {
    func testHeaderAcceptsTheFirstMouseSoAShakeOpenedShelfCanMoveImmediately() {
        // A shake opens the shelf without taking focus. The first click must
        // start the window drag instead of being consumed by activation.
        XCTAssertTrue(ShelfHeaderView().acceptsFirstMouse(for: nil))
    }
}
