import XCTest
@testable import MakiDesk

/// R05: one table renderer. The formatter and the serializer used to align
/// tables with two implementations that disagreed on how wide a cell is.
final class NotesMarkdownTableTests: XCTestCase {
    func testAHeaderSeparatorAndRows() {
        let table = NotesMarkdownTable.render(rows: [["Name", "Size"], ["a", "12"]])
        XCTAssertEqual(table, """
        | Name | Size |
        | ---- | ---- |
        | a    | 12   |
        """)
    }

    /// Three dashes is the shortest separator Markdown accepts, so a narrow
    /// column does not collapse to one.
    func testTheShortestSeparatorIsThreeDashes() {
        let table = NotesMarkdownTable.render(rows: [["a"], ["b"]])
        XCTAssertEqual(table, """
        | a   |
        | --- |
        | b   |
        """)
    }

    func testTheAlignmentRowSurvivesTheRewrite() {
        let table = NotesMarkdownTable.render(rows: [["Left", "Right", "Both"]],
                                              alignments: [":---", "---:", ":---:"])
        let separator = table?.split(separator: "\n").dropFirst().first.map(String.init)
        // Each marker carries its colons inside the column's width, so a
        // wider header makes a longer dash run, not a wider table.
        XCTAssertEqual(separator, "| :--- | ----: | :--: |")
    }

    func testARowWithFewerCellsIsPadded() {
        XCTAssertEqual(NotesMarkdownTable.render(rows: [["a", "b", "c"], ["1"]]), """
        | a   | b   | c   |
        | --- | --- | --- |
        | 1   |     |     |
        """)
    }

    /// UTF-16 units, the measure the formatter has always used: a table is
    /// source text, counted the way the editor's ranges are counted. This is
    /// the disagreement R05 removed — the serializer counted grapheme clusters.
    func testTheWidthIsMeasuredInUTF16Units() {
        XCTAssertEqual(NotesMarkdownTable.width(of: "abc"), 3)
        XCTAssertEqual(NotesMarkdownTable.width(of: "🏁"), 2)
        XCTAssertEqual(NotesMarkdownTable.width(of: "è"), 1)

        // Padded to the same UTF-16 width, whatever the glyphs cost.
        XCTAssertEqual((NotesMarkdownTable.padded("🏁", to: 5) as NSString).length, 5)
        XCTAssertEqual((NotesMarkdownTable.padded("b", to: 5) as NSString).length, 5)
    }

    func testNothingToRenderIsNil() {
        XCTAssertNil(NotesMarkdownTable.render(rows: []))
        XCTAssertNil(NotesMarkdownTable.render(rows: [[]]))
    }

    /// The point of the shared type: both callers lay out the same rows the
    /// same way. Only what goes *into* a cell may differ.
    func testTheTwoCallersAgreeOnLayout() throws {
        let rows = [["Nome", "Peso"], ["uno", "1"], ["due", "22"]]
        let expected = try XCTUnwrap(NotesMarkdownTable.render(rows: rows))

        XCTAssertEqual(NotesMarkdownSerializer.table(rows), expected)

        let text = "| Nome | Peso |\n| --- | --- |\n| uno | 1 |\n| due | 22 |\n"
        let change = try XCTUnwrap(
            NotesMarkdownFormat.table(in: text,
                                      selection: NSRange(location: 0, length: (text as NSString).length))
        )
        XCTAssertEqual(change.replacement, expected + "\n",
                       "the formatter keeps the newline the block ended with")
    }
}
