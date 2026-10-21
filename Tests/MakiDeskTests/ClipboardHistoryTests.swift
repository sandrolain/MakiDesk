import AppKit
import XCTest
@testable import MakiDesk

@MainActor
final class ClipboardHistoryTests: XCTestCase {
    private func makePasteboard() throws -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("makidesk-clipboard-\(UUID().uuidString)"))
        pasteboard.clearContents()
        guard pasteboard.setString("probe", forType: .string) else {
            throw XCTSkip("Named pasteboards are unavailable in this test environment")
        }
        return pasteboard
    }

    private func write(_ text: String, to pasteboard: NSPasteboard) throws {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw XCTSkip("Pasteboard write was unavailable in this test environment")
        }
    }

    func testCollectsNewestFirstAndDeduplicates() throws {
        let pasteboard = try makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10, secureInput: { false })
        history.poll()

        try write("first", to: pasteboard); history.poll()
        try write("second", to: pasteboard); history.poll()
        try write("first", to: pasteboard); history.poll()

        XCTAssertEqual(history.entries.map(\.text), ["first", "second"])
        XCTAssertEqual(history.count, 2)
    }

    func testKeepsOnlyTheNewestEntries() throws {
        let pasteboard = try makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 2, secureInput: { false })
        history.poll()

        for index in 1...4 {
            try write("text \(index)", to: pasteboard)
            history.poll()
        }

        XCTAssertEqual(history.entries.map(\.text), ["text 4", "text 3"])
    }

    func testConcealedCopiesAreIgnored() throws {
        let pasteboard = try makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10, secureInput: { false })
        history.poll()

        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pasteboard.clearContents()
        guard pasteboard.declareTypes([.string, concealed], owner: nil) > 0,
              pasteboard.setString("a password", forType: .string) else {
            throw XCTSkip("Pasteboard types could not be declared in this environment")
        }
        history.poll()

        XCTAssertTrue(history.entries.isEmpty)
    }

    func testSecureInputIsNeverRecorded() throws {
        let pasteboard = try makePasteboard()
        var secure = true
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10, secureInput: { secure })
        history.poll()

        try write("a password", to: pasteboard)
        history.poll()
        XCTAssertTrue(history.entries.isEmpty)

        // Turning secure input off does not reveal what was copied meanwhile.
        secure = false
        history.poll()
        XCTAssertTrue(history.entries.isEmpty)

        try write("a normal text", to: pasteboard)
        history.poll()
        XCTAssertEqual(history.entries.map(\.text), ["a normal text"])
    }

    func testOurOwnPasteIsNotRecordedAgain() throws {
        let pasteboard = try makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10, secureInput: { false })
        history.poll()

        try write("one", to: pasteboard); history.poll()
        XCTAssertEqual(history.count, 1)

        // Pasting writes the chosen text back to the pasteboard.
        try write("one", to: pasteboard)
        history.markPasteboardSeen()
        history.poll()
        XCTAssertEqual(history.count, 1)
    }

    func testPromoteMovesAnEntryBackToTheTop() throws {
        let pasteboard = try makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10, secureInput: { false })
        history.poll()
        try write("first", to: pasteboard); history.poll()
        try write("second", to: pasteboard); history.poll()

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

    func testClearEmptiesTheList() throws {
        let pasteboard = try makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10, secureInput: { false })
        history.poll()
        try write("something", to: pasteboard); history.poll()
        XCTAssertEqual(history.count, 1)

        history.clear()
        XCTAssertTrue(history.entries.isEmpty)
    }
}
