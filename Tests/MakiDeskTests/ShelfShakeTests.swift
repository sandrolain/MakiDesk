import XCTest
@testable import MakiDesk

final class ShelfShakeTests: XCTestCase {
    private func run(_ preset: ShakePreset,
                     points: [(CGFloat, TimeInterval)]) -> Bool {
        var detector = ShakeDetector()
        for (x, time) in points {
            if detector.drag(to: CGPoint(x: x, y: 0), at: time, preset: preset) {
                return true
            }
        }
        return false
    }

    func testMediumZigZagTriggers() {
        let points: [(CGFloat, TimeInterval)] = [
            (0, 0), (20, 0.1), (0, 0.2), (20, 0.3), (0, 0.4), (20, 0.5), (0, 0.6)
        ]
        XCTAssertTrue(run(.medium, points: points))
    }

    func testHighTriggersWithFewerChanges() {
        let points: [(CGFloat, TimeInterval)] = [
            (0, 0), (15, 0.1), (0, 0.2), (15, 0.3), (0, 0.4), (15, 0.5)
        ]
        XCTAssertTrue(run(.high, points: points))
        XCTAssertFalse(run(.medium, points: points),
                       "medium needs one more change and 18 pt legs")
    }

    func testLowNeedsLongerLegsAndMoreChanges() {
        let shortLegs: [(CGFloat, TimeInterval)] = [
            (0, 0), (20, 0.1), (0, 0.2), (20, 0.3), (0, 0.4), (20, 0.5), (0, 0.6)
        ]
        XCTAssertFalse(run(.low, points: shortLegs))

        let longLegs: [(CGFloat, TimeInterval)] = [
            (0, 0), (30, 0.1), (0, 0.2), (30, 0.3), (0, 0.4), (30, 0.5),
            (0, 0.6), (30, 0.7), (0, 0.8)
        ]
        XCTAssertTrue(run(.low, points: longLegs))
    }

    func testAStraightDragNeverTriggers() {
        XCTAssertFalse(run(.high, points: [
            (0, 0), (20, 0.1), (40, 0.2), (60, 0.3), (80, 0.4), (100, 0.5)
        ]))
    }

    func testSmallJitterNeverTriggers() {
        let points: [(CGFloat, TimeInterval)] = [
            (0, 0), (8, 0.05), (0, 0.1), (8, 0.15), (0, 0.2), (8, 0.25), (0, 0.3)
        ]
        XCTAssertFalse(run(.medium, points: points))
    }

    func testSlowChangesFallOutsideTheWindow() {
        let points: [(CGFloat, TimeInterval)] = [
            (0, 0), (20, 0.1), (0, 0.2), (20, 0.3), (0, 0.4), (20, 0.5),
            (0, 2.0), (20, 2.2), (0, 2.4)
        ]
        XCTAssertFalse(run(.medium, points: points))
    }

    func testResetStartsAFreshGesture() {
        var detector = ShakeDetector()
        let preset = ShakePreset.medium
        _ = detector.drag(to: CGPoint(x: 0, y: 0), at: 0, preset: preset)
        _ = detector.drag(to: CGPoint(x: 20, y: 0), at: 0.1, preset: preset)
        detector.reset()
        XCTAssertFalse(detector.drag(to: CGPoint(x: 0, y: 0), at: 0.2, preset: preset))
        XCTAssertTrue(detector.drag(to: CGPoint(x: 20, y: 0), at: 0.3, preset: preset)
                      == false, "the next point only starts a new direction")
    }

    func testVerticalMovementIsIgnored() {
        var detector = ShakeDetector()
        for (index, y) in [0.0, 30, 0, 30, 0, 30, 0].enumerated() {
            XCTAssertFalse(detector.drag(to: CGPoint(x: 10, y: y),
                                         at: Double(index) * 0.1,
                                         preset: .high))
        }
    }
}

private extension ShakePreset {
    static let low = ShelfShakeSensitivity.low.preset
    static let medium = ShelfShakeSensitivity.medium.preset
    static let high = ShelfShakeSensitivity.high.preset
}
