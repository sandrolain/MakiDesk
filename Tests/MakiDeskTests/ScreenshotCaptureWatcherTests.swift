import XCTest
@testable import MakiDesk

/// T48: the notice for a capture macOS just saved is opt-in, silent while a
/// password is being typed, and only fires for a fresh image.
final class ScreenshotCaptureWatcherTests: XCTestCase {
    private func announce(enabled: Bool = true, secureInput: Bool = false,
                          isImage: Bool = true, age: TimeInterval = 1) -> Bool {
        ScreenshotCaptureWatcher.Policy.shouldAnnounce(enabled: enabled,
                                                       secureInput: secureInput,
                                                       isImage: isImage, age: age)
    }

    func testTheNoticeIsOffUntilAsked() {
        XCTAssertFalse(announce(enabled: false))
        XCTAssertTrue(announce(enabled: true))
    }

    func testNothingIsAnnouncedWhileAPasswordIsBeingTyped() {
        XCTAssertFalse(announce(secureInput: true))
    }

    func testOnlyAFreshImageCounts() {
        XCTAssertTrue(announce(age: 0))
        XCTAssertTrue(announce(age: ScreenshotCaptureWatcher.Policy.maximumAge))
        // An old file that the scan meets for the first time is not news.
        XCTAssertFalse(announce(age: ScreenshotCaptureWatcher.Policy.maximumAge + 1))
        // A modification date in the future is not news either.
        XCTAssertFalse(announce(age: -1))
        XCTAssertFalse(announce(isImage: false))
    }

    func testTheWatcherAndTheLibraryAgreeOnWhatACaptureIs() {
        XCTAssertTrue(ScreenshotNames.isCapture("Screenshot 2026-10-29 at 20.30.00.png"))
        XCTAssertTrue(ScreenshotNames.isCapture("Schermata 2026-10-29 alle 20.30.00.png"))
        XCTAssertTrue(ScreenshotNames.isCapture("Bildschirmfoto 2026-10-29 um 20.30.00.jpg"))
        XCTAssertTrue(ScreenshotNames.isCapture("Screenshot 2026-10-29 at 20.30.00.pdf"))
        // Other pictures and other files are not captures.
        XCTAssertFalse(ScreenshotNames.isCapture("IMG_2041.jpg"))
        XCTAssertFalse(ScreenshotNames.isCapture("notes about Screenshot.png"))
        XCTAssertFalse(ScreenshotNames.isCapture("Screenshot.txt"))
        // Recordings only when the library asks for them.
        XCTAssertFalse(ScreenshotNames.isCapture("Registrazione schermo 2026-10-29.mov"))
        XCTAssertTrue(ScreenshotNames.isCapture("Registrazione schermo 2026-10-29.mov",
                                                recordings: true))
        XCTAssertTrue(ScreenshotNames.isCapture("Screen Recording 2026-10-29.mov",
                                                recordings: true))
    }
}
