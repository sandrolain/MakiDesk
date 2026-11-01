import XCTest
@testable import MakiDesk

/// R04: the notices are values, so the sentences can be read in one place and
/// a test can walk them. Before this, three files wrote "A selection is already
/// open" three times.
final class HUDMessageTests: XCTestCase {
    func testEveryCataloguedMessageHasATitleAndASymbol() {
        XCTAssertFalse(HUDMessage.catalogue.isEmpty)
        for message in HUDMessage.catalogue {
            XCTAssertFalse(message.title.isEmpty, message.symbol)
            XCTAssertFalse(message.symbol.isEmpty, message.title)
        }
    }

    func testTheSharedSentencesAreWrittenOnce() {
        XCTAssertEqual(HUDMessage.selectionAlreadyOpen.title, "A selection is already open")
        XCTAssertEqual(HUDMessage.screenRecordingRequired.title,
                       "Screen Recording permission required")
        XCTAssertEqual(HUDMessage.screenRecordingRequired.detail,
                       "Grant it in Settings ▸ General, then try again.")
    }

    /// The severity is still the symbol's business unless a message chose one:
    /// that is what keeps R04 a refactoring instead of a redesign.
    func testTheSeverityStaysInferredUnlessItWasChosen() {
        XCTAssertNil(HUDMessage.selectionAlreadyOpen.kind)
        XCTAssertEqual(HUDKind.inferred(for: HUDMessage.selectionAlreadyOpen.symbol), .warning)

        XCTAssertEqual(HUDMessage.noWindowToCapture.kind, .warning)
        XCTAssertEqual(HUDMessage.screenshotSaved(onTheShelf: true).kind, .success)
        XCTAssertEqual(HUDMessage.screenshotSaved(onTheShelf: false).kind, .warning)
        XCTAssertEqual(HUDMessage.systemScreenshotSaved(named: "a.png").kind, .info)
    }

    func testTheTextTitleFollowsTheDestination() {
        func title(_ output: TextRecognitionOutput) -> String {
            HUDMessage.textCopied(size: "2 characters", preview: "", to: output).title
        }
        XCTAssertEqual(title(.pasteboard), "Text copied · 2 characters")
        XCTAssertEqual(title(.pasteboardAndHistory), "Text copied · 2 characters · ⌥V keeps it")
        XCTAssertEqual(title(.historyOnly), "Text in clipboard history · 2 characters · ⌥V")
    }

    /// The preview travels as the detail: moving the title into the catalog
    /// must not drop what the call site used to pass alongside it.
    func testTheTextPreviewIsKept() {
        let message = HUDMessage.textCopied(size: "1 character", preview: "hello",
                                            to: .pasteboard)
        XCTAssertEqual(message.detail, "hello")
    }

    func testTheDropzoneFamilyAgreesOnTheName() {
        XCTAssertEqual(HUDMessage.dropzoneCancelled(name: "PDF").title, "PDF cancelled")
        XCTAssertEqual(HUDMessage.dropzoneTimedOut(name: "PDF").title, "PDF timed out")
        XCTAssertEqual(HUDMessage.dropzoneDone(name: "PDF").title, "PDF done")
        XCTAssertEqual(HUDMessage.dropzoneFailed(name: "PDF", reason: "").title, "PDF failed")
        XCTAssertEqual(HUDMessage.dropzoneFailed(name: "PDF", reason: "boom").title,
                       "PDF failed: boom")
    }

    func testPluralWordingFollowsTheCount() {
        XCTAssertEqual(HUDMessage.filesOnClipboard(count: 1).title, "1 file on the clipboard")
        XCTAssertEqual(HUDMessage.filesOnClipboard(count: 3).title, "3 files on the clipboard")
        XCTAssertEqual(HUDMessage.filesAddedToShelf(count: 1).title, "1 file added to the Shelf")
        XCTAssertEqual(HUDMessage.transferFinished(moved: false, count: 2).title, "Copied 2 items")
        XCTAssertEqual(HUDMessage.transferFinished(moved: true, count: 2).title, "Moved 2 items")
    }

    /// R04 is complete: no file spells a notice by hand any more. This is the
    /// whole invariant the catalog buys, in one assertion — a notice written
    /// inline again fails the suite instead of growing a second source.
    func testNoFileSpellsANoticeByHand() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MakiDesk")
        let files = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50)

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("HUDController.shared.show(\""),
                           "\(file.lastPathComponent) writes a notice by hand")
            XCTAssertFalse(text.contains("HUDController.shared.showProgress(\""),
                           "\(file.lastPathComponent) writes a progress notice by hand")
        }
    }

    func testTheWindowAndGroupNoticesAgree() {
        XCTAssertEqual(HUDMessage.noWindow.title, "No window")
        XCTAssertEqual(HUDMessage.nothingPutAway.title, "Nothing put away")
        XCTAssertEqual(HUDMessage.everythingBack.title, "Everything back")
        XCTAssertEqual(HUDMessage.windowNoLongerThere(title: "Notes").title,
                       "Notes — no window left")
        XCTAssertEqual(HUDMessage.peekReady(app: "Xcode", putAway: true).symbol, "eye.fill")
        XCTAssertEqual(HUDMessage.peekReady(app: "Xcode", putAway: false).symbol,
                       "exclamationmark.triangle.fill")
    }

    /// The catalog is where a half-translated sentence becomes visible: this
    /// notice said "Non più aperta" in an English interface.
    func testTheCatalogIsInOneLanguage() {
        for message in HUDMessage.catalogue {
            XCTAssertFalse(message.title.contains("Non più"), message.title)
        }
        XCTAssertEqual(HUDMessage.peekNoLongerOpen.title,
                       "No longer open — ⌃⌥⌘P drops the designation")
    }

    func testAFailedRecognitionSaysWhetherTheDetectorStarted() {
        XCTAssertEqual(HUDMessage.textFailed(reason: "x", detectorCouldNotStart: false).title,
                       "Text recognition failed")
        XCTAssertTrue(HUDMessage.textFailed(reason: "x", detectorCouldNotStart: true)
            .title.contains("could not start"))
        XCTAssertEqual(HUDMessage.textFailed(reason: "x", detectorCouldNotStart: false).kind,
                       .warning)
    }
}
