import AppKit
import XCTest
@testable import MakiDesk

/// A drag out of the shelf: what the destination is allowed to do with the
/// thing being dragged. Reported on 1 November 2026 — an annotated screenshot
/// vanished when dragged to the Finder — this is where it started.
@MainActor
final class ShelfDragTests: XCTestCase {
    private var directory: URL!
    private var file: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDeskShelfDrag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        file = nil
    }

    private func item(staged: Bool) -> ShelfItem {
        ShelfItem.file(file, staged: staged)
    }

    func testTheUsersOwnFileCanBeMovedOut() {
        XCTAssertEqual(ShelfController.dragOperations(for: [item(staged: false)]),
                       [.copy, .move])
    }

    /// A staged file is a copy the shelf made: the destination must not take it
    /// away, or a failed move leaves the screenshot nowhere.
    func testAScreenshotTheShelfProducedIsOnlyCopied() {
        XCTAssertEqual(ShelfController.dragOperations(for: [item(staged: true)]), .copy)
    }

    func testOneStagedFileMakesTheWholeDragCopyOnly() {
        XCTAssertEqual(ShelfController.dragOperations(for: [item(staged: false),
                                                            item(staged: true)]),
                       .copy)
    }

    func testTextLinksAndImagesStayCopyOnly() {
        let items = [ShelfItem.text("hello"), ShelfItem.link(URL(string: "https://x.dev")!)]
        XCTAssertEqual(ShelfController.dragOperations(for: items), .copy)
    }

    func testAnEmptyDragIsCopyOnly() {
        XCTAssertEqual(ShelfController.dragOperations(for: []), .copy)
    }
}
