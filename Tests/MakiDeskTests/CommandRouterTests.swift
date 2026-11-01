import CoreGraphics
import XCTest
@testable import MakiDesk

/// R01: the dispatcher's questions, answered without a window. These were
/// private methods inside a 3.756-line class, reachable only by driving the
/// whole store — which is why a new command could land in `default` unnoticed.
final class CommandRouterTests: XCTestCase {
    private let area = CGRect(x: 0, y: 0, width: 1000, height: 800)

    // MARK: - Labo

    /// The label switch has no `default`, so a new case fails the build. What a
    /// test adds is that no label is empty or a placeholder.
    func testEveryLabelSaysSomething() {
        for action in Self.allActions {
            let label = CommandRouter.label(for: action)
            XCTAssertFalse(label.isEmpty, "\(action)")
            XCTAssertEqual(label, label.trimmingCharacters(in: .whitespaces), "\(action)")
        }
    }

    func testTheHalvesReadAsAPosition() {
        XCTAssertEqual(CommandRouter.label(for: .leftHalf), "left column")
        XCTAssertEqual(CommandRouter.label(for: .topRight), "top-right quarter")
        XCTAssertEqual(CommandRouter.label(for: .contentLayout), "content layout")
    }

    // MARK: - Ladder

    func testTheHalvesHaveAnAxisAndADirection() {
        XCTAssertEqual(CommandRouter.axisAndDirection(for: .leftHalf)?.0, .horizontal)
        XCTAssertEqual(CommandRouter.axisAndDirection(for: .leftHalf)?.1, -1)
        XCTAssertEqual(CommandRouter.axisAndDirection(for: .rightHalf)?.1, 1)
        XCTAssertEqual(CommandRouter.axisAndDirection(for: .topHalf)?.0, .vertical)
        XCTAssertEqual(CommandRouter.axisAndDirection(for: .topHalf)?.1, -1)
        XCTAssertEqual(CommandRouter.axisAndDirection(for: .bottomHalf)?.1, 1)
    }

    func testAQuarterIsNotALadderStep() {
        for action in [WindowController.ShortcutAction.topLeft, .topRight,
                       .bottomLeft, .bottomRight, .center, .phi, .centerCycle] {
            XCTAssertNil(CommandRouter.axisAndDirection(for: action), "\(action)")
        }
    }

    // MARK: - Frames

    func testTheQuartersAreTheQuarters() {
        let topLeft = CommandRouter.logicalFrame(for: .topLeft, area: area,
                                                 current: .zero)
        XCTAssertEqual(topLeft?.size, CGSize(width: 500, height: 400))
        XCTAssertEqual(topLeft?.origin, .zero)

        let bottomRight = CommandRouter.logicalFrame(for: .bottomRight, area: area,
                                                     current: .zero)
        XCTAssertEqual(bottomRight?.origin, CGPoint(x: 500, y: 400))
    }

    /// The halves are the ladder's business: answering here too would give the
    /// command two sources of geometry.
    func testTheHalvesHaveNoFrameOfTheirOwn() {
        for action in [WindowController.ShortcutAction.leftHalf, .rightHalf,
                       .topHalf, .bottomHalf] {
            XCTAssertNil(CommandRouter.logicalFrame(for: action, area: area, current: .zero))
        }
    }

    func testACentredWindowKeepsItsSizeWhenItFits() {
        let current = CGRect(x: 10, y: 10, width: 300, height: 200)
        let frame = CommandRouter.logicalFrame(for: .center, area: area, current: current)
        XCTAssertEqual(frame?.size, current.size)
        XCTAssertEqual(frame?.midX, area.midX)
        XCTAssertEqual(frame?.midY, area.midY)
    }

    func testACentredWindowShrinksToTheScreen() {
        let current = CGRect(x: 0, y: 0, width: 2000, height: 1600)
        let frame = CommandRouter.logicalFrame(for: .center, area: area, current: current)
        XCTAssertEqual(frame?.size, area.size)
    }

    func testTheGoldenFrameFitsInsideTheScreen() {
        let frame = CommandRouter.goldenFrame(area: area)
        XCTAssertEqual(frame.width / frame.height, TilingEngine.phi, accuracy: 0.01)
        XCTAssertLessThanOrEqual(frame.width, area.width)
        XCTAssertLessThanOrEqual(frame.height, area.height)
        XCTAssertEqual(frame.midX, area.midX)
        XCTAssertEqual(frame.midY, area.midY)
    }

    /// Ctrl-Opt-Return has two states, and which one you get depends on where
    /// the window already is.
    func testTheCycleAlternatesBetweenFullAndGolden() {
        let full = CommandRouter.logicalFrame(for: .centerCycle, area: area, current: area)
        XCTAssertEqual(full?.size.width ?? 0, area.width / TilingEngine.phi, accuracy: 0.5)

        let back = CommandRouter.logicalFrame(for: .centerCycle, area: area, current: full!)
        XCTAssertEqual(back?.size, area.size)
    }

    // MARK: - Tolerance

    /// AX rounds, and so do displays: two frames this close are one arrangement.
    func testFramesMatchWithinTwelvePoints() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertTrue(CommandRouter.framesMatch(a, a.offsetBy(dx: 11, dy: 0)))
        XCTAssertFalse(CommandRouter.framesMatch(a, a.offsetBy(dx: 13, dy: 0)))
        XCTAssertFalse(CommandRouter.framesMatch(a, CGRect(x: 0, y: 0, width: 120, height: 100)))
    }

    // MARK: - The list

    /// Every case of `ShortcutAction`, written out: the enum is not
    /// `CaseIterable`, and a list that silently stops covering it would defeat
    /// the point of the test above.
    private static let allActions: [WindowController.ShortcutAction] = [
        .leftHalf, .rightHalf, .topHalf, .bottomHalf,
        .topLeft, .topRight, .bottomLeft, .bottomRight,
        .centerCycle, .center, .phi, .toggleFullScreen, .minimize,
        .gridLayout, .spiralLayout, .suggestLayout, .contentLayout,
        .switchWindows, .switchWindowsBack, .searchWindows,
        .toggleNotes, .clipboardHistory, .toggleShelf,
        .recognizeText, .sampleColor, .measureArea,
        .openSettings, .openKeyboardShortcuts, .openScreenshots,
        .toggleFocusBorder, .toggleMiniMap, .toggleFocusDim, .toggleChecklist,
        .newTimer, .captureScreenshot, .captureWindow, .captureScreen, .recordArea,
        .runCommand, .focusSelection, .leaveGroup, .clearPeek, .applySuggestedLayout,
        .assignToGroup(1), .recallGroup(1), .peekDesignate,
        .putAwayFront, .showEverything, .undoStep,
    ]
}
