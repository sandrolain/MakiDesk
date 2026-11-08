import XCTest
@testable import MakiTerminalCore

final class TerminalRendererVisibilityTests: XCTestCase {
    private func visible(occlusion: Bool = false,
                         reported: Bool = true,
                         onScreen: Bool = true,
                         miniaturized: Bool = false,
                         activeSpace: Bool = true,
                         key: Bool = false) -> Bool {
        TerminalRendererVisibility.isVisible(occlusionVisible: occlusion,
                                             windowHasReportedVisible: reported,
                                             isVisible: onScreen,
                                             isMiniaturized: miniaturized,
                                             isOnActiveSpace: activeSpace,
                                             isKeyWindow: key)
    }

    func testAnOcclusionVisibleWindowRenders() {
        XCTAssertTrue(visible(occlusion: true))
    }

    func testAKeyWindowIsAlwaysVisible() {
        XCTAssertTrue(visible(reported: true, onScreen: false, key: true))
        XCTAssertTrue(visible(reported: false, onScreen: false, key: true))
    }

    func testAReportedHiddenWindowDoesNotRender() {
        XCTAssertFalse(visible(reported: true, onScreen: false))
        XCTAssertFalse(visible(reported: true, onScreen: true, miniaturized: true))
        XCTAssertFalse(visible(reported: true, onScreen: true, activeSpace: false))
    }

    func testAVirtualDisplayBeforeItsFirstVisibleReportIsTrusted() {
        XCTAssertTrue(visible(occlusion: false, reported: false, onScreen: true))
        XCTAssertFalse(visible(occlusion: false, reported: false, onScreen: false))
    }

    func testAMiniaturizedWindowWithoutAReportDoesNotRender() {
        XCTAssertFalse(visible(reported: false, onScreen: true, miniaturized: true))
    }
}
