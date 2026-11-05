import AppKit
import CoreGraphics
import XCTest
@testable import MakiDesk

/// E1–E3: the pointer effects' timing, display choice and settings are values,
/// so they are checked with points and times instead of a desktop.
final class PointerEffectTests: XCTestCase {
    private let suiteName = "MakiDeskPointerEffectTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        Settings.registerDefaults(in: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Pulse

    func testThePulseStopsAfterItsLastRing() {
        let pulse = PointerPulse(startedAt: 10, duration: 0.8)
        XCTAssertTrue(pulse.isActive(at: 10))
        XCTAssertTrue(pulse.isActive(at: 10.4))
        XCTAssertFalse(pulse.isActive(at: 9.9))
        XCTAssertEqual(pulse.visibleUntil,
                       10 + PointerPulse.stagger * 2 + 0.8,
                       accuracy: 0.0001)
        XCTAssertFalse(pulse.isActive(at: pulse.visibleUntil))
    }

    func testThePulseProgressIsClamped() {
        let pulse = PointerPulse(startedAt: 20, duration: 1)
        XCTAssertEqual(pulse.progress(at: 19), 0, accuracy: 0.0001)
        XCTAssertEqual(pulse.progress(at: 20.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(pulse.progress(at: 25), 1, accuracy: 0.0001)
    }

    func testTheRingsStartInOrderAndEndWithTheirOwnDuration() {
        let pulse = PointerPulse(startedAt: 0, duration: 1)
        XCTAssertEqual(pulse.ringPhase(index: 0, at: 0) ?? -1, 0, accuracy: 0.0001)
        XCTAssertNil(pulse.ringPhase(index: 1, at: 0.05),
                     "the second ring waits for the stagger")
        XCTAssertEqual(pulse.ringPhase(index: 1, at: 0.62) ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertNil(pulse.ringPhase(index: 0, at: 1.01))
        XCTAssertNil(pulse.ringPhase(index: 3, at: 0.1))
        XCTAssertNil(pulse.ringPhase(index: -1, at: 0.1))
    }

    func testAZeroDurationPulseEndsImmediatelyInsteadOfDividingByZero() {
        let pulse = PointerPulse(startedAt: 0, duration: 0)
        XCTAssertEqual(pulse.progress(at: 0), 1)
        XCTAssertFalse(pulse.isActive(at: 0.5),
                       "the stagger still keeps the surface for a moment")
    }

    // MARK: - Display and radius

    func testTheDisplayUnderThePointWins() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1000, height: 800),
            CGRect(x: -1200, y: 0, width: 1000, height: 800),
        ]
        XCTAssertEqual(PointerEffectGeometry.screenIndex(
            for: CGPoint(x: 500, y: 300), screens: screens), 0)
        XCTAssertEqual(PointerEffectGeometry.screenIndex(
            for: CGPoint(x: -700, y: 300), screens: screens), 1)
    }

    func testAPointerInTheGapChoosesTheNearestDisplay() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1000, height: 800),
            CGRect(x: -1200, y: 0, width: 1000, height: 800),
        ]
        // 50 pt from the left display, 150 pt from the right one.
        XCTAssertEqual(PointerEffectGeometry.screenIndex(
            for: CGPoint(x: -150, y: 300), screens: screens), 1)
        // Exactly between the two: the first display stays, deterministically.
        XCTAssertEqual(PointerEffectGeometry.screenIndex(
            for: CGPoint(x: -100, y: 300), screens: screens), 0)
        XCTAssertNil(PointerEffectGeometry.screenIndex(
            for: .zero, screens: []))
    }

    func testTheLocalPointKeepsNegativeDisplayOrigins() {
        let frame = CGRect(x: -1200, y: -200, width: 1000, height: 800)
        XCTAssertEqual(
            PointerEffectGeometry.localPoint(CGPoint(x: -700, y: 100), in: frame),
            CGPoint(x: 500, y: 300)
        )
    }

    func testTheRadiusShrinksBeforeItLeavesTheDisplay() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(PointerEffectGeometry.clampedRadius(
            44, at: CGPoint(x: 500, y: 400), in: frame), 44)
        XCTAssertEqual(PointerEffectGeometry.clampedRadius(
            44, at: CGPoint(x: 10, y: 400), in: frame), 8)
        XCTAssertEqual(PointerEffectGeometry.clampedRadius(
            44, at: CGPoint(x: 5, y: 5), in: frame), 4,
                       "a pointer in the corner still gets a visible minimum")
    }

    func testAFrameMatchesOnlyWhenOriginAndSizeAgree() {
        let frame = CGRect(x: -1200, y: 0, width: 1000, height: 800)
        XCTAssertTrue(PointerEffectGeometry.frameMatches(
            frame, CGRect(x: -1200, y: 0, width: 1000, height: 800)))
        XCTAssertFalse(PointerEffectGeometry.frameMatches(
            frame, CGRect(x: -1200, y: 0, width: 1000, height: 1000)))
        XCTAssertFalse(PointerEffectGeometry.frameMatches(
            frame, CGRect(x: 0, y: 0, width: 1000, height: 800)))
    }

    // MARK: - Follower

    func testTheFollowerMovesAFractionAndClampsItsFactor() {
        var follow = PointerFollow(CGPoint(x: 0, y: 0))
        XCTAssertEqual(follow.move(towards: CGPoint(x: 100, y: 0), factor: 0.5),
                       CGPoint(x: 50, y: 0))
        XCTAssertEqual(follow.move(towards: CGPoint(x: 100, y: 0), factor: 2),
                       CGPoint(x: 100, y: 0), "above 1 would overshoot")
        XCTAssertEqual(follow.move(towards: CGPoint(x: 0, y: 0), factor: -1),
                       CGPoint(x: 100, y: 0), "below 0 would freeze the ring")
        XCTAssertEqual(follow.distance(to: CGPoint(x: 100, y: 100)), 100,
                       accuracy: 0.001)
    }

    // MARK: - Settings

    func testTheSettingsComeFromTheRegisteredDefaults() {
        let settings = PointerEffectSettings.load(from: defaults)
        XCTAssertEqual(settings.style, .ring)
        XCTAssertEqual(settings.size, PointerEffectSettings.defaultSize)
        XCTAssertEqual(settings.intensity, PointerEffectSettings.defaultIntensity)
        XCTAssertEqual(settings.pulseDuration, PointerEffectSettings.defaultPulseDuration)
        XCTAssertEqual(settings.presentationMinutes,
                       PointerEffectSettings.defaultPresentationMinutes)
        XCTAssertTrue(settings.includesInCaptures)
        XCTAssertTrue(settings.clickRipple)
        XCTAssertEqual(settings, PointerEffectSettings.standard)
    }

    func testTheSettingsAreClampedOnTheWayIn() {
        defaults.set(1000.0, forKey: SettingsKey.pointerEffectSize.rawValue)
        defaults.set(5.0, forKey: SettingsKey.pointerEffectIntensity.rawValue)
        defaults.set(0.0, forKey: SettingsKey.pointerPulseDuration.rawValue)
        defaults.set(99, forKey: SettingsKey.pointerPresentationMinutes.rawValue)

        let high = PointerEffectSettings.load(from: defaults)
        XCTAssertEqual(high.size, PointerEffectSettings.sizeRange.upperBound)
        XCTAssertEqual(high.intensity, PointerEffectSettings.intensityRange.upperBound)
        XCTAssertEqual(high.pulseDuration, PointerEffectSettings.pulseDurationRange.lowerBound)
        XCTAssertEqual(high.presentationMinutes,
                       PointerEffectSettings.presentationMinutesRange.upperBound)

        defaults.set(0.0, forKey: SettingsKey.pointerEffectSize.rawValue)
        defaults.set(-3.0, forKey: SettingsKey.pointerEffectIntensity.rawValue)
        defaults.set(90.0, forKey: SettingsKey.pointerPulseDuration.rawValue)
        defaults.set(0, forKey: SettingsKey.pointerPresentationMinutes.rawValue)

        let low = PointerEffectSettings.load(from: defaults)
        XCTAssertEqual(low.size, PointerEffectSettings.sizeRange.lowerBound)
        XCTAssertEqual(low.intensity, PointerEffectSettings.intensityRange.lowerBound)
        XCTAssertEqual(low.pulseDuration, PointerEffectSettings.pulseDurationRange.upperBound)
        XCTAssertEqual(low.presentationMinutes,
                       PointerEffectSettings.presentationMinutesRange.lowerBound)
    }

    func testTheSwitchesAreOffOnlyWhenTheUserSaysSo() {
        defaults.set(false, forKey: SettingsKey.pointerEffectsInCaptures.rawValue)
        defaults.set(false, forKey: SettingsKey.pointerClickRipple.rawValue)
        let settings = PointerEffectSettings.load(from: defaults)
        XCTAssertFalse(settings.includesInCaptures)
        XCTAssertFalse(settings.clickRipple)
    }

    func testEveryPresentationStyleHasAStableLabelAndSummary() {
        XCTAssertEqual(PointerEffectStyle.allCases.map(\.rawValue),
                       ["ring", "ribbon", "particles", "orbit", "spotlight"])
        XCTAssertTrue(PointerEffectStyle.allCases.allSatisfy {
            $0.label.isEmpty == false && $0.summary.isEmpty == false
        })
        defaults.set(PointerEffectStyle.spotlight.rawValue,
                     forKey: SettingsKey.pointerEffectStyle.rawValue)
        XCTAssertEqual(PointerEffectSettings.load(from: defaults).style, .spotlight)
        defaults.set("unknown-style", forKey: SettingsKey.pointerEffectStyle.rawValue)
        XCTAssertEqual(PointerEffectSettings.load(from: defaults).style, .ring)
    }

    // MARK: - Ribbon trail

    func testTheTrailDeduplicatesCapsAndPrunesSamples() {
        var trail = PointerTrail()
        trail.append(CGPoint(x: 0, y: 0), at: 0)
        trail.append(CGPoint(x: 0.2, y: 0.2), at: 0.01)
        XCTAssertEqual(trail.samples.count, 1, "sub-pixel jitter is ignored")

        for index in 1...PointerTrail.maximumSamples + 4 {
            trail.append(CGPoint(x: CGFloat(index) * 2, y: 0), at: Double(index) / 60)
        }
        XCTAssertEqual(trail.samples.count, PointerTrail.maximumSamples)
        trail.prune(before: 0.3)
        XCTAssertTrue(trail.samples.allSatisfy { $0.time >= 0.3 })
    }

    func testTrailPathsAreBoundedToTheRecordedPoints() throws {
        var trail = PointerTrail()
        trail.append(CGPoint(x: 10, y: 10), at: 0)
        trail.append(CGPoint(x: 30, y: 20), at: 0.02)
        trail.append(CGPoint(x: 50, y: 10), at: 0.04)

        let ribbon = try XCTUnwrap(trail.ribbonPath(maxWidth: 12))
        let core = try XCTUnwrap(trail.corePath())
        XCTAssertGreaterThan(ribbon.boundingBoxOfPath.width, 39)
        XCTAssertGreaterThan(ribbon.boundingBoxOfPath.height, 9)
        XCTAssertEqual(core.boundingBoxOfPath, CGRect(x: 10, y: 10, width: 40, height: 10))
        XCTAssertNil(PointerTrail().ribbonPath(maxWidth: 12))
    }

    func testOutOfOrderTrailSamplesStartANewSegment() {
        var trail = PointerTrail()
        trail.append(CGPoint(x: 10, y: 10), at: 2)
        trail.append(CGPoint(x: 30, y: 10), at: 3)
        trail.append(CGPoint(x: 50, y: 10), at: 1)
        XCTAssertEqual(trail.samples, [PointerSample(point: CGPoint(x: 50, y: 10), time: 1)])
    }

    // MARK: - Shortcut table

    func testThePointerShortcutsAreInTheOneTable() {
        let ids = Set(ShortcutDefinitions.global.map(\.id))
        XCTAssertTrue(ids.contains("pointer.locate"))
        XCTAssertTrue(ids.contains("pointer.toggle"))
        XCTAssertEqual(ShortcutDefinitions.definition(id: "pointer.locate")?.action,
                       .locatePointer)
        XCTAssertEqual(ShortcutDefinitions.definition(id: "pointer.toggle")?.action,
                       .togglePointerEffects)
        XCTAssertEqual(ShortcutDefinitions.definition(id: "pointer.locate")?.display,
                       "⌃⌥⇧P")
        XCTAssertEqual(ShortcutDefinitions.definition(id: "pointer.toggle")?.display,
                       "⌃⌥⇧X")
    }
}

/// The one invariant that matters more than the effect itself: the surface can
/// never take a click, and it cannot outlive its geometry. A mistake here
/// blocks the desktop, so the panel is checked as a value.
@MainActor
final class PointerEffectPanelTests: XCTestCase {
    func testTheSurfaceCannotTakeAClickAndStaysOutOfTheWay() {
        let frame = CGRect(x: -1200, y: 0, width: 1000, height: 800)
        let panel = PointerEffectPanel.make(frame: frame, sharingType: .readOnly)

        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertEqual(panel.level.rawValue, NSWindow.Level.statusBar.rawValue + 1)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
        XCTAssertEqual(panel.sharingType, .readOnly)
        XCTAssertEqual(panel.animationBehavior, .none)
        XCTAssertFalse(panel.isReleasedWhenClosed)
        XCTAssertEqual(panel.frame, frame)
    }

    func testTheCapturePolicyIsAppliedAsAsked() {
        let panel = PointerEffectPanel.make(frame: .zero, sharingType: .none)
        XCTAssertEqual(panel.sharingType, .none)
    }
}
