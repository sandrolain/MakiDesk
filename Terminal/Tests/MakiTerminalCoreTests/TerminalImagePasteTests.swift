import XCTest
@testable import MakiTerminalCore

final class TerminalImagePasteTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    func testTheFileNameIsSortableAndIdentifiable() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let id = UUID(uuidString: "AB12CD34-0000-0000-0000-000000000000")!
        let name = TerminalImagePaste.fileName(date: date, identifier: id, timeZone: utc)
        XCTAssertEqual(name, "paste-20270115-080000-ab12cd34.png")
    }

    func testASpacedPathIsOneShellWord() {
        XCTAssertEqual(
            TerminalImagePaste.shellQuoted("/Users/me/Library/Application Support/x.png"),
            "'/Users/me/Library/Application Support/x.png'"
        )
    }

    func testASingleQuoteInTheNameSurvivesTheShell() {
        XCTAssertEqual(
            TerminalImagePaste.shellQuoted("/tmp/it's here.png"),
            "'/tmp/it'\\''s here.png'"
        )
    }

    func testTheTypedTextIsQuotedAndLeavesRoomForAnArgument() {
        XCTAssertEqual(
            TerminalImagePaste.text(for: "/tmp/a b.png"),
            "'/tmp/a b.png' "
        )
    }

    func testPruningKeepsTheNewestAndTheYoung() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let files = (0..<5).map { index in
            TerminalImagePaste.File(
                url: URL(fileURLWithPath: "/tmp/\(index).png"),
                modified: now.addingTimeInterval(TimeInterval(-index * 60))
            )
        }
        let removals = TerminalImagePaste.filesToRemove(files, now: now, keepNewest: 2)
        XCTAssertEqual(removals.map(\.lastPathComponent), ["2.png", "3.png", "4.png"])
    }

    func testAnOldFileGoesEvenWhenItIsTheOnlyOne() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = TerminalImagePaste.File(
            url: URL(fileURLWithPath: "/tmp/old.png"),
            modified: now.addingTimeInterval(-8 * 24 * 60 * 60)
        )
        let fresh = TerminalImagePaste.File(
            url: URL(fileURLWithPath: "/tmp/fresh.png"),
            modified: now
        )
        let removals = TerminalImagePaste.filesToRemove([old, fresh], now: now)
        XCTAssertEqual(removals, [old.url])
    }

    func testAnEmptyDirectoryHasNothingToPrune() {
        XCTAssertTrue(TerminalImagePaste.filesToRemove([], now: Date()).isEmpty)
    }

    func testPruningAMissingDirectoryDoesNothing() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        TerminalImagePaste.prune(in: missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testPruningDeletesOldFilesOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("old.png")
        let fresh = directory.appendingPathComponent("fresh.png")
        try Data([0]).write(to: old)
        try Data([0]).write(to: fresh)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: old.path
        )
        TerminalImagePaste.prune(in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }
}
