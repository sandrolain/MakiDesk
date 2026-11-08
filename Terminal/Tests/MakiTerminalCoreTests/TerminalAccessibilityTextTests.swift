import XCTest
@testable import MakiTerminalCore

final class TerminalAccessibilityTextTests: XCTestCase {
    func testASnapshotAnswersBurstsUntilItExpires() {
        let text = TerminalAccessibilityText()
        var reads = 0
        let read: () -> String? = {
            reads += 1
            return "screen \(reads)"
        }
        XCTAssertEqual(text.value(now: 100, read: read), "screen 1")
        XCTAssertEqual(text.value(now: 100.2, read: read), "screen 1")
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(text.value(now: 101, read: read), "screen 2")
        XCTAssertEqual(reads, 2)
    }

    func testInvalidatingForcesAFreshRead() {
        let text = TerminalAccessibilityText()
        var reads = 0
        let read: () -> String? = {
            reads += 1
            return "v\(reads)"
        }
        _ = text.value(now: 10, read: read)
        text.invalidate()
        XCTAssertEqual(text.value(now: 10.1, read: read), "v2")
    }

    func testAnAppendedPhraseBecomesOnlyThePhrase() {
        let screen = "user@example ~/src % "
        XCTAssertEqual(
            TerminalAccessibilityText.insertedText(settingValue: screen + "make test",
                                                   over: screen),
            "make test"
        )
    }

    func testAPrependedPhraseBecomesOnlyThePhrase() {
        let screen = "prompt % "
        XCTAssertEqual(
            TerminalAccessibilityText.insertedText(settingValue: "echo " + screen, over: screen),
            "echo "
        )
    }

    func testAnInsertionInsideALongScreenIsFound() {
        let screen = String(repeating: "a", count: 80) + "middle" + String(repeating: "b", count: 80)
        let changed = String(repeating: "a", count: 80) + "INSERTmiddle" + String(repeating: "b", count: 80)
        XCTAssertEqual(
            TerminalAccessibilityText.insertedText(settingValue: changed, over: screen),
            "INSERT"
        )
    }

    func testASelectionReplacementNeedsALongScreen() {
        let long = String(repeating: "x", count: 100)
        let replaced = String(repeating: "x", count: 40) + "NEW" + String(repeating: "x", count: 40)
        XCTAssertEqual(
            TerminalAccessibilityText.insertedText(settingValue: replaced, over: long),
            "NEW"
        )
        let short = "abc"
        XCTAssertNil(TerminalAccessibilityText.insertedText(settingValue: "aXc", over: short))
    }

    func testTextThatIsNotAnEditIsTakenLiterally() {
        let text = TerminalAccessibilityText()
        _ = text.value { "a shell prompt" }
        XCTAssertEqual(text.insertedText(settingValue: "hello"), "hello")
    }

    func testAnEmptyScreenCannotBeDiffed() {
        XCTAssertNil(TerminalAccessibilityText.insertedText(settingValue: "hello", over: ""))
    }

    func testTheClassPrefersAValueTheClientActuallyRead() {
        let text = TerminalAccessibilityText()
        _ = text.value(now: 100) { "old screen" }
        _ = text.value(now: 100.1) { "not used" }
        XCTAssertEqual(
            text.insertedText(settingValue: "old screen dictation", now: 101),
            " dictation"
        )
    }

    func testStaleValuesAreForgotten() {
        let text = TerminalAccessibilityText()
        _ = text.value(now: 100) { "old screen" }
        XCTAssertEqual(
            text.insertedText(settingValue: "old screen dictation", now: 200),
            "old screen dictation"
        )
    }

    func testTrailingNewlinesBecomeReturns() {
        XCTAssertEqual(TerminalAccessibilityText.splitTrailingLineBreaks("ls\n").breaks, 1)
        XCTAssertEqual(TerminalAccessibilityText.splitTrailingLineBreaks("ls\n").body, "ls")
        XCTAssertEqual(TerminalAccessibilityText.splitTrailingLineBreaks("ls\r\n").breaks, 1)
        XCTAssertEqual(TerminalAccessibilityText.splitTrailingLineBreaks("ls\r\n").body, "ls")
        XCTAssertEqual(TerminalAccessibilityText.splitTrailingLineBreaks("\n\n").breaks, 2)
        XCTAssertEqual(TerminalAccessibilityText.splitTrailingLineBreaks("\n\n").body, "")
        XCTAssertEqual(TerminalAccessibilityText.splitTrailingLineBreaks("a\nb").breaks, 0)
        XCTAssertEqual(TerminalAccessibilityText.splitTrailingLineBreaks("a\nb").body, "a\nb")
    }

    func testADetectedLineBreakUsesThePastePath() {
        XCTAssertTrue(TerminalAccessibilityText.containsLineBreak("a\nb"))
        XCTAssertTrue(TerminalAccessibilityText.containsLineBreak("a\rb"))
        XCTAssertFalse(TerminalAccessibilityText.containsLineBreak("one line"))
    }
}
