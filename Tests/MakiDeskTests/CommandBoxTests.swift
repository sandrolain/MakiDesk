import XCTest
@testable import MakiDesk

/// T38: reading a typed command, choosing a suggestion and validating its
/// argument are decisions, so they are checked without a panel.
@MainActor
final class CommandBoxTests: XCTestCase {
    private func match(_ text: String) -> (entry: CommandEntry, argument: String)? {
        CommandCatalog.match(text)
    }

    // MARK: - Matching

    func testAPhraseIsReadTogether() {
        XCTAssertEqual(match("tile left")?.entry.id, "tile left")
        XCTAssertEqual(match("tile left")?.argument, "")
        XCTAssertEqual(match("TILE   LEFT")?.entry.id, "tile left")
    }

    func testTheLongestPhraseWins() {
        // "tile top left" must not be read as "tile top" plus a stray word.
        XCTAssertEqual(match("tile top left")?.entry.id, "tile top left")
        XCTAssertEqual(match("tile top")?.entry.id, "tile top")
        XCTAssertEqual(match("add group 3")?.entry.id, "add group")
    }

    func testAnArgumentIsKeptForTheCommandsThatTakeOne() {
        XCTAssertEqual(match("group 3")?.argument, "3")
        XCTAssertEqual(match("timer 25m")?.argument, "25m")
        XCTAssertEqual(match("timer 8:30")?.argument, "8:30")
    }

    func testACommandWithoutArgumentsRefusesOne() {
        XCTAssertNil(match("notes please"))
        XCTAssertNil(match("center now"))
        XCTAssertNil(match(""))
        XCTAssertNil(match("   "))
        XCTAssertNil(match("something else entirely"))
    }

    // MARK: - Suggestions

    func testSuggestionsFollowThePrefixAndKeepShortPhrasesFirst() {
        let list = CommandCatalog.suggestions(for: "tile")
        XCTAssertGreaterThanOrEqual(list.count, 4)
        XCTAssertEqual(list.first?.id, "tile left")
        XCTAssertTrue(list.allSatisfy { $0.id.hasPrefix("tile") })
        XCTAssertLessThanOrEqual(list.count, 7)
    }

    func testWordsFindACommandInAnyOrder() {
        let list = CommandCatalog.suggestions(for: "group add")
        XCTAssertTrue(list.contains { $0.id == "add group" }, "\(list.map(\.id))")
    }

    func testAnEmptyFieldOffersTheFirstCommands() {
        let list = CommandCatalog.suggestions(for: "")
        XCTAssertEqual(list.count, 7)
        XCTAssertEqual(list.first?.id, "tile left")
    }

    // MARK: - Arguments

    func testAGroupSlotMustBeOneToNine() {
        let entry = CommandCatalog.entries.first { $0.id == "group" }!
        XCTAssertEqual(CommandCatalog.validated(entry, argument: "3"), "3")
        XCTAssertNil(CommandCatalog.validated(entry, argument: "0"))
        XCTAssertNil(CommandCatalog.validated(entry, argument: "10"))
        XCTAssertNil(CommandCatalog.validated(entry, argument: "three"))
        XCTAssertNil(CommandCatalog.validated(entry, argument: ""))
    }

    func testATimerTakesWhateverTheBoxUnderstands() {
        let entry = CommandCatalog.entries.first { $0.id == "timer" }!
        XCTAssertEqual(CommandCatalog.validated(entry, argument: "25m"), "25m")
        XCTAssertEqual(CommandCatalog.validated(entry, argument: "8:30"), "8:30")
        XCTAssertNil(CommandCatalog.validated(entry, argument: "later"))
        XCTAssertNil(CommandCatalog.validated(entry, argument: ""))
    }

    func testACommandWithoutAnArgumentAcceptsAnEmptyOne() {
        let entry = CommandCatalog.entries.first { $0.id == "notes" }!
        XCTAssertEqual(CommandCatalog.validated(entry, argument: ""), "")
        XCTAssertNil(CommandCatalog.validated(entry, argument: "x"))
    }

    func testEveryPhraseIsUniqueAndHasASummary() {
        let ids = CommandCatalog.entries.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(CommandCatalog.entries.allSatisfy { $0.summary.isEmpty == false })
        // Every argument-taking phrase shows what it expects.
        for entry in CommandCatalog.entries where entry.argument != nil {
            XCTAssertTrue(CommandCatalog.display(entry).hasPrefix(entry.id))
            XCTAssertTrue(CommandCatalog.display(entry).count > entry.id.count)
        }
    }

    func testCompletionLeavesRoomForTheArgument() {
        let model = CommandBoxModel()
        model.text = "group"
        model.selection = 0
        model.complete()
        XCTAssertEqual(model.text, "group ")
        model.text = "note"
        model.selection = 0
        model.complete()
        XCTAssertEqual(model.text, "notes")
    }

    func testMovingTheSelectionWrapsInsideTheList() {
        let model = CommandBoxModel()
        model.text = "tile"
        model.selection = 0
        model.move(-1)
        XCTAssertEqual(model.selection, model.suggestions.count - 1)
        model.move(1)
        XCTAssertEqual(model.selection, 0)
    }
}
