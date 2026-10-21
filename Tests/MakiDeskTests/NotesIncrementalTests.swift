import XCTest
import SwiftTreeSitter
@testable import MakiDesk

final class NotesIncrementalTests: XCTestCase {
    private let styleKey = NSAttributedString.Key("testSyntax")

    private func captures(_ source: String) throws -> [NotesHighlightCapture] {
        let configuration = try XCTUnwrap(NotesGrammar.configuration(for: .swift))
        let query = try XCTUnwrap(configuration.queries[.highlights])
        let parser = Parser()
        try parser.setLanguage(configuration.language)
        let tree = try XCTUnwrap(parser.parse(source))
        return query.execute(in: tree).flatMap { match in
            match.captures.compactMap { capture in
                capture.name.map { NotesHighlightCapture(name: $0, range: capture.node.range) }
            }
        }
    }

    private func styled(_ source: String, captures: [NotesHighlightCapture]) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: source, attributes: [styleKey: "base"])
        for capture in captures { result.addAttribute(styleKey, value: capture.name, range: capture.range) }
        return result
    }

    func testIncrementalPatchesMatchFullStylingAcrossSyntaxAndUnicodeEdits() throws {
        let cases: [(String, String, String)] = [
            ("let x = 1\nlet y = 2\n", "1", "22"),
            ("let x = 1\nlet y = 2\n", "let x", "// let x"),
            ("/* one\n two */\nlet x = 1\n", "*/", ""),
            ("let icon = \"😀\"\n", "😀", "🧠"),
            ("let x = 1\n", "let ", ""),
            ("let x = 1\nlet y = 2\n", "let x = 1\n", ""),
            ("let x = \"hello\"\n", "hello", "hello\\\" world")
        ]
        for (before, needle, replacement) in cases {
            let edit = (before as NSString).range(of: needle)
            let after = (before as NSString).replacingCharacters(in: edit, with: replacement)
            let old = try captures(before)
            let new = try captures(after)
            let patched = styled(before, captures: old)
            patched.replaceCharacters(in: edit, with: replacement)
            let dirty = NotesHighlightDiff.changedRanges(oldSource: before, source: after, old: old, new: new)
            for range in dirty {
                patched.setAttributes([styleKey: "base"], range: range)
                for capture in new {
                    let intersection = NSIntersectionRange(capture.range, range)
                    if intersection.length > 0 { patched.addAttribute(styleKey, value: capture.name, range: intersection) }
                }
            }
            let expected = styled(after, captures: new)
            for index in 0..<expected.length {
                XCTAssertEqual(patched.attribute(styleKey, at: index, effectiveRange: nil) as? String,
                               expected.attribute(styleKey, at: index, effectiveRange: nil) as? String,
                               "edit \(needle) → \(replacement), offset \(index)")
            }
        }
    }

    func testInsertionDoesNotInvalidateUnchangedStyledSuffix() {
        let before = "let a = 1\nlet b = 2\n"
        let after = "//\n" + before
        let old = [NotesHighlightCapture(name: "keyword", range: NSRange(location: 0, length: 3)),
                   NotesHighlightCapture(name: "keyword", range: NSRange(location: 10, length: 3))]
        let new = old.map { NotesHighlightCapture(name: $0.name, range: NSRange(location: $0.range.location + 3, length: $0.range.length)) }
        let ranges = NotesHighlightDiff.changedRanges(oldSource: before, source: after, old: old, new: new)
        XCTAssertEqual(ranges, [NSRange(location: 0, length: 3)])
    }

    func testIncrementalLineIndexMatchesFullScanThroughRepeatedEdits() {
        var text = "one\ntwo\nthree\n"
        var starts = [0, 4, 8, 14]
        let insertions = ["a", "\n", "😀", "b\nc", "", "\r\n"]
        for step in 0..<200 {
            let boundaries = Array(text.indices) + [text.endIndex]
            let first = step * 7 % boundaries.count
            let last = min(boundaries.count - 1, first + step % 3)
            let edit = NSRange(boundaries[first]..<boundaries[last], in: text)
            let replacement = insertions[step % insertions.count]
            text = (text as NSString).replacingCharacters(in: edit, with: replacement)
            let updatedRange = NSRange(location: edit.location, length: (replacement as NSString).length)
            starts = NotesLineIndex.updating(starts, text: text as NSString, editedRange: updatedRange,
                                             delta: updatedRange.length - edit.length)
            let expected = [0] + text.utf16.enumerated().compactMap { $0.element == 10 ? $0.offset + 1 : nil }
            XCTAssertEqual(starts, expected, "edit \(step)")
        }
    }
}
