import XCTest
@testable import MakiDesk

/// T16, the hold behind the peek: press and release, a repeated press that must
/// not restart anything, and the watchdog that closes a hold whose release never
/// arrived. The clock is injected, so none of it waits on wall time.
final class PeekControllerTests: XCTestCase {
    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ interval: TimeInterval) { date.addTimeInterval(interval) }
    }

    private func controller(_ clock: Clock) -> PeekController {
        let peek = PeekController()
        peek.now = { clock.date }
        return peek
    }

    func testPressStartsAHold() {
        let peek = controller(Clock())
        XCTAssertFalse(peek.isHolding)
        XCTAssertTrue(peek.press())
        XCTAssertTrue(peek.isHolding)
    }

    func testARepeatedPressDoesNotRestartTheHold() {
        let clock = Clock()
        let peek = controller(clock)
        peek.press()
        clock.advance(5)
        // Key repeat on a held key: the second press must be ignored, or the
        // watchdog would never fire on a key held down.
        XCTAssertFalse(peek.press())
        XCTAssertEqual(peek.release() ?? -1, 5, accuracy: 0.001)
    }

    func testReleaseReportsHowLongTheKeyWasHeld() {
        let clock = Clock()
        let peek = controller(clock)
        peek.press()
        clock.advance(1.5)
        XCTAssertEqual(peek.release() ?? -1, 1.5, accuracy: 0.001)
        XCTAssertFalse(peek.isHolding)
    }

    func testReleaseWithoutAHoldIsIgnored() {
        let peek = controller(Clock())
        XCTAssertNil(peek.release())
        XCTAssertFalse(peek.isHolding)
    }

    func testTheHoldExpiresAfterTheWatchdog() {
        let clock = Clock()
        let peek = controller(clock)
        peek.press()
        clock.advance(peek.holdWatchdog - 0.5)
        XCTAssertFalse(peek.hasExpired)
        clock.advance(1)
        XCTAssertTrue(peek.hasExpired)
    }

    func testALostReleaseLeavesTheHoldExpiredAndReleaseStillEndsIt() {
        let clock = Clock()
        let peek = controller(clock)
        peek.press()
        clock.advance(peek.holdWatchdog + 5)
        XCTAssertTrue(peek.hasExpired)
        // The physical release, if it ever comes, still ends the hold cleanly.
        XCTAssertEqual(peek.release() ?? -1, peek.holdWatchdog + 5, accuracy: 0.001)
        XCTAssertFalse(peek.isHolding)
    }

    func testCancelEndsAHoldAtOnceAndAllowsANewOne() {
        let peek = controller(Clock())
        peek.press()
        peek.cancel()
        XCTAssertFalse(peek.isHolding)
        XCTAssertFalse(peek.hasExpired)
        XCTAssertTrue(peek.press())
    }

    func testAReleasedHoldNeverExpires() {
        let clock = Clock()
        let peek = controller(clock)
        peek.press()
        peek.release()
        clock.advance(peek.holdWatchdog * 10)
        XCTAssertFalse(peek.hasExpired)
    }
}
