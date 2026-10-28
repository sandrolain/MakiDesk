import XCTest
@testable import MakiDesk

/// The Chromium special case around `AXEnhancedUserInterface`: which bundles
/// match, and when the attribute we disabled must be restored.
final class AXEnhancedUITests: XCTestCase {
    func testChromiumBundlesMatchExactlyAndByHelperPrefix() {
        for identifier in ["com.google.Chrome",
                           "com.google.Chrome.helper",
                           "com.microsoft.edgemac",
                           "com.microsoft.edgemac.WebKit.Networking",
                           "com.brave.Browser",
                           "company.thebrowser.Browser",
                           "company.thebrowser.dia"] {
            XCTAssertTrue(AXEnhancedUIController.isChromiumBundle(identifier), identifier)
        }
    }

    func testChannelBundlesFollowTheirFamily() {
        XCTAssertTrue(AXEnhancedUIController.isChromiumBundle("com.google.Chrome.canary"))
        XCTAssertTrue(AXEnhancedUIController.isChromiumBundle("com.brave.Browser.beta"))
        XCTAssertTrue(AXEnhancedUIController.isChromiumBundle("com.microsoft.edgemac.canary"))
        XCTAssertFalse(AXEnhancedUIController.isChromiumBundle("com.brave.BrowserX"))
        XCTAssertFalse(AXEnhancedUIController.isChromiumBundle(""))
    }

    func testOtherBundlesAndMissingIdentifiersDoNotMatch() {
        for identifier in ["com.apple.Safari",
                           "com.makidesk.app",
                           "org.mozilla.firefox",
                           "com.google.ChromeX"] {
            XCTAssertFalse(AXEnhancedUIController.isChromiumBundle(identifier), identifier)
        }
        XCTAssertFalse(AXEnhancedUIController.isChromiumBundle(nil))
    }

    func testRestoreDecision() {
        // Nothing was disabled, nothing to restore.
        XCTAssertFalse(AXEnhancedUIController.shouldRestoreEnhancedUI(
            wasEnabled: false, isChromium: false, assistiveTechnology: false))
        XCTAssertFalse(AXEnhancedUIController.shouldRestoreEnhancedUI(
            wasEnabled: false, isChromium: true, assistiveTechnology: true))

        // A normal app gets its attribute back.
        XCTAssertTrue(AXEnhancedUIController.shouldRestoreEnhancedUI(
            wasEnabled: true, isChromium: false, assistiveTechnology: false))

        // Chromium keeps it off, unless assistive technology needs it.
        XCTAssertFalse(AXEnhancedUIController.shouldRestoreEnhancedUI(
            wasEnabled: true, isChromium: true, assistiveTechnology: false))
        XCTAssertTrue(AXEnhancedUIController.shouldRestoreEnhancedUI(
            wasEnabled: true, isChromium: true, assistiveTechnology: true))
    }
}
