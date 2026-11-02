import XCTest
@testable import MakiDesk

/// Regression cover for the "send to note" overwrite: text must never reach an
/// editor whose note body has not been loaded yet.
final class NotesInsertionQueueTests: XCTestCase {
    func testInsertionIsAllowedOnlyWhenTheBodyIsInTheEditor() {
        XCTAssertTrue(NotesInsertionPolicy.canInsert(
            noteLoaded: true, loadFailed: false, isCurrent: true,
            editorVisible: true, writingToolsActive: false))

        XCTAssertFalse(NotesInsertionPolicy.canInsert(
            noteLoaded: false, loadFailed: false, isCurrent: true,
            editorVisible: true, writingToolsActive: false),
            "an unloaded body would be replaced by the placeholder editor")
        XCTAssertFalse(NotesInsertionPolicy.canInsert(
            noteLoaded: true, loadFailed: true, isCurrent: true,
            editorVisible: true, writingToolsActive: false))
        XCTAssertFalse(NotesInsertionPolicy.canInsert(
            noteLoaded: true, loadFailed: false, isCurrent: false,
            editorVisible: true, writingToolsActive: false))
        XCTAssertFalse(NotesInsertionPolicy.canInsert(
            noteLoaded: true, loadFailed: false, isCurrent: true,
            editorVisible: false, writingToolsActive: false))
        XCTAssertFalse(NotesInsertionPolicy.canInsert(
            noteLoaded: true, loadFailed: false, isCurrent: true,
            editorVisible: true, writingToolsActive: true))
    }

    func testTextWaitsForItsOwnNote() {
        var queue = NotesInsertionQueue()
        let first = UUID()
        let second = UUID()
        queue.enqueue("one", for: first)
        queue.enqueue("two", for: second)
        queue.enqueue("three", for: first)

        XCTAssertTrue(queue.hasPending(for: first))
        XCTAssertTrue(queue.hasPending(for: second))
        XCTAssertEqual(queue.take(for: first), ["one", "three"])
        XCTAssertFalse(queue.hasPending(for: first))
        XCTAssertTrue(queue.hasPending(for: second))
        XCTAssertEqual(queue.take(for: second), ["two"])
        XCTAssertTrue(queue.pending.isEmpty)
    }

    func testTakingANoteLeavesTheOthersAlone() {
        var queue = NotesInsertionQueue()
        let first = UUID()
        let second = UUID()
        queue.enqueue("kept", for: second)
        queue.enqueue("taken", for: first)
        _ = queue.take(for: first)
        XCTAssertEqual(queue.take(for: second), ["kept"])
        XCTAssertEqual(queue.take(for: first), [])
    }

    func testDiscardRemovesOnlyThatNote() {
        var queue = NotesInsertionQueue()
        let first = UUID()
        let second = UUID()
        queue.enqueue("first", for: first)
        queue.enqueue("second", for: second)
        queue.discard(for: first)
        XCTAssertFalse(queue.hasPending(for: first))
        XCTAssertTrue(queue.hasPending(for: second))
        XCTAssertEqual(queue.take(for: second), ["second"])
    }
}
