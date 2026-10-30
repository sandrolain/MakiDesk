import XCTest
@testable import MakiDesk

/// T65: the Markdown commands are plain string work, so they are checked here
/// without a text view. Every command must be one change that the editor applies
/// as a single undoable edit.
final class NotesMarkdownFormatTests: XCTestCase {
    private func result(_ change: NotesMarkdownChange?, _ text: String) -> String? {
        guard let change else { return nil }
        return (text as NSString).replacingCharacters(in: change.range,
                                                      with: change.replacement)
    }

    private func selection(_ location: Int, _ length: Int) -> NSRange {
        NSRange(location: location, length: length)
    }

    // MARK: - Styles

    func testBoldWrapsTheSelectionAndTogglesItBack() {
        let text = "hello world"
        let bold = NotesMarkdownFormat.bold(in: text, selection: selection(0, 5))
        XCTAssertEqual(result(bold, text), "**hello** world")
        XCTAssertEqual(bold?.selection, selection(2, 5))

        let plain = NotesMarkdownFormat.bold(in: "**hello** world", selection: selection(2, 5))
        XCTAssertEqual(result(plain, "**hello** world"), "hello world")
        XCTAssertEqual(plain?.selection, selection(0, 5))
    }

    func testAStyleOnTheWordUnderTheCaret() {
        let text = "hello"
        let bold = NotesMarkdownFormat.bold(in: text, selection: selection(2, 0))
        XCTAssertEqual(result(bold, text), "**hello**")
        XCTAssertEqual(bold?.range, selection(0, 5))
    }

    func testAStyleOnWhitespaceLeavesACaretBetweenTheMarkers() {
        let text = "ab "
        let bold = NotesMarkdownFormat.bold(in: text, selection: selection(3, 0))
        XCTAssertEqual(result(bold, text), "ab ****")
        XCTAssertEqual(bold?.selection, selection(5, 0))
    }

    func testAStyleAroundAnEmojiDoesNotSplitTheSurrogates() {
        let text = "hi 👋 there"
        let start = (text as NSString).range(of: "there").location
        let bold = NotesMarkdownFormat.bold(in: text, selection: selection(start, 5))
        XCTAssertEqual(result(bold, text), "hi 👋 **there**")
    }

    func testItalicInsideBoldBecomesBoth() {
        let text = "**bold**"
        let italic = NotesMarkdownFormat.italic(in: text, selection: selection(2, 4))
        XCTAssertEqual(result(italic, text), "***bold***")
    }

    func testItalicUnwrapsItsOwnMarkersOnly() {
        let text = "*ital*"
        let plain = NotesMarkdownFormat.italic(in: text, selection: selection(1, 4))
        XCTAssertEqual(result(plain, text), "ital")
    }

    func testCodeToggles() {
        let text = "value"
        let code = NotesMarkdownFormat.code(in: text, selection: selection(0, 5))
        XCTAssertEqual(result(code, text), "`value`")
        let plain = NotesMarkdownFormat.code(in: "`value`", selection: selection(1, 5))
        XCTAssertEqual(result(plain, "`value`"), "value")
    }

    // MARK: - Link

    func testLinkWrapsTheSelectionAndSelectsTheURL() {
        let text = "text here"
        let link = NotesMarkdownFormat.link(in: text, selection: selection(0, 4))
        XCTAssertEqual(result(link, text), "[text](url) here")
        XCTAssertEqual(link?.selection, selection(7, 3))
    }

    func testLinkUnwrapsFromTheLabelOrTheURL() {
        let source = "[text](url) here"
        let fromLabel = NotesMarkdownFormat.link(in: source, selection: selection(1, 4))
        XCTAssertEqual(result(fromLabel, source), "text here")
        let fromURL = NotesMarkdownFormat.link(in: source, selection: selection(7, 3))
        XCTAssertEqual(result(fromURL, source), "text here")
    }

    // MARK: - Blocks

    func testBulletListTogglesOnAndOff() {
        let text = "a\nb\n"
        let list = NotesMarkdownFormat.toggleList(.bullet, in: text, selection: selection(0, 4))
        XCTAssertEqual(result(list, text), "- a\n- b\n")
        let plain = NotesMarkdownFormat.toggleList(.bullet, in: "- a\n- b\n",
                                                   selection: selection(0, 8))
        XCTAssertEqual(result(plain, "- a\n- b\n"), "a\nb\n")
    }

    func testNumberedListRenumbersAndReplacesABullet() {
        let text = "a\nb\nc\n"
        let numbered = NotesMarkdownFormat.toggleList(.numbered, in: text,
                                                      selection: selection(0, 6))
        XCTAssertEqual(result(numbered, text), "1. a\n2. b\n3. c\n")
        let fromBullets = NotesMarkdownFormat.toggleList(.numbered, in: "- a\n- b\n",
                                                         selection: selection(0, 8))
        XCTAssertEqual(result(fromBullets, "- a\n- b\n"), "1. a\n2. b\n")
        let back = NotesMarkdownFormat.toggleList(.numbered, in: "1. a\n2. b\n",
                                                  selection: selection(0, 10))
        XCTAssertEqual(result(back, "1. a\n2. b\n"), "a\nb\n")
    }

    func testCheckboxAndQuoteToggle() {
        let checkbox = NotesMarkdownFormat.toggleList(.checkbox, in: "task\n",
                                                      selection: selection(0, 5))
        XCTAssertEqual(result(checkbox, "task\n"), "- [ ] task\n")
        let quote = NotesMarkdownFormat.toggleQuote(in: "a\nb\n", selection: selection(0, 4))
        XCTAssertEqual(result(quote, "a\nb\n"), "> a\n> b\n")
        let plain = NotesMarkdownFormat.toggleQuote(in: "> a\n> b\n", selection: selection(0, 8))
        XCTAssertEqual(result(plain, "> a\n> b\n"), "a\nb\n")
    }

    func testTheListMarkerGoesAfterTheIndent() {
        let text = "  a\n"
        let list = NotesMarkdownFormat.toggleList(.bullet, in: text, selection: selection(0, 4))
        XCTAssertEqual(result(list, text), "  - a\n")
    }

    func testIndentAndOutdentByTwoSpaces() {
        let text = "a\nb\n"
        let indented = NotesMarkdownFormat.indent(in: text, selection: selection(0, 4))
        XCTAssertEqual(result(indented, text), "  a\n  b\n")
        let outdented = NotesMarkdownFormat.indent(in: "    a\n",
                                                   selection: selection(0, 6), outdent: true)
        XCTAssertEqual(result(outdented, "    a\n"), "  a\n")
    }

    func testFenceWrapsWithTheLanguageAndUnwraps() {
        let text = "code\n"
        let fence = NotesMarkdownFormat.toggleFence(in: text, selection: selection(0, 5),
                                                    language: "swift")
        let wrapped = "```swift\ncode\n```\n"
        XCTAssertEqual(result(fence, text), wrapped)
        let again = NotesMarkdownFormat.toggleFence(
            in: wrapped, selection: NSRange(location: 0, length: (wrapped as NSString).length),
            language: "swift"
        )
        XCTAssertEqual(result(again, wrapped), "code\n")
    }

    func testFenceWithoutATrailingNewline() {
        let text = "code"
        let fence = NotesMarkdownFormat.toggleFence(in: text, selection: selection(0, 4),
                                                    language: "")
        XCTAssertEqual(result(fence, text), "```\ncode\n```")
    }

    // MARK: - Tables

    func testTableAlignsEveryColumn() {
        let text = "| a | bb |\n| ccc | d |\n"
        let table = NotesMarkdownFormat.table(in: text,
                                              selection: NSRange(location: 0,
                                                                 length: (text as NSString).length))
        XCTAssertEqual(result(table, text),
                       "| a   | bb  |\n| --- | --- |\n| ccc | d   |\n")
    }

    func testTableKeepsTheAlignmentOfAnExistingSeparator() {
        let text = "| a | b |\n| :-- | --: |\n| 1 | 2 |\n"
        let table = NotesMarkdownFormat.table(in: text,
                                              selection: NSRange(location: 0,
                                                                 length: (text as NSString).length))
        XCTAssertEqual(result(table, text),
                       "| a   | b   |\n| :-- | --: |\n| 1   | 2   |\n")
    }

    func testTableNeedsRowsWithPipes() {
        XCTAssertNil(NotesMarkdownFormat.table(in: "just words\n",
                                               selection: selection(0, 11)))
    }
}
