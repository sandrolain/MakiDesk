import XCTest
@testable import MakiDesk

final class PaletteScreenLocationTests: XCTestCase {
    private let displays = [
        CGRect(x: 0, y: 0, width: 1440, height: 900),
        CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        CGRect(x: 0, y: 900, width: 2560, height: 1440)
    ]

    func testFocusPreferenceKeepsFocusDisplayWhenMouseIsElsewhere() {
        XCTAssertEqual(PaletteScreenLocation.focusedWindow.screenIndex(
            frames: displays, focusedIndex: 0, mouse: CGPoint(x: -500, y: 300)), 0)
    }

    func testMousePreferenceSelectsExternalDisplayWithNegativeOrigin() {
        XCTAssertEqual(PaletteScreenLocation.mouse.screenIndex(
            frames: displays, focusedIndex: 0, mouse: CGPoint(x: -500, y: 300)), 1)
    }

    func testMousePreferenceSelectsDisplayAboveInternalScreen() {
        XCTAssertEqual(PaletteScreenLocation.mouse.screenIndex(
            frames: displays, focusedIndex: 1, mouse: CGPoint(x: 300, y: 1400)), 2)
    }

    func testPointerOutsideDisplaysFallsBackToFocusDisplay() {
        XCTAssertEqual(PaletteScreenLocation.mouse.screenIndex(
            frames: displays, focusedIndex: 1, mouse: CGPoint(x: 6000, y: 6000)), 1)
    }

    func testDisconnectedFocusDisplayFallsBackToAvailableDisplay() {
        let remaining = [displays[0]]
        for location in PaletteScreenLocation.allCases {
            XCTAssertEqual(location.screenIndex(frames: remaining, focusedIndex: 2,
                                                 mouse: CGPoint(x: -500, y: 300)), 0)
        }
    }

    func testNoConnectedDisplaysDoesNotReturnAnInvalidIndex() {
        for location in PaletteScreenLocation.allCases {
            XCTAssertNil(location.screenIndex(frames: [], focusedIndex: 0, mouse: .zero))
        }
    }
}
