import XCTest
@testable import MakiDesk

/// T15, the scene: which windows a recalled group puts away and how. Pure — no
/// accessibility, no windows — so the rules can be pinned down exactly: an app
/// with no member is hidden, an app holding a member only has its *other*
/// windows minimised, and anything the user had already put away is left alone.
final class WindowSceneTests: XCTestCase {
    private func candidate(
        _ id: String, _ pid: pid_t,
        minimized: Bool = false, appHidden: Bool = false,
        appHideable: Bool = true, onDisplay: Bool = true, unmanaged: Bool = false
    ) -> WindowScene.Candidate {
        WindowScene.Candidate(id: id, pid: pid, minimized: minimized, appHidden: appHidden,
                              appHideable: appHideable, onDisplay: onDisplay, unmanaged: unmanaged)
    }

    func testAnAppWithNoMemberIsHidden() {
        let windows = [candidate("member", 1), candidate("other", 2)]
        let plan = WindowScene.plan(windows: windows, members: ["member"])
        XCTAssertEqual(plan.hiddenApps, [2])
        XCTAssertTrue(plan.minimizedWindows.isEmpty)
        XCTAssertEqual(plan.count, 1)
    }

    func testAnAppHoldingAMemberOnlyHasItsOtherWindowsMinimised() {
        // Hiding the app would hide the member with it.
        let windows = [candidate("member", 1), candidate("sibling", 1)]
        let plan = WindowScene.plan(windows: windows, members: ["member"])
        XCTAssertTrue(plan.hiddenApps.isEmpty)
        XCTAssertEqual(plan.minimizedWindows, ["sibling"])
    }

    func testAnAppIsHiddenOnceHoweverManyWindowsItHas() {
        let windows = [candidate("member", 1), candidate("a", 2), candidate("b", 2), candidate("c", 2)]
        let plan = WindowScene.plan(windows: windows, members: ["member"])
        XCTAssertEqual(plan.hiddenApps, [2])
        XCTAssertEqual(plan.count, 1, "hiding an app counts once, not once per window")
    }

    func testAWindowTheUserHadMinimisedIsLeftAlone() {
        let windows = [candidate("member", 1), candidate("already", 2, minimized: true)]
        let plan = WindowScene.plan(windows: windows, members: ["member"])
        XCTAssertTrue(plan.isEmpty)
    }

    func testAnAlreadyHiddenAppIsLeftAlone() {
        let windows = [candidate("member", 1), candidate("other", 2, appHidden: true)]
        let plan = WindowScene.plan(windows: windows, members: ["member"])
        XCTAssertTrue(plan.isEmpty)
    }

    func testAWindowOfAnAppThatCannotBeHiddenIsMinimised() {
        let windows = [candidate("member", 1), candidate("other", 2, appHideable: false)]
        let plan = WindowScene.plan(windows: windows, members: ["member"])
        XCTAssertTrue(plan.hiddenApps.isEmpty)
        XCTAssertEqual(plan.minimizedWindows, ["other"])
    }

    func testMembersAreNeverTouchedEvenAsSiblings() {
        let windows = [candidate("a", 3), candidate("b", 3), candidate("c", 3)]
        let plan = WindowScene.plan(windows: windows, members: ["a", "c"])
        XCTAssertEqual(plan.minimizedWindows, ["b"])
        XCTAssertTrue(plan.hiddenApps.isEmpty)
    }

    func testASceneHoldingEveryWindowMovesNothing() {
        let windows = [candidate("a", 1), candidate("b", 2)]
        let plan = WindowScene.plan(windows: windows, members: ["a", "b"])
        XCTAssertTrue(plan.isEmpty)
    }

    func testAWindowOnAnotherDisplayIsLeftAlone() {
        // Scenes are per display: the other screen keeps what it has.
        let windows = [candidate("member", 1), candidate("other", 2, onDisplay: false)]
        let plan = WindowScene.plan(windows: windows, members: ["member"])
        XCTAssertTrue(plan.isEmpty)
    }

    func testAMemberOnAnotherDisplayStillKeepsItsAppVisible() {
        // The member is elsewhere, but hiding its app would take it away there.
        let windows = [candidate("member", 1, onDisplay: false), candidate("sibling", 1)]
        let plan = WindowScene.plan(windows: windows, members: ["member"])
        XCTAssertTrue(plan.hiddenApps.isEmpty)
        XCTAssertEqual(plan.minimizedWindows, ["sibling"])
    }

    func testTheOrderIsTheOrderTheWindowsWereFoundIn() {
        let windows = [candidate("a", 1), candidate("x", 4), candidate("y", 2), candidate("z", 4)]
        let plan = WindowScene.plan(windows: windows, members: ["a"])
        XCTAssertEqual(plan.hiddenApps, [4, 2], "each app once, in first-seen order")
    }

    // MARK: - Windows we may not touch (fullscreen)

    func testAWindowTheModeMayNotTouchIsNeverMinimised() {
        let windows = [candidate("member", 1), candidate("fullscreen", 2, unmanaged: true)]
        let plan = WindowScene.plan(windows: windows, members: ["member"])
        XCTAssertTrue(plan.minimizedWindows.isEmpty)
        XCTAssertTrue(plan.hiddenApps.isEmpty)
    }

    func testAnAppWithAVisibleWindowWeMayNotTouchIsNotHidden() {
        // Hiding it would take the fullscreen window with it.
        let windows = [candidate("member", 1),
                       candidate("fullscreen", 2, onDisplay: true, unmanaged: true),
                       candidate("sibling", 2)]
        let plan = WindowScene.plan(windows: windows, members: ["member"])
        XCTAssertTrue(plan.hiddenApps.isEmpty, "the app stays: it owns a window we cannot hide with it")
        XCTAssertEqual(plan.minimizedWindows, ["sibling"])
    }

    func testAnAppWeMayNotTouchCanStillBeHiddenWhenThatWindowIsAway() {
        // The fullscreen window is minimised, so nothing of the app is pinned on
        // screen and hiding it takes nothing away.
        let windows = [candidate("member", 1),
                       candidate("fullscreen", 2, minimized: true, unmanaged: true),
                       candidate("sibling", 2)]
        let plan = WindowScene.plan(windows: windows, members: ["member"])
        XCTAssertEqual(plan.hiddenApps, [2])
        XCTAssertTrue(plan.minimizedWindows.isEmpty)
    }

    func testAnUntouchableWindowOnAnotherDisplayPinsNothing() {
        let windows = [candidate("member", 1),
                       candidate("fullscreen", 2, onDisplay: false, unmanaged: true),
                       candidate("sibling", 2)]
        let plan = WindowScene.plan(windows: windows, members: ["member"])
        XCTAssertEqual(plan.hiddenApps, [2])
    }

    // MARK: - Reveal (bringing the members forward)

    func testAMemberWithAHiddenAppAsksForTheAppToBeShown() {
        let plan = WindowScene.revealPlan(members: [candidate("a", 1, appHidden: true)])
        XCTAssertEqual(plan.revealedApps, [1])
        XCTAssertTrue(plan.restoredWindows.isEmpty)
        XCTAssertTrue(plan.hasReveals)
    }

    func testAMemberInTheDockAsksToComeBack() {
        let plan = WindowScene.revealPlan(members: [candidate("member", 1, minimized: true)])
        XCTAssertEqual(plan.restoredWindows, ["member"])
        XCTAssertEqual(plan.revealedApps, [])
    }

    func testEachAppIsRevealedOnceHoweverManyMembersItHolds() {
        let members = [candidate("a", 1, appHidden: true), candidate("b", 1, minimized: true),
                       candidate("c", 1)]
        let plan = WindowScene.revealPlan(members: members)
        XCTAssertEqual(plan.revealedApps, [1])
        XCTAssertEqual(plan.restoredWindows, ["b"])
    }

    func testAMemberAlreadyOnScreenAsksForNothing() {
        let plan = WindowScene.revealPlan(members: [candidate("member", 1)])
        XCTAssertTrue(plan.revealedApps.isEmpty)
        XCTAssertTrue(plan.restoredWindows.isEmpty)
        XCTAssertTrue(plan.isEmpty)
    }

    func testRevealingLooksOnlyAtMembers() {
        // The planner is handed members only; a window the user hid themselves
        // is none of a recall's business.
        let plan = WindowScene.revealPlan(members: [candidate("member", 1)])
        XCTAssertTrue(plan.isEmpty)
    }
}
