import XCTest
@testable import MakiDesk

/// S04: the shortcut table in the guide is generated, not copied, so it cannot
/// drift from the keys the app registers.
final class ShortcutTableDocumentTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MakiDeskTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // the repository
    }

    private var usageURL: URL {
        repositoryRoot.appendingPathComponent("docs/USAGE.md")
    }

    func testTheDocumentShowsTheGeneratedTable() throws {
        let text = try String(contentsOf: usageURL, encoding: .utf8)
        let block = try XCTUnwrap(ShortcutTableDocument.block(in: text),
                                  "docs/USAGE.md has no \(ShortcutTableDocument.beginMarker) block")
        XCTAssertEqual(block, ShortcutTableDocument.markdown(),
                       "the guide is behind the table: run `task docs:shortcuts`")
    }

    func testTheGeneratedBlockListsEveryRow() {
        let markdown = ShortcutTableDocument.markdown()
        for definition in ShortcutDefinitions.all {
            XCTAssertTrue(markdown.contains(definition.title), definition.id)
        }
        XCTAssertTrue(markdown.contains(ShortcutTableDocument.beginMarker))
        XCTAssertTrue(markdown.contains(ShortcutTableDocument.endMarker))
    }

    func testTheBlockIsFoundBetweenItsMarkers() {
        let text = """
        Some prose.

        \(ShortcutTableDocument.beginMarker)
        | a | b |
        \(ShortcutTableDocument.endMarker)

        More prose.
        """
        let block = ShortcutTableDocument.block(in: text)
        XCTAssertEqual(block?.hasPrefix(ShortcutTableDocument.beginMarker), true)
        XCTAssertEqual(block?.hasSuffix(ShortcutTableDocument.endMarker), true)
        XCTAssertEqual(block?.contains("| a | b |"), true)
    }

    func testAMissingBlockIsReportedInsteadOfOverwritingTheDocument() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDeskDoc-\(UUID().uuidString).md")
        try "no markers here".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try ShortcutTableDocument.rewrite(fileAt: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "no markers here")
    }

    func testARewriteIsIdempotent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDeskDoc-\(UUID().uuidString).md")
        let original = """
        Before.

        \(ShortcutTableDocument.beginMarker)
        stale
        \(ShortcutTableDocument.endMarker)

        After.
        """
        try original.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try ShortcutTableDocument.rewrite(fileAt: url)
        let once = try String(contentsOf: url, encoding: .utf8)
        try ShortcutTableDocument.rewrite(fileAt: url)
        let twice = try String(contentsOf: url, encoding: .utf8)

        XCTAssertEqual(once, twice)
        XCTAssertTrue(once.contains("Before."))
        XCTAssertTrue(once.contains("After."))
        XCTAssertTrue(once.contains(ShortcutTableDocument.markdown()))
    }
}
