import AppKit
import CoreGraphics
import XCTest
@testable import MakiDesk

/// T61: the formats, the parser, the deadlines and the overlay's proximity rule
/// are values, so they are checked without a clock, a mouse or a panel.
final class TimerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: - Showing

    func testDurationsUseAsFewUnitsAsTheyNeed() {
        XCTAssertEqual(TimerText.duration(40), "40s")
        XCTAssertEqual(TimerText.duration(60), "1m")
        XCTAssertEqual(TimerText.duration(90), "1m 30s")
        XCTAssertEqual(TimerText.duration(2700), "45m")
        XCTAssertEqual(TimerText.duration(3600), "1h")
        XCTAssertEqual(TimerText.duration(4800), "1h 20m")
        XCTAssertEqual(TimerText.duration(0), "0s")
    }

    func testTheOverlayClockNeverShowsMoreThanItNeeds() {
        XCTAssertEqual(TimerText.countdown(40), "0:40")
        XCTAssertEqual(TimerText.countdown(90), "1:30")
        XCTAssertEqual(TimerText.countdown(3600), "1:00:00")
        XCTAssertEqual(TimerText.countdown(3672), "1:01:12")
        XCTAssertEqual(TimerText.countdown(-5), "0:00")
    }

    // MARK: - Reading

    func testParsingDurations() {
        XCTAssertEqual(TimerText.parse("25"), .countdown(1500))
        XCTAssertEqual(TimerText.parse("25m"), .countdown(1500))
        XCTAssertEqual(TimerText.parse("25 min"), .countdown(1500))
        XCTAssertEqual(TimerText.parse("40s"), .countdown(40))
        XCTAssertEqual(TimerText.parse("1h 30m"), .countdown(5400))
        XCTAssertEqual(TimerText.parse("1h30m"), .countdown(5400))
        XCTAssertEqual(TimerText.parse("2m 30s"), .countdown(150))
        XCTAssertEqual(TimerText.parse("  25M  "), .countdown(1500))
    }

    func testAColonIsATimeOfDayNotADuration() {
        // The rule that has to be learned once.
        XCTAssertEqual(TimerText.parse("8:30"), .clock(hour: 8, minute: 30))
        XCTAssertEqual(TimerText.parse("1:30"), .clock(hour: 1, minute: 30))
        XCTAssertEqual(TimerText.parse("20:15"), .clock(hour: 20, minute: 15))
        XCTAssertEqual(TimerText.parse("fino a 8:30"), .clock(hour: 8, minute: 30))
        XCTAssertEqual(TimerText.parse("fino alle 8:30"), .clock(hour: 8, minute: 30))
        XCTAssertEqual(TimerText.parse("until 8:30"), .clock(hour: 8, minute: 30))
    }

    func testUnreadableInputIsRefusedInsteadOfGuessed() {
        for text in ["", "   ", "abc", "25x", "8:5", "25:00", "0", "0m", "1h 1h", ":30", "25 30"] {
            XCTAssertNil(TimerText.parse(text), text)
        }
    }

    // MARK: - Deadlines

    func testAClockTimeMeansTodayWhenStillAheadAndTomorrowOtherwise() {
        let morning = utc.date(from: DateComponents(year: 2026, month: 10, day: 29,
                                                    hour: 7, minute: 0))!
        let evening = utc.date(from: DateComponents(year: 2026, month: 10, day: 29,
                                                    hour: 9, minute: 0))!
        let today = TimerBoard.nextOccurrence(hour: 8, minute: 30, after: morning, calendar: utc)
        XCTAssertEqual(utc.component(.day, from: today!), 29)
        XCTAssertEqual(utc.component(.hour, from: today!), 8)
        XCTAssertEqual(utc.component(.minute, from: today!), 30)

        let tomorrow = TimerBoard.nextOccurrence(hour: 8, minute: 30, after: evening, calendar: utc)
        XCTAssertEqual(utc.component(.day, from: tomorrow!), 30)
    }

    func testAClockTimeSurvivesTheChangeOfHour() {
        // Europe/Rome springs forward at 2:00 on 29 March 2026: the target is
        // read on the wall clock, so 8:30 stays 8:30.
        var rome = Calendar(identifier: .gregorian)
        rome.timeZone = TimeZone(identifier: "Europe/Rome")!
        let before = rome.date(from: DateComponents(year: 2026, month: 3, day: 28,
                                                    hour: 23, minute: 0))!
        let target = TimerBoard.nextOccurrence(hour: 8, minute: 30, after: before, calendar: rome)
        XCTAssertEqual(rome.component(.day, from: target!), 29)
        XCTAssertEqual(rome.component(.hour, from: target!), 8)
        XCTAssertEqual(rome.component(.minute, from: target!), 30)
    }

    func testCountdownsAndClockTimesLiveInOneList() {
        var board = TimerBoard()
        board.startCountdown(1500, now: now)
        board.startClock(hour: 8, minute: 30, now: now, calendar: utc)
        XCTAssertEqual(board.timers.count, 2)
        XCTAssertEqual(board.timers.map(\.label), ["25m", "8:30"])
        XCTAssertEqual(board.timers.map(\.origin), [.countdown, .clockTime])
        XCTAssertNotNil(board.timers[1].clockTarget)
    }

    func testTheNearestDeadlineComesFirst() {
        var board = TimerBoard()
        board.startCountdown(600, label: "10m", now: now)
        board.startCountdown(60, label: "1m", now: now)
        board.startCountdown(1800, label: "30m", now: now)
        XCTAssertEqual(board.sorted(at: now).map(\.label), ["1m", "10m", "30m"])
    }

    func testTheListStopsAtItsLimit() {
        var board = TimerBoard()
        for index in 0..<TimerBoard.maxTimers {
            XCTAssertNotNil(board.startCountdown(60, label: "t\(index)", now: now))
        }
        XCTAssertNil(board.startCountdown(60, now: now))
        XCTAssertNil(board.startClock(hour: 8, minute: 30, now: now, calendar: utc))
    }

    func testAPausedTimerKeepsWhatWasLeftAndNeverExpires() {
        var board = TimerBoard()
        let timer = board.startCountdown(600, now: now)!
        let later = now.addingTimeInterval(120)
        board.pause(timer.id, now: later)
        XCTAssertEqual(board.timers[0].remaining(at: later), 480, accuracy: 0.5)
        XCTAssertEqual(board.timers[0].remaining(at: later.addingTimeInterval(10_000)),
                       480, accuracy: 0.5)
        XCTAssertTrue(board.expire(at: later.addingTimeInterval(10_000)).isEmpty)
        XCTAssertFalse(board.hasRunning)

        board.resume(timer.id, now: later.addingTimeInterval(10))
        XCTAssertEqual(board.timers[0].remaining(at: later.addingTimeInterval(10)),
                       480, accuracy: 0.5)
        XCTAssertTrue(board.hasRunning)
        XCTAssertNotNil(board.timers[0].deadline)
    }

    func testTheRemainingTimeComesFromTheDeadlineNotFromTicks() {
        var board = TimerBoard()
        let timer = board.startCountdown(600, now: now)!
        // The app was asleep for an hour: the deadline still decides.
        let afterSleep = now.addingTimeInterval(3600)
        XCTAssertTrue(board.timers[0].isDue(at: afterSleep))
        let finished = board.expire(at: afterSleep)
        XCTAssertEqual(finished.map(\.id), [timer.id])
        XCTAssertTrue(board.isEmpty)
        // The deadline itself did not move.
        XCTAssertEqual(timer.deadline, now.addingTimeInterval(600))
    }

    func testOnlyTheTimersThatRanOutAreReturnedOnce() {
        var board = TimerBoard()
        board.startCountdown(60, label: "short", now: now)
        board.startCountdown(600, label: "long", now: now)
        let first = board.expire(at: now.addingTimeInterval(61))
        XCTAssertEqual(first.map(\.label), ["short"])
        XCTAssertEqual(board.timers.map(\.label), ["long"])
        XCTAssertTrue(board.expire(at: now.addingTimeInterval(62)).isEmpty)
    }

    func testALabelReplacesTheDefaultAndIsTidiedUp() {
        var board = TimerBoard()
        board.startCountdown(1500, label: TimerText.cleanLabel("  Tea  "), now: now)
        board.startClock(hour: 8, minute: 30, now: now, calendar: utc,
                         label: TimerText.cleanLabel("Stand up"))
        XCTAssertEqual(board.timers.map(\.label), ["Tea", "Stand up"])

        // No label keeps the value, which is what the list would otherwise say.
        board.startCountdown(60, label: TimerText.cleanLabel("   "), now: now)
        XCTAssertEqual(board.timers.last?.label, "1m")
    }

    func testALabelIsFlattenedAndCapped() {
        XCTAssertNil(TimerText.cleanLabel(nil))
        XCTAssertNil(TimerText.cleanLabel(""))
        XCTAssertNil(TimerText.cleanLabel("  \n  "))
        XCTAssertEqual(TimerText.cleanLabel("  Tea\nbreak "), "Tea break")
        XCTAssertEqual(TimerText.cleanLabel(String(repeating: "a", count: 60))?.count, 40)
    }

    func testTheMenuListDoesNotDependOnTheSeconds() {
        // The titles the status menu builds must not read the clock, or the
        // menu would be rebuilt and closed every second while it is open.
        var board = TimerBoard()
        board.startCountdown(60, label: "Tea", now: now)
        XCTAssertEqual(board.timers.map(\.label), ["Tea"])
        XCTAssertEqual(TimerText.row(board.timers[0], now: now).hasPrefix("Tea"), true)
    }

    func testAClockTimerNamesItsHourEvenWhenPaused() {
        var board = TimerBoard()
        let timer = board.startClock(hour: 8, minute: 30, now: now, calendar: utc)!
        board.pause(timer.id, now: now)
        let row = TimerText.row(board.timers[0], now: now, calendar: utc)
        XCTAssertTrue(row.contains("8:30"), row)
    }

    // MARK: - Overlay proximity

    private let overlay = CGRect(x: 1200, y: 700, width: 230, height: 90)
    private let far = CGPoint(x: 200, y: 200)

    func testTheOverlayStepsAsideWhenThePointerArrives() {
        var rule = TimerProximity()
        XCTAssertFalse(rule.update(pointer: far, overlay: overlay, now: now))
        // Within the hide radius.
        let close = CGPoint(x: overlay.minX - 20, y: overlay.midY)
        XCTAssertTrue(rule.update(pointer: close, overlay: overlay, now: now))
        XCTAssertNil(rule.revealAt)
    }

    func testItStaysAsideUntilThePointerIsTwiceAsFarAndTheDelayHasPassed() {
        var rule = TimerProximity()
        let close = CGPoint(x: overlay.minX - 20, y: overlay.midY)
        _ = rule.update(pointer: close, overlay: overlay, now: now)

        // Between the two thresholds: still hidden, no flicker.
        let between = CGPoint(x: overlay.minX - 100, y: overlay.midY)
        XCTAssertTrue(rule.update(pointer: between, overlay: overlay, now: now))
        XCTAssertNil(rule.revealAt)

        // Outside: the reveal is scheduled, not immediate.
        XCTAssertTrue(rule.update(pointer: far, overlay: overlay, now: now))
        XCTAssertNotNil(rule.revealAt)
        XCTAssertTrue(rule.update(pointer: far, overlay: overlay,
                                  now: now.addingTimeInterval(0.2)))
        // After the delay it comes back.
        XCTAssertFalse(rule.update(pointer: far, overlay: overlay,
                                   now: now.addingTimeInterval(0.41)))
        XCTAssertNil(rule.revealAt)
    }

    func testComingBackCancelsAPendingReveal() {
        var rule = TimerProximity()
        let close = CGPoint(x: overlay.minX - 20, y: overlay.midY)
        _ = rule.update(pointer: close, overlay: overlay, now: now)
        _ = rule.update(pointer: far, overlay: overlay, now: now)
        XCTAssertNotNil(rule.revealAt)
        // The pointer returns before the delay ends: nothing appears.
        XCTAssertTrue(rule.update(pointer: close, overlay: overlay,
                                  now: now.addingTimeInterval(0.1)))
        XCTAssertNil(rule.revealAt)
        // Leaving again starts a new delay: still hidden for now.
        XCTAssertTrue(rule.update(pointer: far, overlay: overlay,
                                  now: now.addingTimeInterval(5)))
        XCTAssertNotNil(rule.revealAt)
    }

    func testTheDistanceIsMeasuredFromTheEdgeOfTheCard() {
        XCTAssertEqual(TimerProximity.distance(from: CGPoint(x: 1100, y: 720),
                                               to: overlay), 100, accuracy: 0.5)
        XCTAssertEqual(TimerProximity.distance(from: CGPoint(x: 1250, y: 720),
                                               to: overlay), 0, accuracy: 0.5)
    }

    func testTheSoundListHasADefaultAndFallsBackToIt() {
        XCTAssertTrue(TimerSettings.soundNames.contains(TimerSettings.defaultSound))
        XCTAssertFalse(TimerSettings.soundNames.isEmpty)
        XCTAssertEqual(TimerSettings.resolvedSound("Ping"), "Ping")
        XCTAssertEqual(TimerSettings.resolvedSound(nil), TimerSettings.defaultSound)
        XCTAssertEqual(TimerSettings.resolvedSound("Nope"), TimerSettings.defaultSound)
        // Every offered name is a system sound this Mac actually has.
        for name in TimerSettings.soundNames {
            XCTAssertNotNil(NSSound(named: name), name)
        }
    }

    func testTheOverlayAlphaFollowsTheSettingAndReduceTransparency() {
        XCTAssertEqual(TimerSettings.alpha(opacity: 0.6, reduceTransparency: false), 0.6)
        XCTAssertEqual(TimerSettings.alpha(opacity: 0.6, reduceTransparency: true), 1)
        XCTAssertEqual(TimerSettings.alpha(opacity: 0.1, reduceTransparency: false),
                       CGFloat(TimerSettings.opacityRange.lowerBound))
    }
}
