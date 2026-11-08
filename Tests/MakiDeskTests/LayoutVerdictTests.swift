import CoreGraphics
import XCTest
@testable import MakiDesk

/// The verdict taken once a layout command has all its answers: how many windows
/// took their frame, and whether the result still holds together.
final class LayoutVerdictTests: XCTestCase {
    private let area = CGRect(x: 0, y: 0, width: 1200, height: 800)

    private func target(_ frame: CGRect, _ outcome: FrameOutcome,
                        area: CGRect? = nil) -> (intended: CGRect, area: CGRect, outcome: FrameOutcome) {
        (intended: frame, area: area ?? self.area, outcome: outcome)
    }

    func testACleanLayoutIsClean() {
        let verdict = LayoutVerdict.evaluate([
            target(CGRect(x: 0, y: 0, width: 500, height: 400), .accepted(CGRect(x: 0, y: 0, width: 500, height: 400))),
            target(CGRect(x: 508, y: 0, width: 400, height: 400), .accepted(CGRect(x: 508, y: 0, width: 400, height: 400))),
            target(CGRect(x: 0, y: 408, width: 500, height: 300), .accepted(CGRect(x: 0, y: 408, width: 500, height: 300))),
        ], gap: 8)
        XCTAssertEqual(verdict.placed, 3)
        XCTAssertTrue(verdict.isClean)
        XCTAssertEqual(verdict.summary, "clean")
    }

    func testARefusalIsCountedAndStillJudgedWhereTheWindowStayed() {
        let intended = CGRect(x: 508, y: 0, width: 400, height: 400)
        let actual = CGRect(x: 508, y: 0, width: 480, height: 400)
        let verdict = LayoutVerdict.evaluate([
            target(CGRect(x: 0, y: 0, width: 500, height: 400), .accepted(CGRect(x: 0, y: 0, width: 500, height: 400))),
            target(intended, .refused(actual)),
        ], gap: 8)
        XCTAssertEqual(verdict.placed, 1)
        XCTAssertEqual(verdict.refused, 1)
        XCTAssertFalse(verdict.isClean)
        XCTAssertTrue(verdict.summary.contains("1 kept size"))
    }

    func testAnUnconfirmedWindowIsCounted() {
        let verdict = LayoutVerdict.evaluate([
            target(CGRect(x: 0, y: 0, width: 500, height: 400), .timedOut),
        ], gap: 8)
        XCTAssertEqual(verdict.timedOut, 1)
        XCTAssertEqual(verdict.placed, 0)
        XCTAssertTrue(verdict.summary.contains("1 unconfirmed"))
    }

    func testTwoFramesThatOverlapByMoreThanAPointAreCounted() {
        let verdict = LayoutVerdict.evaluate([
            target(CGRect(x: 0, y: 0, width: 500, height: 500), .accepted(CGRect(x: 0, y: 0, width: 500, height: 500))),
            target(CGRect(x: 498, y: 0, width: 500, height: 500), .accepted(CGRect(x: 498, y: 0, width: 500, height: 500))),
        ], gap: 8)
        XCTAssertEqual(verdict.overlaps, 1)
        XCTAssertTrue(verdict.summary.contains("1 overlap"))
    }

    func testAPointOfContactIsRoundingNotOverlap() {
        let verdict = LayoutVerdict.evaluate([
            target(CGRect(x: 0, y: 0, width: 500, height: 500), .accepted(CGRect(x: 0, y: 0, width: 500, height: 500))),
            target(CGRect(x: 500, y: 0, width: 500, height: 500), .accepted(CGRect(x: 500, y: 0, width: 500, height: 500))),
        ], gap: 0)
        XCTAssertEqual(verdict.overlaps, 0)
    }

    func testAFrameThatLeavesItsDisplayIsCounted() {
        let verdict = LayoutVerdict.evaluate([
            target(CGRect(x: 100, y: 100, width: 1200, height: 300),
                   .accepted(CGRect(x: 100, y: 100, width: 1200, height: 300))),
        ], gap: 8)
        XCTAssertEqual(verdict.escapes, 1)
        XCTAssertTrue(verdict.summary.contains("1 outside"))
    }

    func testAGapThatComesTooCloseIsCounted() {
        let intendedA = CGRect(x: 0, y: 0, width: 500, height: 800)
        let intendedB = CGRect(x: 508, y: 0, width: 692, height: 800)
        let actualA = CGRect(x: 0, y: 0, width: 500, height: 800)
        let actualB = CGRect(x: 502, y: 0, width: 698, height: 800)
        let verdict = LayoutVerdict.evaluate([
            target(intendedA, .accepted(actualA)),
            target(intendedB, .accepted(actualB)),
        ], gap: 8)
        XCTAssertEqual(verdict.gapErosions, 1)
        XCTAssertTrue(verdict.summary.contains("1 gap"))
    }

    func testAGapAtTheToleranceIsNotCounted() {
        let intendedA = CGRect(x: 0, y: 0, width: 500, height: 800)
        let intendedB = CGRect(x: 508, y: 0, width: 692, height: 800)
        let actualA = CGRect(x: 0, y: 0, width: 500, height: 800)
        let actualB = CGRect(x: 507, y: 0, width: 693, height: 800)
        let verdict = LayoutVerdict.evaluate([
            target(intendedA, .accepted(actualA)),
            target(intendedB, .accepted(actualB)),
        ], gap: 8)
        XCTAssertEqual(verdict.gapErosions, 0)
    }
}
