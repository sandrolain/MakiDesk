import CoreGraphics
import XCTest
@testable import MakiDesk

/// F2: when the bar opens and when it retreats, decided without a screen.
///
/// The pointer and the clock are values, so the awkward cases — a dwell, a
/// drag, a dismissal while the pointer is still in the trigger band — are
/// assertions rather than a manual inspection of a moving panel.
final class BarRevealTests: XCTestCase {
    /// A 1440 × 884 screen with a 24 pt menu bar, in AppKit coordinates: the
    /// desktop area is what remains below it.
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 884)
    private let area = CGRect(x: 0, y: 0, width: 1440, height: 860)
    private let height: CGFloat = 46
    private var zone: CGRect {
        BarReveal.zone(for: screen, desktop: area, minimum: 12)
    }

    /// A point in the menu bar, the band that starts the reveal.
    private var inZone: CGPoint { CGPoint(x: 700, y: screen.maxY - 12) }
    /// A point inside the open bar.
    private var insideBar: CGPoint { CGPoint(x: 700, y: area.maxY - 24) }
    /// A point far from the bar.
    private var outside: CGPoint { CGPoint(x: 700, y: area.midY) }

    private func show(_ reveal: inout BarReveal, at time: TimeInterval) -> BarReveal.Action {
        var action = BarReveal.Action.none
        for step in stride(from: 0.0, through: time, by: 0.05) {
            action = reveal.update(pointer: inZone, area: area, zone: zone,
                                   barHeight: height,
                                   pressed: false, suppressed: false, now: step)
        }
        return action
    }

    // MARK: - Geometry

    func testTheBarSitsJustUnderTheMenuBar() {
        let frame = BarReveal.barFrame(in: area, height: height)
        XCTAssertEqual(frame.minX, area.minX)
        XCTAssertEqual(frame.width, area.width)
        XCTAssertEqual(frame.maxY, area.maxY)
        XCTAssertEqual(frame.height, height)
        XCTAssertEqual(frame.minY, area.maxY - height)
    }

    func testTheMenuBarIsTheTriggerBand() {
        // The whole menu bar, not a thin strip under it: the pointer can be
        // flung to the top edge and still be inside the band.
        XCTAssertEqual(zone.minX, screen.minX)
        XCTAssertEqual(zone.width, screen.width)
        XCTAssertEqual(zone.maxY, screen.maxY)
        XCTAssertEqual(zone.height, screen.maxY - area.maxY)
        XCTAssertTrue(zone.contains(inZone))
        XCTAssertTrue(zone.contains(CGPoint(x: 700, y: screen.maxY - 1)))
        XCTAssertFalse(zone.contains(insideBar))
    }

    func testADisplayWithoutAMenuBarGetsAMinimumBand() {
        // A secondary display: visibleFrame reaches the top edge, so the band
        // falls back to the minimum instead of shrinking to nothing.
        let secondary = CGRect(x: -1920, y: -260, width: 1920, height: 1080)
        let band = BarReveal.zone(for: secondary, desktop: secondary, minimum: 12)
        XCTAssertEqual(band.maxY, secondary.maxY)
        XCTAssertEqual(band.height, 12)
        XCTAssertEqual(band.minX, secondary.minX)
        XCTAssertEqual(band.width, secondary.width)
    }

    func testANonPositiveHeightStaysAVisibleLine() {
        XCTAssertEqual(BarReveal.barFrame(in: area, height: 0).height, 1)
        XCTAssertEqual(BarReveal.barFrame(in: area, height: -10).height, 1)
        XCTAssertEqual(BarReveal.zone(for: screen, desktop: area, minimum: 0).height,
                       screen.maxY - area.maxY)
    }

    func testADisplayWithANegativeOriginKeepsIt() {
        // A secondary display to the left and below the main one.
        let secondary = CGRect(x: -1920, y: -260, width: 1920, height: 1080)
        let frame = BarReveal.barFrame(in: secondary, height: 46)
        XCTAssertEqual(frame.minX, -1920)
        XCTAssertEqual(frame.width, 1920)
        XCTAssertEqual(frame.maxY, secondary.maxY)
        XCTAssertEqual(frame.minY, secondary.maxY - 46)
    }

    // MARK: - Opening

    func testThePointerMustDwellInTheTriggerBand() {
        var reveal = BarReveal()
        XCTAssertEqual(reveal.update(pointer: inZone, area: area, zone: zone, barHeight: height,
                                     pressed: false, suppressed: false, now: 0), .none)
        XCTAssertEqual(reveal.update(pointer: inZone, area: area, zone: zone, barHeight: height,
                                     pressed: false, suppressed: false, now: 0.2), .none)
        XCTAssertFalse(reveal.isVisible)
        XCTAssertEqual(reveal.update(pointer: inZone, area: area, zone: zone, barHeight: height,
                                     pressed: false, suppressed: false, now: 0.25), .show)
        XCTAssertTrue(reveal.isVisible)
    }

    func testLeavingTheTriggerBandRestartsTheDwell() {
        var reveal = BarReveal()
        _ = reveal.update(pointer: inZone, area: area, zone: zone, barHeight: height,
                          pressed: false, suppressed: false, now: 0)
        _ = reveal.update(pointer: outside, area: area, zone: zone, barHeight: height,
                          pressed: false, suppressed: false, now: 0.1)
        XCTAssertEqual(reveal.update(pointer: inZone, area: area, zone: zone, barHeight: height,
                                     pressed: false, suppressed: false, now: 0.3), .none)
        XCTAssertEqual(reveal.update(pointer: inZone, area: area, zone: zone, barHeight: height,
                                     pressed: false, suppressed: false, now: 0.55), .show)
    }

    func testAMouseButtonHeldDownNeverOpensIt() {
        var reveal = BarReveal()
        _ = reveal.update(pointer: inZone, area: area, zone: zone, barHeight: height,
                          pressed: true, suppressed: false, now: 0)
        _ = reveal.update(pointer: inZone, area: area, zone: zone, barHeight: height,
                          pressed: true, suppressed: false, now: 1)
        XCTAssertFalse(reveal.isVisible)
        // The dwell starts once the button is released.
        XCTAssertEqual(reveal.update(pointer: inZone, area: area, zone: zone, barHeight: height,
                                     pressed: false, suppressed: false, now: 1.05), .none)
        XCTAssertEqual(reveal.update(pointer: inZone, area: area, zone: zone, barHeight: height,
                                     pressed: false, suppressed: false, now: 1.3), .show)
    }

    func testSuppressedMeansOff() {
        var reveal = BarReveal()
        XCTAssertEqual(show(&reveal, at: 0.3), .show)
        XCTAssertEqual(reveal.update(pointer: inZone, area: area, zone: zone, barHeight: height,
                                     pressed: false, suppressed: true, now: 0.4), .hide)
        XCTAssertFalse(reveal.isVisible)
        // Still suppressed: no dwell, no reveal.
        XCTAssertEqual(reveal.update(pointer: inZone, area: area, zone: zone, barHeight: height,
                                     pressed: false, suppressed: true, now: 2), .none)
        XCTAssertFalse(reveal.isVisible)
    }

    // MARK: - Closing

    func testItStaysWhileThePointerIsOnIt() {
        var reveal = BarReveal()
        _ = show(&reveal, at: 0.3)
        for time in stride(from: 0.35, through: 5.0, by: 0.1) {
            XCTAssertEqual(reveal.update(pointer: insideBar, area: area, zone: zone, barHeight: height,
                                         pressed: false, suppressed: false, now: time), .none)
        }
        XCTAssertTrue(reveal.isVisible)
    }

    func testRestingInTheMenuBarKeepsItOpen() {
        // The pointer stays where it started the reveal: the band counts as
        // "on the bar", so the user can decide before moving down onto it.
        var reveal = BarReveal()
        _ = show(&reveal, at: 0.3)
        for time in stride(from: 0.35, through: 5.0, by: 0.1) {
            XCTAssertEqual(reveal.update(pointer: inZone, area: area, zone: zone, barHeight: height,
                                         pressed: false, suppressed: false, now: time), .none)
        }
        XCTAssertTrue(reveal.isVisible)
    }

    func testItRetreatsAfterTheLinger() {
        var reveal = BarReveal()
        _ = show(&reveal, at: 0.3)
        XCTAssertEqual(reveal.update(pointer: outside, area: area, zone: zone, barHeight: height,
                                     pressed: false, suppressed: false, now: 0.5), .none)
        XCTAssertEqual(reveal.update(pointer: outside, area: area, zone: zone, barHeight: height,
                                     pressed: false, suppressed: false, now: 0.85), .none)
        XCTAssertEqual(reveal.update(pointer: outside, area: area, zone: zone, barHeight: height,
                                     pressed: false, suppressed: false, now: 0.9), .hide)
        XCTAssertFalse(reveal.isVisible)
    }

    func testAComeBackCancelsTheRetreat() {
        var reveal = BarReveal()
        _ = show(&reveal, at: 0.3)
        _ = reveal.update(pointer: outside, area: area, zone: zone, barHeight: height,
                          pressed: false, suppressed: false, now: 0.5)
        _ = reveal.update(pointer: insideBar, area: area, zone: zone, barHeight: height,
                          pressed: false, suppressed: false, now: 0.6)
        XCTAssertEqual(reveal.update(pointer: outside, area: area, zone: zone, barHeight: height,
                                     pressed: false, suppressed: false, now: 1.5), .none)
        XCTAssertTrue(reveal.isVisible)
    }

    func testAPinnedBarNeverRetreats() {
        var reveal = BarReveal()
        _ = show(&reveal, at: 0.3)
        reveal.setPinned(true)
        for time in stride(from: 0.4, through: 10.0, by: 0.5) {
            XCTAssertEqual(reveal.update(pointer: outside, area: area, zone: zone, barHeight: height,
                                         pressed: false, suppressed: false, now: time), .none)
        }
        XCTAssertTrue(reveal.isVisible)
    }

    func testAPinnedBarIgnoresAnOutsideClick() {
        var reveal = BarReveal()
        _ = show(&reveal, at: 0.3)
        XCTAssertTrue(reveal.closesOnOutsideClick)
        reveal.setPinned(true)
        XCTAssertFalse(reveal.closesOnOutsideClick)
        reveal.setPinned(false)
        XCTAssertTrue(reveal.closesOnOutsideClick)
    }

    func testADismissedBarWaitsForThePointerToLeave() {
        var reveal = BarReveal()
        _ = show(&reveal, at: 0.3)
        reveal.dismiss(pointer: inZone, area: area, zone: zone, barHeight: height)
        XCTAssertFalse(reveal.isVisible)
        // Still in the strip: nothing comes back, however long it stays.
        for time in stride(from: 0.4, through: 4.0, by: 0.2) {
            XCTAssertEqual(reveal.update(pointer: inZone, area: area, zone: zone, barHeight: height,
                                         pressed: false, suppressed: false, now: time), .none)
        }
        // Away, then back: the dwell starts over and the bar returns.
        _ = reveal.update(pointer: outside, area: area, zone: zone, barHeight: height,
                          pressed: false, suppressed: false, now: 4.1)
        _ = reveal.update(pointer: inZone, area: area, zone: zone, barHeight: height,
                          pressed: false, suppressed: false, now: 4.2)
        XCTAssertEqual(reveal.update(pointer: inZone, area: area, zone: zone, barHeight: height,
                                     pressed: false, suppressed: false, now: 4.45), .show)
    }

    func testACommandShowsItAndThenThePointerTakesOver() {
        var reveal = BarReveal()
        reveal.showNow()
        XCTAssertTrue(reveal.isVisible)
        // The pointer is elsewhere: an explicit show does not retreat.
        for time in stride(from: 0.0, through: 10.0, by: 1.0) {
            XCTAssertEqual(reveal.update(pointer: outside, area: area, zone: zone, barHeight: height,
                                         pressed: false, suppressed: false, now: time), .none)
        }
        XCTAssertTrue(reveal.isVisible)
        // Once the pointer has been on it, the ordinary linger applies.
        _ = reveal.update(pointer: insideBar, area: area, zone: zone, barHeight: height,
                          pressed: false, suppressed: false, now: 10.1)
        _ = reveal.update(pointer: outside, area: area, zone: zone, barHeight: height,
                          pressed: false, suppressed: false, now: 10.2)
        XCTAssertEqual(reveal.update(pointer: outside, area: area, zone: zone, barHeight: height,
                                     pressed: false, suppressed: false, now: 10.6), .hide)
    }

    func testResetForgetsEverything() {
        var reveal = BarReveal()
        _ = show(&reveal, at: 0.3)
        reveal.setPinned(true)
        reveal.dismiss(pointer: inZone, area: area, zone: zone, barHeight: height)
        reveal.reset()
        XCTAssertFalse(reveal.isVisible)
        // A screen change does not take the pin away.
        XCTAssertTrue(reveal.isPinned)
        // No exit is owed after a reset: the strip works again straight away.
        _ = reveal.update(pointer: inZone, area: area, zone: zone, barHeight: height,
                          pressed: false, suppressed: false, now: 1)
        XCTAssertEqual(reveal.update(pointer: inZone, area: area, zone: zone, barHeight: height,
                                     pressed: false, suppressed: false, now: 1.25), .show)
    }

    func testTheDefaultTimingsAreTheAgreedOnes() {
        let timings = BarReveal.Timings()
        XCTAssertEqual(timings.dwell, 0.25)
        XCTAssertEqual(timings.linger, 0.4)
        XCTAssertEqual(timings.zoneHeight, 12)
    }
}

/// F3: the info values are formatted once, without a view.
final class BarInfoTextTests: XCTestCase {
    func testDiskIsTheMenuBarText() {
        XCTAssertEqual(BarInfoText.disk("120 GB"), "120 GB")
        XCTAssertEqual(BarInfoText.disk(nil), "—")
        XCTAssertEqual(BarInfoText.disk(""), "—")
    }

    func testCPUIsRounded() {
        XCTAssertEqual(BarInfoText.cpu(0), "0%")
        XCTAssertEqual(BarInfoText.cpu(72.4), "72%")
        XCTAssertEqual(BarInfoText.cpu(72.6), "73%")
        XCTAssertEqual(BarInfoText.cpu(nil), "—")
        XCTAssertEqual(BarInfoText.cpu(.nan), "—")
        XCTAssertEqual(BarInfoText.cpu(.infinity), "—")
    }

    func testTheNearestRunningTimerWins() {
        let now = Date()
        let soon = AppTimer(label: "soon", origin: .countdown,
                            deadline: now.addingTimeInterval(30))
        let later = AppTimer(label: "later", origin: .countdown,
                             deadline: now.addingTimeInterval(90))
        XCTAssertEqual(BarInfoText.timer([later, soon], now: now), "0:30")
        XCTAssertEqual(BarInfoText.timer([later], now: now), "1:30")
    }

    func testDueAndPausedTimersAreNotCounted() {
        let now = Date()
        let due = AppTimer(label: "due", origin: .countdown,
                           deadline: now.addingTimeInterval(-1))
        let paused = AppTimer(label: "paused", origin: .countdown, deadline: nil,
                              pausedRemaining: 60)
        XCTAssertNil(BarInfoText.timer([due, paused], now: now))
        XCTAssertNil(BarInfoText.timer([], now: now))
    }

    func testTheWindowCountNeverGoesNegative() {
        XCTAssertEqual(BarInfoText.windows(0), "0")
        XCTAssertEqual(BarInfoText.windows(12), "12")
        XCTAssertEqual(BarInfoText.windows(-3), "0")
    }
}

/// F3: what fits in the strip, decided from the same widths the view uses.
final class BarLayoutTests: XCTestCase {
    private func item(_ id: String, _ priority: Int, _ width: CGFloat) -> BarLayoutItem {
        BarLayoutItem(id: id, priority: priority, width: width)
    }

    func testEverythingFits() {
        let plan = BarLayout.plan([item("a", 1, 50), item("b", 2, 50)], available: 120)
        XCTAssertEqual(plan.visible, ["a", "b"])
        XCTAssertTrue(plan.overflow.isEmpty)
    }

    func testTheLeastImportantGoesFirst() {
        let items = [item("a", 1, 50), item("b", 2, 50), item("c", 3, 50)]
        let plan = BarLayout.plan(items, available: 110)
        XCTAssertEqual(plan.visible, ["a", "b"])
        XCTAssertEqual(plan.overflow, ["c"])
        XCTAssertEqual(plan.overflow, plan.overflow.filter { items.map(\.id).contains($0) })
    }

    func testATieGoesToTheRightmost() {
        let items = [item("a", 1, 50), item("b", 1, 50)]
        let plan = BarLayout.plan(items, available: 60)
        XCTAssertEqual(plan.visible, ["a"])
        XCTAssertEqual(plan.overflow, ["b"])
    }

    func testTheOrderStaysTheDeclaredOne() {
        let items = [item("a", 3, 40), item("b", 1, 40), item("c", 2, 40)]
        let plan = BarLayout.plan(items, available: 90)
        XCTAssertEqual(plan.visible, ["b", "c"])
        XCTAssertEqual(plan.overflow, ["a"])
    }

    func testTheReserveIsNotAvailable() {
        let items = [item("a", 1, 60), item("b", 1, 60)]
        let plan = BarLayout.plan(items, available: 130, reserve: 40)
        XCTAssertEqual(plan.visible, ["a"])
        XCTAssertEqual(plan.overflow, ["b"])
    }

    func testOneControlAlwaysStays() {
        let plan = BarLayout.plan([item("only", 9, 500)], available: 10)
        XCTAssertEqual(plan.visible, ["only"])
        XCTAssertTrue(plan.overflow.isEmpty)
    }

    func testNothingToPlan() {
        let plan = BarLayout.plan([], available: 800)
        XCTAssertTrue(plan.visible.isEmpty)
        XCTAssertTrue(plan.overflow.isEmpty)
        XCTAssertTrue(plan.isEmpty)
    }

    func testNegativeRoomKeepsOneControl() {
        let items = [item("a", 1, 40), item("b", 2, 40)]
        let plan = BarLayout.plan(items, available: 0, reserve: 100)
        XCTAssertEqual(plan.visible, ["a"])
        XCTAssertEqual(plan.overflow, ["b"])
    }

    func testTheOverflowMenuOpensUnderTheBar() {
        let panel = CGRect(x: 0, y: 800, width: 900, height: 46)
        let anchor = BarLayout.menuAnchor(in: panel)
        XCTAssertEqual(anchor.x, panel.maxX - 10)
        XCTAssertEqual(anchor.y, panel.minY - 2)
        XCTAssertLessThan(anchor.y, panel.minY)
    }
}

/// F1: the bar's contents name existing commands, so the bar cannot grow a
/// second, subtly different menu.
final class BarItemCatalogTests: XCTestCase {
    func testIDsAreUnique() {
        let ids = BarItemCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testEveryItemIsInOneOfTheZones() {
        for item in BarItemCatalog.all {
            XCTAssertTrue(BarItem.Zone.allCases.contains(item.zone), item.id)
        }
        XCTAssertEqual(BarItemCatalog.all.count,
                       BarItemCatalog.utility.count + BarItemCatalog.toggles.count
                       + BarItemCatalog.info.count + BarItemCatalog.right.count)
    }

    func testPlannedLeavesOutTheRightHandControls() {
        let planned = Set(BarItemCatalog.planned.map(\.id))
        for item in BarItemCatalog.right {
            XCTAssertFalse(planned.contains(item.id), item.id)
        }
    }

    func testWidthsArePositiveAndGrowWithLabels() {
        for item in BarItemCatalog.all {
            XCTAssertGreaterThan(item.width(labels: false), 0, item.id)
            XCTAssertGreaterThanOrEqual(item.width(labels: true),
                                        item.width(labels: false), item.id)
        }
    }

    func testTheRightHandControlsAreAlwaysKept() {
        for item in BarItemCatalog.right {
            XCTAssertEqual(item.priority, 0, item.id)
        }
    }

    func testThePinIsTheOnlyStatefulControl() {
        XCTAssertEqual(BarItemCatalog.right.filter { $0.kind == .pin }.count, 1)
        XCTAssertEqual(BarItemCatalog.item(id: "pin")?.kind, .pin)
        XCTAssertNil(BarItemCatalog.item(id: "nope"))
    }

    func testUtilityCommandsAreRealShortcuts() {
        for item in BarItemCatalog.all {
            guard case let .shortcut(action) = item.kind else { continue }
            XCTAssertEqual(item.shortcutAction, action, item.id)
            XCTAssertFalse(CommandRouter.label(for: action).isEmpty, item.id)
        }
    }

    func testTheCatalogCarriesTheFourEverydayPanels() {
        let actions = BarItemCatalog.utility.compactMap(\.shortcutAction)
        XCTAssertTrue(actions.contains(.toggleNotes))
        XCTAssertTrue(actions.contains(.clipboardHistory))
        XCTAssertTrue(actions.contains(.toggleShelf))
        XCTAssertTrue(actions.contains(.newTimer))
    }

    func testTheBarOffersThePortsWindow() {
        guard let ports = BarItemCatalog.item(id: "ports") else {
            return XCTFail("missing the ports item")
        }
        XCTAssertEqual(ports.kind, .shortcut(.openPorts))
        XCTAssertEqual(ports.zone, .utility)
        XCTAssertEqual(ports.priority, 3)
        XCTAssertEqual(ports.symbol, "network")
    }

    func testTheInfoValuesCoverWhatTheMenuBarReads() {
        XCTAssertEqual(Set(BarItemCatalog.info.compactMap { item -> BarItem.Info? in
            guard case let .info(info) = item.kind else { return nil }
            return info
        }), Set(BarItem.Info.allCases))
    }

    func testTheTimerIsOneButtonWithItsCountdown() {
        let timers = BarItemCatalog.planned.filter { $0.title == "Timer" }
        XCTAssertEqual(timers.count, 1)
        XCTAssertEqual(timers.first?.kind, .shortcut(.newTimer))
    }

    func testThePinAndSettingsCannotBeHidden() {
        for item in BarItemCatalog.right {
            XCTAssertFalse(BarItemCatalog.hideable.contains { $0.id == item.id }, item.id)
        }
    }

    func testABadgeWidensTheEstimate() {
        guard let clipboard = BarItemCatalog.item(id: "clipboard") else {
            return XCTFail("missing the clipboard item")
        }
        XCTAssertEqual(clipboard.width(labels: false, badge: nil),
                       clipboard.width(labels: false))
        XCTAssertGreaterThan(clipboard.width(labels: false, badge: "12"),
                             clipboard.width(labels: false))
        XCTAssertGreaterThan(clipboard.width(labels: false, badge: "1234"),
                             clipboard.width(labels: false, badge: "1"))
    }

    func testLabelModesHaveTitles() {
        XCTAssertEqual(BarLabelMode.allCases, [.auto, .always, .never])
        for mode in BarLabelMode.allCases {
            XCTAssertFalse(mode.title.isEmpty)
        }
    }
}

/// F1: the bar is reachable from the keyboard and from the command box, with
/// names that agree with the settings section.
final class UtilityBarWiringTests: XCTestCase {
    func testTheBarHasItsOwnGeneralFamilyShortcut() {
        guard let row = ShortcutDefinitions.definition(id: "app.utilityBar") else {
            return XCTFail("missing app.utilityBar")
        }
        XCTAssertEqual(row.action, .toggleUtilityBar)
        XCTAssertTrue(row.isGlobal)
        XCTAssertEqual(row.family, .general)
        XCTAssertEqual(row.display, "⌃⌥B")
    }

    func testNoOtherRowClaimsTheSameKeys() {
        guard let wanted = ShortcutDefinitions.definition(id: "app.utilityBar") else {
            return XCTFail("missing app.utilityBar")
        }
        let clashes = ShortcutDefinitions.global.filter {
            $0.id != wanted.id && $0.keyCode == wanted.keyCode
                && $0.modifiers == wanted.modifiers
        }
        XCTAssertTrue(clashes.isEmpty, "\(clashes.map(\.id))")
    }

    func testTheDefaultsAreDeclared() {
        let name = "makidesk-utility-bar-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            return XCTFail("no defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: name) }
        Settings.registerDefaults(in: defaults)
        XCTAssertTrue(Settings.bool(.utilityBarEnabled, in: defaults))
        XCTAssertEqual(Settings.int(.utilityBarHeight, in: defaults), 46)
        XCTAssertEqual(Settings.string(.utilityBarLabels, in: defaults),
                       BarLabelMode.auto.rawValue)
        XCTAssertEqual(Settings.string(.utilityBarHiddenItems, in: defaults), "")
    }

    func testTheCommandBoxReachesItInWords() {
        XCTAssertEqual(CommandCatalog.match("utility bar")?.entry.action,
                       .shortcut(.toggleUtilityBar))
        XCTAssertEqual(CommandCatalog.match("bar pin")?.entry.action, .pinUtilityBar)
        XCTAssertEqual(CommandCatalog.match("bar show")?.entry.action, .showUtilityBar)
        XCTAssertEqual(CommandCatalog.match("bar hide")?.entry.action, .hideUtilityBar)
        XCTAssertEqual(CommandCatalog.match("bar")?.entry.action,
                       .shortcut(.toggleUtilityBar))
    }

    func testTheBarReachesOnlyExistingCommands() {
        // Every shortcut the bar can run is a case of the one enum, so the
        // dispatch in `applyShortcut` is the same one the menu and the keys use.
        for item in BarItemCatalog.all {
            guard let action = item.shortcutAction else { continue }
            XCTAssertEqual(item.kind, .shortcut(action), item.id)
        }
    }
}
