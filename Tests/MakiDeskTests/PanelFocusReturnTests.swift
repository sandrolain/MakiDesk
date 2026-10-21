import XCTest
@testable import MakiDesk

@MainActor
final class PanelFocusReturnTests: XCTestCase {
    func testEscapeReturnsFocusOnlyOnceEvenIfDismissalReenters() {
        var restored = 0
        let session = PanelFocusReturn(captureTarget: { { restored += 1 } },
                                      applicationIsActive: { true })
        session.capture()
        let action = session.takeRestoreAction(ownsKeyboard: true)
        // orderOut can synchronously trigger a second hide through resign-key.
        XCTAssertNil(session.takeRestoreAction(ownsKeyboard: false))
        action?()
        XCTAssertEqual(restored, 1)
        XCTAssertNil(session.takeRestoreAction(ownsKeyboard: true))
    }

    func testDismissalAfterChoosingAnotherWindowDoesNotStealFocus() {
        var restored = false
        let session = PanelFocusReturn(captureTarget: { { restored = true } },
                                      applicationIsActive: { true })
        session.capture()
        session.takeRestoreAction(ownsKeyboard: false)?()
        XCTAssertFalse(restored)
        XCTAssertNil(session.takeRestoreAction(ownsKeyboard: true))
    }

    func testInactiveApplicationCannotRestoreAnOldTarget() {
        let session = PanelFocusReturn(captureTarget: { {} },
                                      applicationIsActive: { false })
        session.capture()
        XCTAssertNil(session.takeRestoreAction(ownsKeyboard: true))
    }

    func testNestedPanelsKeepIndependentReturnDestinations() {
        var destinations: [String] = []
        let notes = PanelFocusReturn(captureTarget: { { destinations.append("external") } },
                                    applicationIsActive: { true })
        let clipboard = PanelFocusReturn(captureTarget: { { destinations.append("notes") } },
                                        applicationIsActive: { true })
        notes.capture()
        clipboard.capture()
        clipboard.takeRestoreAction(ownsKeyboard: true)?()
        notes.takeRestoreAction(ownsKeyboard: true)?()
        XCTAssertEqual(destinations, ["notes", "external"])
    }

    func testNewPresentationReplacesTheOldReturnTarget() {
        var target = "first"
        var restored: String?
        let session = PanelFocusReturn(captureTarget: {
            let captured = target
            return { restored = captured }
        }, applicationIsActive: { true })
        session.capture()
        target = "second"
        session.capture()
        session.takeRestoreAction(ownsKeyboard: true)?()
        XCTAssertEqual(restored, "second")
    }
}
