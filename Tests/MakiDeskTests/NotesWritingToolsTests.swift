import XCTest
@testable import MakiDesk

/// T64: Writing Tools must not rewrite code samples, so the fenced blocks of a
/// note are the ranges it has to leave alone. Pure scan, no AppKit.
final class NotesWritingToolsTests: XCTestCase {
    private func blocks(in text: String,
                        range: NSRange? = nil) -> [String] {
        let full = NSRange(location: 0, length: (text as NSString).length)
        let ns = text as NSString
        return NotesWritingTools.ignoredRanges(in: range ?? full, of: text)
            .map { ns.substring(with: $0) }
    }

    func testAFencedBlockIsIgnoredWithItsFences() {
        let text = "intro\n```swift\nlet x = 1\n```\nafter\n"
        let result = blocks(in: text)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].hasPrefix("```swift\n"), result[0])
        XCTAssertTrue(result[0].contains("let x = 1"))
        XCTAssertTrue(result[0].hasSuffix("```\n"), result[0])
    }

    func testATildeFenceCountsToo() {
        let text = "text\n~~~\nplain\n~~~\n"
        let result = blocks(in: text)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].contains("plain"))
    }

    func testAnUnclosedFenceRunsToTheEnd() {
        let text = "text\n```\nunfinished\nmore text\n"
        let result = blocks(in: text)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].hasSuffix("more text\n"), result[0])
    }

    func testFourSpacesDoNotOpenAFence() {
        let text = "text\n    ```\nnot a block\n"
        XCTAssertTrue(blocks(in: text).isEmpty)
    }

    func testInlineBackticksAreNotAFence() {
        let text = "use `code` and `more` here\n"
        XCTAssertTrue(blocks(in: text).isEmpty)
    }

    func testOnlyTheBlocksInsideTheRequestedRange() {
        let text = "```\none\n```\nmiddle\n```\ntwo\n```\n"
        let ns = text as NSString
        let inside = ns.range(of: "two")
        let result = blocks(in: text, range: inside)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].contains("two"))
        XCTAssertFalse(result[0].contains("one"))
    }

    func testAFenceInsideATildeBlockDoesNotCloseIt() {
        let text = "~~~\n```\nstill code\n~~~\n"
        let result = blocks(in: text)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].contains("still code"))
        XCTAssertTrue(result[0].hasSuffix("~~~\n"))
    }

    func testAShorterRunDoesNotCloseALongerFence() {
        let text = "````\n```\ncode\n````\n"
        let result = blocks(in: text)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].hasSuffix("````\n"), result[0])
    }
}
