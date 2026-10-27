import CoreGraphics
import XCTest
@testable import MakiDesk

/// T52: duration policy, queue layout, history ring and defaults.
final class HUDModelTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    // MARK: - Duration

    func testSeverityDurations() {
        XCTAssertEqual(HUDTiming.duration(for: .confirmation, base: 1.4) ?? 0, 1.4, accuracy: 0.001)
        XCTAssertEqual(HUDTiming.duration(for: .warning, base: 1.4) ?? 0, 2.1, accuracy: 0.001)
        XCTAssertEqual(HUDTiming.duration(for: .error, base: 1.4) ?? 0, 3.0, accuracy: 0.001)
        XCTAssertNil(HUDTiming.duration(for: .progress, base: 1.4))
        XCTAssertGreaterThan(HUDTiming.duration(for: .warning, base: 3) ?? 0, 3)
    }

    func testErrorsKeepAThreeSecondFloor() {
        XCTAssertEqual(HUDTiming.duration(for: .error, base: 0.5) ?? 0, 3.0, accuracy: 0.001)
    }

    // MARK: - Layout

    func testBottomCenterStacksUpward() {
        let frames = HUDLayout.frames(anchor: .bottomCenter, screen: screen,
                                      sizes: [CGSize(width: 200, height: 40),
                                              CGSize(width: 220, height: 50)])
        XCTAssertEqual(frames[0], CGRect(x: 400, y: 24, width: 200, height: 40))
        XCTAssertEqual(frames[1], CGRect(x: 390, y: 72, width: 220, height: 50))
    }

    func testTopRightStacksDownwardAndStaysInside() {
        let frames = HUDLayout.frames(anchor: .topRight, screen: screen,
                                      sizes: [CGSize(width: 200, height: 40),
                                              CGSize(width: 220, height: 50)])
        XCTAssertEqual(frames[0], CGRect(x: 776, y: 736, width: 200, height: 40))
        XCTAssertEqual(frames[1], CGRect(x: 756, y: 678, width: 220, height: 50))
    }

    func testNegativeOriginDisplayStaysInside() {
        let left = CGRect(x: -1200, y: 0, width: 1200, height: 800)
        let frames = HUDLayout.frames(anchor: .bottomRight, screen: left,
                                      sizes: [CGSize(width: 200, height: 40)])
        XCTAssertEqual(frames[0].maxX, -24)
        XCTAssertEqual(frames[0].minX, -224)
    }

    func testEmptySizesAreSkipped() {
        let frames = HUDLayout.frames(anchor: .bottomCenter, screen: screen,
                                      sizes: [.zero, CGSize(width: 100, height: 30)])
        XCTAssertEqual(frames[0], .zero)
        XCTAssertEqual(frames[1].minY, 24)
    }

    // MARK: - History

    func testHistoryIsNewestFirstAndCapped() {
        var history = HUDHistory(limit: 50)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<55 {
            history.add(HUDNotice(id: UUID(), text: "notice \(index)",
                                  symbol: "checkmark", detail: nil,
                                  kind: .confirmation,
                                  date: base.addingTimeInterval(Double(index)),
                                  overrideDuration: nil))
        }
        XCTAssertEqual(history.notices.count, 50)
        XCTAssertEqual(history.notices.first?.text, "notice 54")
        XCTAssertEqual(history.notices.last?.text, "notice 5")
    }

    func testHistoryAddWithTheSameIDMovesTheNoticeToTheTop() {
        var history = HUDHistory()
        let id = UUID()
        let first = HUDNotice(id: id, text: "first", symbol: "checkmark", detail: nil,
                              kind: .confirmation, date: Date(), overrideDuration: nil)
        let second = HUDNotice(id: UUID(), text: "second", symbol: "checkmark", detail: nil,
                               kind: .confirmation, date: Date(), overrideDuration: nil)
        let updated = HUDNotice(id: id, text: "first, updated", symbol: "checkmark", detail: nil,
                                kind: .warning, date: Date(), overrideDuration: nil)
        history.add(first)
        history.add(second)
        history.add(updated)
        XCTAssertEqual(history.notices.map(\.text), ["first, updated", "second"])
    }

    func testClearEmptiesTheHistory() {
        var history = HUDHistory()
        history.add(HUDNotice(id: UUID(), text: "a", symbol: "checkmark", detail: nil,
                              kind: .confirmation, date: Date(), overrideDuration: nil))
        history.clear()
        XCTAssertTrue(history.notices.isEmpty)
    }

    // MARK: - Typography

    func testTypographyGrowsWithTheTextSize() {
        let regular = HUDTypography(textSize: 16, compact: false)
        XCTAssertEqual(regular.titleSize, 16, accuracy: 0.001)
        XCTAssertEqual(regular.detailSize, 13.5, accuracy: 0.001)
        XCTAssertEqual(regular.iconSize, 17, accuracy: 0.001)
        XCTAssertGreaterThan(regular.horizontalPadding,
                             HUDTypography(textSize: 14, compact: false).horizontalPadding)
        XCTAssertGreaterThan(regular.verticalPadding,
                             HUDTypography(textSize: 14, compact: false).verticalPadding)
        XCTAssertGreaterThan(regular.cornerRadius,
                             HUDTypography(textSize: 14, compact: false).cornerRadius)

        let compact = HUDTypography(textSize: 16, compact: true)
        XCTAssertLessThan(compact.titleSize, regular.titleSize)
        XCTAssertLessThan(compact.horizontalPadding, regular.horizontalPadding)
    }

    func testTypographyClampsExtremeSizes() {
        XCTAssertEqual(HUDTypography(textSize: 5, compact: false).titleSize, 11)
        XCTAssertEqual(HUDTypography(textSize: 40, compact: false).titleSize, 22)
    }

    // MARK: - Kind inference and settings

    func testSymbolInfersTheSeverity() {
        XCTAssertEqual(HUDKind.inferred(for: "exclamationmark.triangle.fill"), .error)
        XCTAssertEqual(HUDKind.inferred(for: "nosign"), .error)
        XCTAssertEqual(HUDKind.inferred(for: "xmark.circle"), .warning)
        XCTAssertEqual(HUDKind.inferred(for: "hand.raised.fill"), .warning)
        XCTAssertEqual(HUDKind.inferred(for: "lock.fill"), .warning)
        XCTAssertEqual(HUDKind.inferred(for: "checkmark.circle.fill"), .confirmation)
        XCTAssertEqual(HUDKind.inferred(for: "folder"), .confirmation)
    }

    func testSettingsFallBackToTheOldBehaviour() {
        let suite = "MakiDeskHUD-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(HUDSettings.position(defaults: defaults), .bottomCenter)
        XCTAssertEqual(HUDSettings.screenLocation(defaults: defaults), .focusedWindow)
        XCTAssertEqual(HUDSettings.baseDuration(defaults: defaults), 1.4, accuracy: 0.001)
        XCTAssertTrue(HUDSettings.historyEnabled(defaults: defaults))
        XCTAssertTrue(HUDSettings.voiceOverEnabled(defaults: defaults))
        XCTAssertFalse(HUDSettings.compact(defaults: defaults))
        XCTAssertEqual(HUDSettings.textSize(defaults: defaults), 14, accuracy: 0.001)

        defaults.set("topRight", forKey: HUDSettings.positionKey)
        defaults.set("mouse", forKey: HUDSettings.screenKey)
        defaults.set(3.0, forKey: HUDSettings.baseDurationKey)
        defaults.set(false, forKey: HUDSettings.historyEnabledKey)
        defaults.set(false, forKey: HUDSettings.voiceOverKey)
        defaults.set(true, forKey: HUDSettings.compactKey)
        defaults.set(18.0, forKey: HUDSettings.textSizeKey)
        XCTAssertEqual(HUDSettings.position(defaults: defaults), .topRight)
        XCTAssertEqual(HUDSettings.screenLocation(defaults: defaults), .mouse)
        XCTAssertEqual(HUDSettings.baseDuration(defaults: defaults), 3.0, accuracy: 0.001)
        XCTAssertFalse(HUDSettings.historyEnabled(defaults: defaults))
        XCTAssertFalse(HUDSettings.voiceOverEnabled(defaults: defaults))
        XCTAssertTrue(HUDSettings.compact(defaults: defaults))
        XCTAssertEqual(HUDSettings.textSize(defaults: defaults), 18, accuracy: 0.001)

        defaults.set(40.0, forKey: HUDSettings.textSizeKey)
        XCTAssertEqual(HUDSettings.textSize(defaults: defaults), 22, accuracy: 0.001)
        defaults.set(5.0, forKey: HUDSettings.textSizeKey)
        XCTAssertEqual(HUDSettings.textSize(defaults: defaults), 11, accuracy: 0.001)
    }

    func testUnknownPositionFallsBackToBottomCentre() {
        let suite = "MakiDeskHUD-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("somewhere", forKey: HUDSettings.positionKey)
        defaults.set("somewhere", forKey: HUDSettings.screenKey)
        XCTAssertEqual(HUDSettings.position(defaults: defaults), .bottomCenter)
        XCTAssertEqual(HUDSettings.screenLocation(defaults: defaults), .focusedWindow)
    }
}
