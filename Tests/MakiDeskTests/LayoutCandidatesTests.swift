import XCTest
import AppKit
@testable import MakiDesk

/// Who a layout command arranges, and what it says about the rest (T24), plus
/// the identity a window keeps between reads (T25). Both are pure rules, so they
/// are checked here rather than on a running desktop.
@MainActor
final class LayoutCandidatesTests: XCTestCase {

    // MARK: - Who is arranged

    func testAWindowInViewIsArranged() {
        XCTAssertEqual(
            WorkspaceStore.disposition(minimized: false, appHidden: false, fullScreen: false),
            .arrange)
    }

    func testAMinimisedWindowStaysAway() {
        XCTAssertEqual(
            WorkspaceStore.disposition(minimized: true, appHidden: false, fullScreen: false),
            .away)
    }

    func testAWindowOfAHiddenAppStaysAway() {
        XCTAssertEqual(
            WorkspaceStore.disposition(minimized: false, appHidden: true, fullScreen: false),
            .away)
    }

    func testAFullScreenWindowIsCalledOutButNotArranged() {
        XCTAssertEqual(
            WorkspaceStore.disposition(minimized: false, appHidden: false, fullScreen: true),
            .fullScreen)
    }

    /// A full-screen window of a hidden app is reported as away: it is not in
    /// view at all, so "full screen" would be a reason for the wrong thing.
    func testAwayWinsOverFullScreen() {
        XCTAssertEqual(
            WorkspaceStore.disposition(minimized: false, appHidden: true, fullScreen: true),
            .away)
        XCTAssertEqual(
            WorkspaceStore.disposition(minimized: true, appHidden: false, fullScreen: true),
            .away)
    }

    // MARK: - What the feedback says

    private func makeWindow(_ id: String, pid: pid_t = 0, minimized: Bool = false,
                            fullScreen: Bool = false, state: WindowState = .normal) -> ActionableWindow {
        ActionableWindow(id: id, title: id, appName: "Example", frame: .zero, pid: pid,
                         minimized: minimized, element: AXUIElementCreateSystemWide(), color: .black,
                         windowID: nil, icon: nil, state: state, fullScreen: fullScreen)
    }

    func testArrangeableSetSortsWindowsFromTheInventoryFlagsAlone() {
        let windows = [
            makeWindow("plain", pid: 1),
            makeWindow("full", pid: 2, fullScreen: true),
            makeWindow("minimized", pid: 3, minimized: true),
            makeWindow("hidden-app", pid: 4),
            makeWindow("gone", pid: 5, state: .unavailable),
        ]
        let set = WorkspaceStore.arrangeableSet(from: windows) { $0 == 4 }
        XCTAssertEqual(set.windows.map(\.id), ["plain"])
        XCTAssertEqual(set.fullScreen, 1)
        XCTAssertEqual(set.away, 2)
        XCTAssertEqual(set.unavailable, 1)
    }

    func testTheSummaryCountsTheWindowsItPlaced() {
        var set = WorkspaceStore.ArrangeableSet(windows: [makeWindow("a")])
        XCTAssertEqual(WorkspaceStore.layoutSummary(set), "1 window")
        set.windows.append(makeWindow("b"))
        XCTAssertEqual(WorkspaceStore.layoutSummary(set), "2 windows")
    }

    func testTheSummarySaysWhyThereWereNotMore() {
        var set = WorkspaceStore.ArrangeableSet(windows: [makeWindow("a"), makeWindow("b")])
        set.fullScreen = 1
        set.away = 3
        XCTAssertEqual(WorkspaceStore.layoutSummary(set), "2 windows · 1 full screen · 3 away")
    }

    func testASetWithNothingToArrangeSaysSoRatherThanLyingAboutReasons() {
        var set = WorkspaceStore.ArrangeableSet()
        set.away = 2
        XCTAssertEqual(WorkspaceStore.layoutSummary(set), "0 windows · 2 away")
        XCTAssertTrue(set.isEmpty)
    }

    // MARK: - Which windows of a helper app count

    /// A helper app's settings or document window is a window: title, frame,
    /// window subrole, normal level.
    func testARealWindowOfAMenuBarAgentIsListed() {
        XCTAssertTrue(WindowController.isAgentWindow(
            subrole: kAXStandardWindowSubrole as String, title: "Preferences",
            frame: CGRect(x: 0, y: 0, width: 600, height: 400), layer: 0))
    }

    /// Notification Center's panel runs above every app (level 21): it is not a
    /// window to switch to, however good its title and subrole look.
    func testAPanelThatFloatsAboveEveryAppIsNotListed() {
        XCTAssertFalse(WindowController.isAgentWindow(
            subrole: kAXStandardWindowSubrole as String, title: "Notification Center",
            frame: CGRect(x: 0, y: 0, width: 1710, height: 1107), layer: 21))
    }

    /// A widget on the desktop sits at the desktop-widget level, not at 0.
    func testADesktopWidgetOfANotificationCentreIsNotListed() {
        XCTAssertFalse(WindowController.isAgentWindow(
            subrole: kAXStandardWindowSubrole as String, title: "Prossimi eventi",
            frame: CGRect(x: 8, y: 47, width: 180, height: 180), layer: -2147483601))
    }

    /// No window level from the window server: not a window we can act on.
    func testAnUnknownLevelIsNotAWindow() {
        XCTAssertFalse(WindowController.isAgentWindow(
            subrole: kAXStandardWindowSubrole as String, title: "Something",
            frame: CGRect(x: 0, y: 0, width: 100, height: 100), layer: nil))
    }

    /// A widget or overlay reports no window subrole, whatever its title.
    func testAWidgetSubroleIsNotAWindow() {
        XCTAssertFalse(WindowController.isAgentWindow(
            subrole: "AXUnknown", title: "Dynamic Island",
            frame: CGRect(x: 0, y: 0, width: 185, height: 34), layer: 0))
        XCTAssertFalse(WindowController.isAgentWindow(
            subrole: nil, title: "MenuBarAgent",
            frame: CGRect(x: 0, y: 0, width: 1710, height: 34), layer: 0))
    }

    /// Without a title — or without a frame — there is nothing to list.
    func testANamelessOrFramelessAgentWindowIsNotListed() {
        XCTAssertFalse(WindowController.isAgentWindow(
            subrole: kAXStandardWindowSubrole as String, title: nil,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100), layer: 0))
        XCTAssertFalse(WindowController.isAgentWindow(
            subrole: kAXStandardWindowSubrole as String, title: "   ",
            frame: CGRect(x: 0, y: 0, width: 100, height: 100), layer: 0))
        XCTAssertFalse(WindowController.isAgentWindow(
            subrole: kAXStandardWindowSubrole as String, title: "No frame",
            frame: nil, layer: 0))
    }

    // MARK: - The pointer and the keyboard (T28)

    /// Entering a card with the mouse is a move: the pointer may choose.
    func testThePointerChoosesACardWhenItMoves() {
        XCTAssertTrue(WindowPalette.pointerMoved(from: CGPoint(x: 100, y: 100),
                                                 to: CGPoint(x: 140, y: 100)))
    }

    /// The card that scrolls under a still cursor is reported as hovered, but
    /// the pointer did not move, so it must not take the selection back from
    /// the keyboard.
    func testAStillPointerDoesNotTakeTheSelectionBack() {
        XCTAssertFalse(WindowPalette.pointerMoved(from: CGPoint(x: 100, y: 100),
                                                  to: CGPoint(x: 100, y: 100)))
    }

    /// A point of jitter (tracking noise, a 1 px nudge) is not a move either.
    func testAPointOfJitterIsNotAMove() {
        XCTAssertFalse(WindowPalette.pointerMoved(from: CGPoint(x: 100, y: 100),
                                                  to: CGPoint(x: 101, y: 100)))
        XCTAssertFalse(WindowPalette.pointerMoved(from: CGPoint(x: 100, y: 100),
                                                  to: CGPoint(x: 100, y: 101)))
    }

    // MARK: - The identity a window keeps

    /// The window number is the identity Core Graphics can name even while the
    /// window is in the Dock, and it does not move when a sibling window opens or
    /// closes — which the index does, and which is what made a window "change
    /// identity" between two reads (T25).
    func testTheWindowNumberIsPreferredOverTheAppIdentifier() {
        XCTAssertEqual(
            WindowController.stableID(pid: 42, identifier: "FinderWindow", windowNumber: 915, index: 3),
            "42-cg915")
    }

    func testASharedAppIdentifierIsNotAnIdentityWhenTheNumberIsUnknown() {
        XCTAssertEqual(
            WindowController.stableID(pid: 42, identifier: "FinderWindow", windowNumber: nil, index: 15),
            "42-FinderWindow")
    }

    func testTheIndexIsTheLastResort() {
        XCTAssertEqual(
            WindowController.stableID(pid: 42, identifier: nil, windowNumber: nil, index: 15),
            "42-idx15")
        XCTAssertEqual(
            WindowController.stableID(pid: 42, identifier: "", windowNumber: nil, index: 0),
            "42-idx0")
    }
}
