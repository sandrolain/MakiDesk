import XCTest
@testable import MakiDesk

final class ScreenshotSourcesTests: XCTestCase {
    func testMissingLocationFallsBackToDesktop() {
        let folder = SystemScreenshotFolder.folderURL(read: { _ in nil })
        XCTAssertEqual(folder.standardizedFileURL, SystemScreenshotFolder.desktopURL.standardizedFileURL)
    }

    func testEmptyLocationFallsBackToDesktop() {
        let folder = SystemScreenshotFolder.folderURL(read: { _ in "   " })
        XCTAssertEqual(folder.standardizedFileURL, SystemScreenshotFolder.desktopURL.standardizedFileURL)
    }

    func testAbsoluteLocationIsKeptAndStandardised() {
        let folder = SystemScreenshotFolder.folderURL(read: { _ in "/Users/example/Pictures/Screens/" })
        XCTAssertEqual(folder.path, "/Users/example/Pictures/Screens")
    }

    func testTildeLocationIsExpanded() {
        let folder = SystemScreenshotFolder.folderURL(read: { _ in "~/Pictures/Shots" })
        let expected = URL(fileURLWithPath: (NSString(string: "~/Pictures/Shots")).expandingTildeInPath,
                           isDirectory: true).standardizedFileURL
        XCTAssertEqual(folder, expected)
        XCTAssertTrue(folder.path.hasPrefix(NSHomeDirectory()))
    }

    func testKnownFileTypeIsLowercasedAndUnknownIsIgnored() {
        XCTAssertEqual(SystemScreenshotFolder.fileType(read: { _ in "PNG" }), "png")
        XCTAssertEqual(SystemScreenshotFolder.fileType(read: { _ in "jpeg" }), "jpeg")
        XCTAssertEqual(SystemScreenshotFolder.fileType(read: { _ in "tiff" }), "tiff")
        XCTAssertNil(SystemScreenshotFolder.fileType(read: { _ in "webp" }))
        XCTAssertNil(SystemScreenshotFolder.fileType(read: { _ in nil }))
        XCTAssertNil(SystemScreenshotFolder.fileType(read: { _ in 42 }))
    }
}
