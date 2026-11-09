import CoreGraphics
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

    func testTheNewestOfFocusAndPointerChoosesTheDisplay() {
        let first: CGDirectDisplayID = 1
        let second: CGDirectDisplayID = 2
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(ActiveDisplaySelection.mostRecent(
            focusID: first, focusAt: start,
            mouseID: second, mouseAt: start.addingTimeInterval(1)), second)
        XCTAssertEqual(ActiveDisplaySelection.mostRecent(
            focusID: first, focusAt: start.addingTimeInterval(2),
            mouseID: second, mouseAt: start.addingTimeInterval(1)), first)
        XCTAssertEqual(ActiveDisplaySelection.mostRecent(
            focusID: nil, focusAt: .distantPast,
            mouseID: second, mouseAt: start), second)
        XCTAssertEqual(ActiveDisplaySelection.mostRecent(
            focusID: first, focusAt: start,
            mouseID: nil, mouseAt: .distantPast), first)
        XCTAssertNil(ActiveDisplaySelection.mostRecent(
            focusID: nil, focusAt: .distantPast,
            mouseID: nil, mouseAt: .distantPast))
    }
}
