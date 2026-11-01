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

    func testAFailedRecognitionSaysWhetherTheDetectorStarted() {
        XCTAssertEqual(HUDMessage.textFailed(reason: "x", detectorCouldNotStart: false).title,
                       "Text recognition failed")
        XCTAssertTrue(HUDMessage.textFailed(reason: "x", detectorCouldNotStart: true)
            .title.contains("could not start"))
        XCTAssertEqual(HUDMessage.textFailed(reason: "x", detectorCouldNotStart: false).kind,
                       .warning)
    }
}
