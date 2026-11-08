import XCTest
@testable import MakiTerminalCore

final class TerminalSearchTests: XCTestCase {
    func testAnEmptyStateHasNoLabel() {
        let state = TerminalSearchState(needle: "abc")
        XCTAssertEqual(state.countText, "")
        XCTAssertFalse(state.hasResults)
    }

    func testATotalWithoutASelectionStartsAtTheFirstMatch() {
        var state = TerminalSearchState(needle: "abc")
        state.apply(total: 17)
        XCTAssertEqual(state.countText, "1 of 17")
        XCTAssertTrue(state.hasResults)
    }

    func testTheSelectionIsClampedToTheTotal() {
        var state = TerminalSearchState(needle: "abc")
        state.apply(total: 3)
        state.apply(selected: 9)
        XCTAssertEqual(state.countText, "3 of 3")
        state.apply(selected: 0)
        XCTAssertEqual(state.countText, "1 of 3")
    }

    func testNoMatchesReadAsSuch() {
        var state = TerminalSearchState(needle: "abc")
        state.apply(total: 0)
        state.apply(selected: 2)
        XCTAssertEqual(state.countText, "No results")
        XCTAssertEqual(state.selected, nil)
        XCTAssertFalse(state.hasResults)
    }

    func testNegativeReportsAreUnknownNotZero() {
        var state = TerminalSearchState()
        state.apply(total: -1)
        XCTAssertNil(state.total)
        XCTAssertEqual(state.countText, "")
        state.apply(selected: -1)
        XCTAssertNil(state.selected)
    }

    func testASelectionWithoutATotalIsKeptUntilTheTotalArrives() {
        var state = TerminalSearchState()
        state.apply(selected: 4)
        XCTAssertEqual(state.selected, 4)
        XCTAssertEqual(state.countText, "")
        state.apply(total: 9)
        XCTAssertEqual(state.countText, "4 of 9")
    }

    func testTheBindingActionsNameGhosttysGrammar() {
        XCTAssertEqual(TerminalSearchNavigation.next.bindingAction, "navigate_search:next")
        XCTAssertEqual(TerminalSearchNavigation.previous.bindingAction, "navigate_search:previous")
        XCTAssertEqual(TerminalSearchNavigation.needleAction("let foo"), "search:let foo")
        XCTAssertEqual(TerminalSearchNavigation.endAction, "end_search")
        XCTAssertEqual(TerminalSearchNavigation.startAction, "start_search")
    }
}
