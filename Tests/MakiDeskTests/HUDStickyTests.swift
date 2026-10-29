import CoreGraphics
import XCTest
@testable import MakiDesk

/// T60: states, sticky notices and the two-lane queue are decided by values, so
/// they can be checked without a window server or a screen.
final class HUDStickyTests: XCTestCase {
    private func notice(_ kind: HUDKind, sticky: Bool = false,
                        id: UUID = UUID()) -> HUDNotice {
        HUDNotice(id: id, text: "text", symbol: "circle", detail: nil, kind: kind,
                  date: Date(), overrideDuration: nil, sticky: sticky)
    }

    // MARK: - States

    func testEveryStateHasItsOwnLabel() {
        XCTAssertEqual(Set(HUDKind.allCases.map(\.label)).count, HUDKind.allCases.count)
        XCTAssertEqual(HUDKind.info.label, "Info")
        XCTAssertEqual(HUDKind.success.label, "Success")
    }

    func testInformationAndSuccessKeepTheBaseDuration() {
        let base: TimeInterval = 2
        XCTAssertEqual(HUDTiming.duration(for: .info, base: base) ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(HUDTiming.duration(for: .success, base: base) ?? 0, 2, accuracy: 0.001)
    }

    // MARK: - Sticky policy

    func testNothingIsStickyUnlessErrorsAreKept() {
        for kind in HUDKind.allCases where kind != .error {
            XCTAssertFalse(HUDStickyPolicy.isSticky(kind: kind, keepErrors: true), kind.label)
            XCTAssertFalse(HUDStickyPolicy.isSticky(kind: kind, keepErrors: false), kind.label)
        }
        XCTAssertFalse(HUDStickyPolicy.isSticky(kind: .error, keepErrors: false))
        XCTAssertTrue(HUDStickyPolicy.isSticky(kind: .error, keepErrors: true))
    }

    func testANoticeWithAnActionCannotVanishBeforeItIsUsed() {
        for kind in HUDKind.allCases {
            XCTAssertTrue(HUDStickyPolicy.isSticky(kind: kind, keepErrors: false,
                                                   hasActions: true), kind.label)
        }
    }

    func testAStickyNoticeHasNoTimer() {
        XCTAssertNil(HUDTiming.duration(for: notice(.error, sticky: true), base: 1.4))
        // A sticky notice also ignores an explicit duration.
        var timed = notice(.error, sticky: true)
        timed.overrideDuration = 9
        XCTAssertNil(HUDTiming.duration(for: timed, base: 1.4))
        XCTAssertEqual(HUDTiming.duration(for: notice(.error), base: 1.4) ?? 0,
                       3.0, accuracy: 0.001)
        XCTAssertEqual(HUDTiming.duration(for: notice(.confirmation), base: 1.4) ?? 0,
                       1.4, accuracy: 0.001)
    }

    func testTheErrorsOptionDefaultsToOffAndIsRemembered() {
        let suite = "MakiDeskHUDSticky-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(HUDSettings.errorsSticky(defaults: defaults))
        defaults.set(true, forKey: HUDSettings.errorsStickyKey)
        XCTAssertTrue(HUDSettings.errorsSticky(defaults: defaults))
    }

    // MARK: - Two lanes

    func testStickyNoticesNeverTakeTheTransientSlots() {
        var stack = HUDStack(maxSticky: 3, maxTransient: 2)
        let sticky = (0..<3).map { _ in UUID() }
        for id in sticky { XCTAssertNil(stack.addSticky(id)) }
        // All transient slots are still free: a notice waiting for the user
        // cannot block the ones that close by themselves.
        let first = UUID()
        let second = UUID()
        XCTAssertTrue(stack.addTransient(first))
        XCTAssertTrue(stack.addTransient(second))
        XCTAssertFalse(stack.addTransient(UUID()))
        XCTAssertEqual(stack.transient.count, 2)
        XCTAssertEqual(stack.sticky.count, 3)
    }

    func testTheOldestStickyNoticeLeavesWhenTheLaneIsFull() {
        var stack = HUDStack(maxSticky: 2, maxTransient: 2)
        let oldest = UUID()
        let middle = UUID()
        let newest = UUID()
        XCTAssertNil(stack.addSticky(oldest))
        XCTAssertNil(stack.addSticky(middle))
        XCTAssertEqual(stack.addSticky(newest), oldest)
        XCTAssertEqual(stack.sticky, [newest, middle])
    }

    func testRemovingFromEitherLaneLetsTheNextOneIn() {
        var stack = HUDStack(maxSticky: 1, maxTransient: 1)
        let sticky = UUID()
        let transient = UUID()
        XCTAssertNil(stack.addSticky(sticky))
        XCTAssertTrue(stack.addTransient(transient))
        XCTAssertFalse(stack.hasTransientRoom)

        XCTAssertTrue(stack.remove(transient))
        XCTAssertFalse(stack.remove(transient))
        XCTAssertTrue(stack.hasTransientRoom)
        XCTAssertTrue(stack.addTransient(UUID()))

        XCTAssertTrue(stack.remove(sticky))
        // The transient added after the removal is still on screen.
        XCTAssertEqual(stack.transient.count, 1)
        XCTAssertFalse(stack.isEmpty)
        stack.clear()
        XCTAssertTrue(stack.isEmpty)
    }

    func testTheStackIsOrderedStickyFirst() {
        var stack = HUDStack(maxSticky: 3, maxTransient: 2)
        let a = UUID()
        let b = UUID()
        let t = UUID()
        XCTAssertNil(stack.addSticky(a))
        XCTAssertNil(stack.addSticky(b))
        XCTAssertTrue(stack.addTransient(t))
        XCTAssertEqual(stack.ordered, [b, a, t])
        XCTAssertTrue(stack.contains(a))
        XCTAssertFalse(stack.contains(UUID()))
        stack.clear()
        XCTAssertTrue(stack.isEmpty)
    }

    // MARK: - Close control

    func testEveryStateHasItsOwnPreview() {
        let samples = HUDKind.allCases.map { HUDPreview.sample(for: $0) }
        for (kind, sample) in zip(HUDKind.allCases, samples) {
            XCTAssertFalse(sample.text.isEmpty, kind.label)
            XCTAssertFalse(sample.symbol.isEmpty, kind.label)
            XCTAssertFalse(sample.detail.isEmpty, kind.label)
        }
        // Distinguishable at a glance: no two states share a sample.
        XCTAssertEqual(Set(samples.map(\.text)).count, HUDKind.allCases.count)
        XCTAssertEqual(Set(samples.map(\.symbol)).count, HUDKind.allCases.count)
    }

    func testPreviewSymbolsCarryTheStateTheyShow() {
        // A symbol copied from the Preview buttons cannot land in a state the
        // inference would read as another one.
        for kind in HUDKind.allCases where kind != .progress {
            XCTAssertEqual(HUDKind.inferred(for: HUDPreview.sample(for: kind).symbol),
                           kind, kind.label)
        }
    }

}
