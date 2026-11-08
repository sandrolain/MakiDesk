import CoreGraphics
import XCTest
@testable import MakiDesk

/// The bounded drift response: two agreeing readings, one re-apply, then stop
/// if the app takes the frame back. Clock-injected so no test sleeps.
final class LayoutDriftGuardTests: XCTestCase {
    private let intended = CGRect(x: 0, y: 0, width: 500, height: 400)
    private let drifted = CGRect(x: 120, y: 40, width: 500, height: 400)
    private let start = Date(timeIntervalSince1970: 1_000)

    private func note(_ guardState: inout LayoutDriftGuard, _ frame: CGRect,
                      at seconds: TimeInterval) -> LayoutDriftGuard.Decision {
        guardState.note(frame: frame, intended: intended,
                        now: start.addingTimeInterval(seconds), recurrenceWindow: 5)
    }

    func testAWindowOnTargetIsIdle() {
        var guardState = LayoutDriftGuard()
        XCTAssertEqual(note(&guardState, intended, at: 0), .idle)
    }

    func testOneDriftedReadingWaits() {
        var guardState = LayoutDriftGuard()
        XCTAssertEqual(note(&guardState, drifted, at: 0), .seen)
    }

    func testTwoAgreeingReadingsAskForOneReapply() {
        var guardState = LayoutDriftGuard()
        XCTAssertEqual(note(&guardState, drifted, at: 0), .seen)
        XCTAssertEqual(note(&guardState, drifted, at: 0.1), .reapply)
    }

    func testTwoDifferentReadingsWaitForAgreement() {
        var guardState = LayoutDriftGuard()
        XCTAssertEqual(note(&guardState, drifted, at: 0), .seen)
        let elsewhere = CGRect(x: 200, y: 40, width: 500, height: 400)
        XCTAssertEqual(note(&guardState, elsewhere, at: 0.1), .seen)
    }

    func testTheSameDriftAfterAReapplyStops() {
        var guardState = LayoutDriftGuard()
        _ = note(&guardState, drifted, at: 0)
        _ = note(&guardState, drifted, at: 0.1)
        XCTAssertEqual(note(&guardState, drifted, at: 1), .seen)
        XCTAssertEqual(note(&guardState, drifted, at: 1.1), .abandon)
    }

    func testADriftLongAfterTheReapplyIsANewEpisode() {
        var guardState = LayoutDriftGuard()
        _ = note(&guardState, drifted, at: 0)
        _ = note(&guardState, drifted, at: 0.1)
        let later = CGRect(x: 80, y: 10, width: 500, height: 400)
        XCTAssertEqual(note(&guardState, later, at: 6), .seen)
        XCTAssertEqual(note(&guardState, later, at: 6.1), .reapply)
    }

    func testBackOnTargetResetsTheEpisode() {
        var guardState = LayoutDriftGuard()
        _ = note(&guardState, drifted, at: 0)
        XCTAssertEqual(note(&guardState, intended, at: 0.1), .idle)
        XCTAssertEqual(note(&guardState, drifted, at: 0.2), .seen)
    }

    func testAbandonedStaysQuiet() {
        var guardState = LayoutDriftGuard()
        _ = note(&guardState, drifted, at: 0)
        _ = note(&guardState, drifted, at: 0.1)
        _ = note(&guardState, drifted, at: 1)
        XCTAssertEqual(note(&guardState, drifted, at: 1.1), .abandon)
        XCTAssertEqual(note(&guardState, drifted, at: 2), .idle)
    }

    func testReappliesAreBoundedEvenAfterTouchingTheTarget() {
        var guardState = LayoutDriftGuard()
        _ = note(&guardState, drifted, at: 0)
        XCTAssertEqual(note(&guardState, drifted, at: 0.1), .reapply)
        XCTAssertEqual(note(&guardState, intended, at: 0.2), .idle)

        _ = note(&guardState, drifted, at: 0.3)
        XCTAssertEqual(note(&guardState, drifted, at: 0.4), .reapply)
        XCTAssertEqual(note(&guardState, intended, at: 0.5), .idle)

        _ = note(&guardState, drifted, at: 0.6)
        XCTAssertEqual(note(&guardState, drifted, at: 0.7), .abandon)
    }
}
