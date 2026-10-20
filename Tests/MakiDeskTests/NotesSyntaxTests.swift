import XCTest
import SwiftTreeSitter
@testable import MakiDesk

final class NotesSyntaxTests: XCTestCase {
    /// Every grammar we ship must compile its highlight query **and** parse its
    /// own kind of text: the two failures look identical in the editor (no
    /// colour), so they are checked here instead of by eye.
    func testEveryGrammarParsesAndMatchesSomething() throws {
        let samples: [NotesLanguage: String] = [
            .swift: "let x = 1 // comment\n",
            .json: "{\"a\": 1}\n",
            .markdown: "# Title\n\n- item\n\n```swift\nlet x = 1\n```\n",
            .bash: "echo \"hi\"\n",
            .python: "def f():\n    return 1\n",
            .javascript: "const x = 1;\n",
            .typescript: "const x: number = 1;\n",
            .html: "<p class=\"a\">hi</p>\n",
            .css: "a { color: red; }\n",
        ]

        for language in NotesLanguage.allCases where language != .plain {
            let sample = try XCTUnwrap(samples[language], "no sample for \(language.label)")
            let configuration = try XCTUnwrap(NotesGrammar.configuration(for: language),
                                              "no configuration for \(language.label)")
            let query = try XCTUnwrap(configuration.queries[.highlights],
                                      "no highlight query for \(language.label)")
            let parser = Parser()
            XCTAssertNoThrow(try parser.setLanguage(configuration.language),
                             "\(language.label) parser rejected by tree-sitter")
            let tree = try XCTUnwrap(parser.parse(sample), "\(language.label) did not parse")
            let captures = query.execute(in: tree).flatMap { $0.captures }
            XCTAssertFalse(captures.isEmpty, "\(language.label) produced no captures")
        }
    }

    func testCaptureNamesGetAColour() {
        let theme = NotesSyntaxTheme(theme: PaletteTheme.all[0])
        for name in ["keyword", "string", "comment", "number", "function.method", "type",
                     "constant", "property", "operator", "text.title", "text.literal"] {
            XCTAssertNotNil(theme.color(forCapture: name), "\(name) has no colour")
        }
        XCTAssertNil(theme.color(forCapture: "unknown.capture"))
    }
}
