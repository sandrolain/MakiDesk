import AppKit
import XCTest
@testable import MakiDesk

@MainActor
final class ClipboardHistoryTests: XCTestCase {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("makidesk-clipboard-\(UUID().uuidString)"))
    }

    private func write(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func testCollectsNewestFirstAndDeduplicates() {
        let pasteboard = makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10, secureInput: { false })
        history.poll()

        write("first", to: pasteboard); history.poll()
        write("second", to: pasteboard); history.poll()
        write("first", to: pasteboard); history.poll()

        XCTAssertEqual(history.entries.map(\.text), ["first", "second"])
        XCTAssertEqual(history.count, 2)
    }

    func testKeepsOnlyTheNewestEntries() {
        let pasteboard = makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 2, secureInput: { false })
        history.poll()

        for index in 1...4 {
            write("text \(index)", to: pasteboard)
            history.poll()
        }

        XCTAssertEqual(history.entries.map(\.text), ["text 4", "text 3"])
    }

    func testConcealedCopiesAreIgnored() {
        let pasteboard = makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10, secureInput: { false })
        history.poll()

        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealed], owner: nil)
        pasteboard.setString("a password", forType: .string)
        history.poll()

        XCTAssertTrue(history.entries.isEmpty)
    }

    func testSecureInputIsNeverRecorded() {
        let pasteboard = makePasteboard()
        var secure = true
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10, secureInput: { secure })
        history.poll()

        write("a password", to: pasteboard)
        history.poll()
        XCTAssertTrue(history.entries.isEmpty)

        // Turning secure input off does not reveal what was copied meanwhile.
        secure = false
        history.poll()
        XCTAssertTrue(history.entries.isEmpty)

        write("a normal text", to: pasteboard)
        history.poll()
        XCTAssertEqual(history.entries.map(\.text), ["a normal text"])
    }

    func testOurOwnPasteIsNotRecordedAgain() {
        let pasteboard = makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10, secureInput: { false })
        history.poll()

        write("one", to: pasteboard); history.poll()
        XCTAssertEqual(history.count, 1)

        // Pasting writes the chosen text back to the pasteboard.
        write("one", to: pasteboard)
        history.markPasteboardSeen()
        history.poll()
        XCTAssertEqual(history.count, 1)
    }

    func testPromoteMovesAnEntryBackToTheTop() throws {
        let pasteboard = makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10, secureInput: { false })
        history.poll()
        write("first", to: pasteboard); history.poll()
        write("second", to: pasteboard); history.poll()

        let older = try XCTUnwrap(history.entries.last)
        history.promote(older)

        XCTAssertEqual(history.entries.map(\.text), ["first", "second"])
    }

    func testPreviewCollapsesLinesAndDetailCounts() {
        let entry = ClipboardEntry(id: UUID(), text: "   \nFirst   line\ttabs\nsecond line",
                                   date: Date())
        XCTAssertEqual(entry.preview, "First line tabs")
        XCTAssertTrue(entry.detail.hasPrefix("3 lines"))
        XCTAssertTrue(entry.detail.contains("characters"))

        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(ClipboardEntry(id: UUID(), text: long, date: Date()).preview.count, 121)
    }

    func testClearEmptiesTheList() {
        let pasteboard = makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10, secureInput: { false })
        history.poll()
        write("something", to: pasteboard); history.poll()
        XCTAssertEqual(history.count, 1)

        history.clear()
        XCTAssertTrue(history.entries.isEmpty)
    }
}
