import AppKit
import XCTest
@testable import MakiDesk

/// R08: the modals are values now. Two of them existed twice — the dropzone
/// overwrite and the "run this command?" — in the settings window and in the
/// shelf, word for word.
@MainActor
final class ConfirmationTests: XCTestCase {
    func testTheOverwriteQuestionNamesTheZoneAndThePath() {
        let confirmation = Confirmation.dropzoneOverwrite(zone: "PDF", path: "/tmp/out.pdf")
        XCTAssertEqual(confirmation.title, "Replace an existing file?")
        XCTAssertTrue(confirmation.message.contains("“PDF”"))
        XCTAssertTrue(confirmation.message.contains("/tmp/out.pdf"))
        XCTAssertEqual(confirmation.confirm, "Run Anyway")
        XCTAssertEqual(confirmation.cancel, "Cancel")
        XCTAssertTrue(confirmation.isQuestion)
    }

    func testTheRunQuestionShowsTheCommand() {
        let confirmation = Confirmation.dropzoneRun(zone: "PDF", command: "sips -s format png")
        XCTAssertEqual(confirmation.title, "Run “PDF”?")
        XCTAssertTrue(confirmation.message.contains("sips -s format png"))
        XCTAssertTrue(confirmation.message.contains("trust"))
    }

    /// The phrase that matters: closing a draft is not deleting the file.
    func testClosingADraftSaysTheFileSurvives() {
        let confirmation = Confirmation.closeNote(title: "Notes", file: "todo.md")
        XCTAssertTrue(confirmation.message.contains("todo.md"))
        XCTAssertTrue(confirmation.message.contains("not deleted"))
        XCTAssertEqual(confirmation.confirm, "Close Note")
    }

    func testAStatementHasOneButton() {
        let confirmation = Confirmation.statement(title: "Done", message: "Nothing to do.")
        XCTAssertFalse(confirmation.isQuestion)
        XCTAssertNil(confirmation.cancel)
        XCTAssertEqual(confirmation.makeAlert().buttons.count, 1)
    }

    func testTheRenamePromptKeepsItsFallbackText() {
        let confirmation = Confirmation.rename(slot: 3, current: "Group 3")
        XCTAssertEqual(confirmation.title, "Rename Group 3")
        XCTAssertTrue(confirmation.message.contains("“Group 3”"))
        XCTAssertEqual(confirmation.makeAlert().buttons.count, 2)
    }

    func testEveryConfirmationSaysSomething() {
        let all = [
            Confirmation.dropzoneOverwrite(zone: "Z", path: "/p"),
            Confirmation.dropzoneRun(zone: "Z", command: "ls"),
            Confirmation.closeNote(title: "T", file: "f.md"),
            Confirmation.rename(slot: 1, current: "Group 1"),
            Confirmation.statement(title: "T", message: "M"),
        ]
        for confirmation in all {
            XCTAssertFalse(confirmation.title.isEmpty)
            XCTAssertFalse(confirmation.message.isEmpty)
            XCTAssertFalse(confirmation.confirm.isEmpty)
        }
    }

    /// The guard: a modal built by hand again would be a second place to keep
    /// the wording in step with the rest.
    func testNoFileBuildsAnAlertByHand() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MakiDesk")
        let files = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "Confirmation.swift" }

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("NSAlert()"),
                           "\(file.lastPathComponent) builds an alert by hand")
        }
    }
}
