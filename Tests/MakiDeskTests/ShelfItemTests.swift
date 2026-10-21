import XCTest
@testable import MakiDesk

@MainActor
final class ShelfItemTests: XCTestCase {
    func testTextPreviewAndDetail() {
        let item = ShelfItem.text("   \nHello   world\nsecond line\n")
        XCTAssertEqual(item.name, "Hello world")
        XCTAssertTrue(item.detail.hasPrefix("4 lines"))
        XCTAssertTrue(item.detail.contains("characters"))
        XCTAssertNotNil(item.pasteboardWriter)
    }

    func testLinkShowsTheHost() {
        let item = ShelfItem.link(URL(string: "https://www.example.com/a/b")!)
        XCTAssertEqual(item.name, "example.com")
        XCTAssertEqual(item.detail, "https://www.example.com/a/b")
        XCTAssertEqual(item.fileURL, URL(string: "https://www.example.com/a/b"))
    }

    func testAFileThatDisappearsBecomesUnavailable() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-item-\(UUID().uuidString).txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let item = ShelfItem.file(url)
        XCTAssertTrue(item.isAvailable)
        XCTAssertEqual(item.name, url.lastPathComponent)
        XCTAssertTrue(item.detail.contains("byte") || item.detail.contains("B"))

        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(item.isAvailable)
    }

    func testAnImageItemUsesAThumbnailInsteadOfAnIcon() {
        let image = NSImage(size: NSSize(width: 80, height: 40))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 80, height: 40).fill()
        image.unlockFocus()

        let item = ShelfItem.image(image)
        XCTAssertEqual(item.icon.size, NSSize(width: 32, height: 32))
    }

    func testAnImageFileAlsoGetsAThumbnail() throws {
        let image = NSImage(size: NSSize(width: 60, height: 30))
        image.lockFocus()
        NSColor.green.setFill()
        NSRect(x: 0, y: 0, width: 60, height: 30).fill()
        image.unlockFocus()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-image-\(UUID().uuidString).png")
        try XCTUnwrap(image.shelfPNGData).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let item = ShelfItem.file(url)
        XCTAssertEqual(item.icon.size, NSSize(width: 32, height: 32))
    }

    func testImagesAndFilesHavePasteboardWriters() throws {
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        NSColor.red.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 10, height: 10)).fill()
        image.unlockFocus()
        XCTAssertNotNil(ShelfItem.image(image).pasteboardWriter)
    }

    func testImageDragPromisesRepresentationsAndProducesAValidPNGOnDemand() throws {
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill()
        image.unlockFocus()
        let writer = try XCTUnwrap(ShelfItem.image(image).pasteboardWriter as? ShelfImageWriter)
        XCTAssertEqual(writer.writableTypes(for: .general), [.png, .tiff])
        XCTAssertTrue(writer.writingOptions(forType: .png, pasteboard: .general).contains(.promised))
        let png = try XCTUnwrap(writer.pasteboardPropertyList(forType: .png) as? Data)
        XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertEqual(writer.pasteboardPropertyList(forType: .png) as? Data, png)
    }
}
