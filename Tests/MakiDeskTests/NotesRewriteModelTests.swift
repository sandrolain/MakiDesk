import XCTest
@testable import MakiDesk

/// T66: the model fills a structure and this code writes the Markdown. The
/// serializer and the prompt are pure, so they are checked without a model.
final class NotesRewriteModelTests: XCTestCase {
    func testImproveKeepsProseAndBulletsWithoutHeadings() {
        let draft = NotesRewriteDraft(sections: [
            .init(level: 1, heading: "Ignored", paragraphs: ["One."], bullets: ["a", "b"]),
            .init(paragraphs: ["Two."])
        ])
        XCTAssertEqual(NotesMarkdownSerializer.render(draft, action: .improve),
                       "One.\n\n- a\n- b\n\nTwo.\n")
    }

    func testFormatWritesTitleSectionsListsAndTables() {
        let draft = NotesRewriteDraft(
            title: "Plan",
            sections: [
                .init(level: 1, heading: "Steps", paragraphs: ["One."], bullets: ["a", "b"],
                      table: [["key", "value"], ["x", "1"]]),
                .init(level: 3, heading: "Notes", paragraphs: ["Two."])
            ]
        )
        XCTAssertEqual(NotesMarkdownSerializer.render(draft, action: .format), """
        # Plan

        ## Steps

        One.

        - a
        - b

        | key | value |
        | --- | ----- |
        | x   | 1     |

        #### Notes

        Two.

        """)
    }

    func testFormatWithoutATitleStartsAtTheTopLevel() {
        let draft = NotesRewriteDraft(sections: [.init(level: 1, heading: "Only", paragraphs: ["x"])])
        XCTAssertEqual(NotesMarkdownSerializer.render(draft, action: .format), "# Only\n\nx\n")
    }

    func testSummarizePrefersTheSummaryThenTheKeyPoints() {
        let draft = NotesRewriteDraft(
            summary: "Short.",
            sections: [.init(bullets: ["one", "two"]), .init(bullets: ["three"])]
        )
        XCTAssertEqual(NotesMarkdownSerializer.render(draft, action: .summarize),
                       "Short.\n\n- one\n- two\n- three\n")
    }

    func testSummarizeCapsThePointsAtEight() {
        let bullets = (1...12).map { "point \($0)" }
        let draft = NotesRewriteDraft(summary: "S", sections: [.init(bullets: bullets)])
        let text = NotesMarkdownSerializer.render(draft, action: .summarize)
        XCTAssertEqual(text.components(separatedBy: "\n- ").count - 1, 8)
    }

    func testAStrayBulletMarkerIsNotDoubled() {
        let draft = NotesRewriteDraft(sections: [.init(bullets: ["- already"])])
        XCTAssertEqual(NotesMarkdownSerializer.render(draft, action: .improve), "- already\n")
    }

    func testAnEmptyDraftRendersNothing() {
        XCTAssertEqual(NotesMarkdownSerializer.render(NotesRewriteDraft(), action: .format), "")
    }

    func testTablesPadRaggedRows() {
        let table = NotesMarkdownSerializer.table([["a", "bb"], ["ccc"]])
        XCTAssertEqual(table, "| a   | bb  |\n| --- | --- |\n| ccc |     |")
    }

    // MARK: - Prompt

    func testEveryActionSaysTheFieldsArePlainText() {
        for action in NotesRewriteAction.allCases {
            let instructions = NotesRewritePrompt.instructions(for: action)
            XCTAssertTrue(instructions.contains("Markdown"), action.rawValue)
            XCTAssertTrue(instructions.lowercased().contains("plain text"), action.rawValue)
        }
    }

    func testTheSourceIsTheSelectionWhenThereIsOne() {
        let text = "one two three"
        let selection = (text as NSString).range(of: "two")
        XCTAssertEqual(NotesRewritePrompt.source(text, selection: selection), "two")
    }

    func testALongNoteIsCutAtALineWithoutSplittingSurrogates() {
        let line = String(repeating: "a", count: 99) + "\n"
        let text = String(repeating: line, count: 100)
        let source = NotesRewritePrompt.source(text, selection: NSRange(location: 0, length: 0))
        XCTAssertLessThanOrEqual((source as NSString).length, NotesRewritePrompt.maximumCharacters)
        XCTAssertTrue(text.hasPrefix(source))
    }

    func testThePromptCarriesTheInstructionsAndTheNote() {
        let prompt = NotesRewritePrompt.prompt(for: .summarize, source: "the note")
        XCTAssertTrue(prompt.contains("summarise"))
        XCTAssertTrue(prompt.contains("the note"))
    }
}
