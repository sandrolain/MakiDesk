import XCTest
@testable import MakiDesk

final class PaletteOrderingTests: XCTestCase {
    func testRepeatedSingleSwitchAlternatesLastTwoWindows() {
        let first = ["A", "B", "C"]
        XCTAssertEqual(first[PaletteOrdering.initialSelection(ids: first, origin: "A", backwards: false)], "B")
        let next = ["B", "A", "C"]
        XCTAssertEqual(next[PaletteOrdering.initialSelection(ids: next, origin: "B", backwards: false)], "A")
    }

    func testRefreshDoesNotReorderExistingCardsAndAppendsNewWindows() {
        XCTAssertEqual(PaletteOrdering.stableOrder(existing: ["A", "B", "C"], incoming: ["D", "C", "B"]),
                       ["B", "C", "D"])
    }

    func testBackwardsSingleWindowAndMissingOrigin() {
        XCTAssertEqual(PaletteOrdering.initialSelection(ids: ["A", "B", "C"], origin: "A", backwards: true), 2)
        XCTAssertEqual(PaletteOrdering.initialSelection(ids: ["A"], origin: "A", backwards: false), 0)
        XCTAssertEqual(PaletteOrdering.initialSelection(ids: [], origin: "A", backwards: true), 0)
        XCTAssertEqual(PaletteOrdering.initialSelection(ids: ["A", "B"], origin: nil, backwards: false), 0)
    }
}
