import XCTest
import AppKit
@testable import MakiDesk

/// The layouts that know about an app's size floors: grid, spiral, treemap and
/// the keyboard ladder. Pure, so each rule is checked without a desktop.
final class ConstrainedLayoutTests: XCTestCase {
    private let area = CGRect(x: 0, y: 0, width: 1200, height: 800)

    // MARK: - Grid

    func testTheUnconstrainedGridIsStillTheOldGrid() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)
        XCTAssertEqual(TilingEngine.layout(.grid, count: 5, in: screen, gap: 12).frames,
                       TilingEngine.gridFrames(count: 5, in: screen, gap: 12))
    }

    func testAWideWindowWidensItsColumnAndTheOtherColumnGivesWay() {
        let wide = CGRect(x: 0, y: 0, width: 1600, height: 800)
        let geometry = TilingEngine.layout(
            .grid, count: 2, in: wide, gap: 10,
            minimums: [CGSize(width: 900, height: 300), .zero])
        XCTAssertEqual(geometry.unplacedCount, 0)
        XCTAssertFalse(geometry.fallback)
        XCTAssertGreaterThanOrEqual(geometry.frames[0].width, 900)
        XCTAssertGreaterThanOrEqual(geometry.frames[0].height, 300)
        XCTAssertGreaterThanOrEqual(geometry.frames[1].width, 1)
        XCTAssertLessThanOrEqual(geometry.frames[1].maxX, wide.maxX + 0.5)
    }

    func testAGridDropsTheWindowItCannotFitAndKeepsTheRest() {
        let geometry = TilingEngine.layout(
            .grid, count: 2, in: area, gap: 10,
            minimums: [CGSize(width: 700, height: 300),
                       CGSize(width: 700, height: 300)])
        XCTAssertEqual(geometry.unplacedCount, 1)
        XCTAssertTrue(geometry.fallback)
        XCTAssertTrue(TilingEngine.LayoutGeometry.isPlaced(geometry.frames[0]))
        XCTAssertFalse(TilingEngine.LayoutGeometry.isPlaced(geometry.frames[1]))
    }

    func testAGridDropsWindowsOnlyWhenEvenOneFloorCannotFit() {
        let small = CGRect(x: 0, y: 0, width: 600, height: 400)
        let geometry = TilingEngine.layout(
            .grid, count: 2, in: small, gap: 10,
            minimums: [CGSize(width: 900, height: 300), .zero])
        XCTAssertEqual(geometry.unplacedCount, 2)
        XCTAssertTrue(geometry.fallback)
    }

    // MARK: - Golden spiral

    func testTheSpiralLeavesOutAWindowWhoseSlotCannotHoldIt() {
        let geometry = TilingEngine.layout(
            .goldenSpiral, count: 4, in: area, gap: 10,
            minimums: [.zero, .zero, .zero, CGSize(width: 700, height: 600)])
        XCTAssertEqual(geometry.unplacedCount, 1)
        XCTAssertTrue(geometry.fallback)
        XCTAssertTrue(TilingEngine.LayoutGeometry.isPlaced(geometry.frames[0]))
        XCTAssertFalse(TilingEngine.LayoutGeometry.isPlaced(geometry.frames[3]))
    }

    // MARK: - Content

    func testAnUnconstrainedTreemapIsStillTheTreemap() {
        let weights = [2.0, 1.0, 1.0]
        XCTAssertEqual(TilingEngine.layout(.content, count: 3, in: area, gap: 8,
                                           weights: weights).frames,
                       TilingEngine.weightedFrames(weights: weights, in: area, gap: 8))
    }

    func testATreemapKeepsEveryFloorWhenItCan() {
        let geometry = TilingEngine.layout(
            .content, count: 3, in: area, gap: 8,
            weights: [2, 1, 1],
            minimums: [CGSize(width: 700, height: 500), .zero, .zero])
        XCTAssertEqual(geometry.unplacedCount, 1)
        XCTAssertTrue(geometry.fallback)
        XCTAssertGreaterThanOrEqual(geometry.frames[0].width, 700)
        XCTAssertGreaterThanOrEqual(geometry.frames[0].height, 500)
    }

    func testAnImpossibleTreemapFallsBackToTheConstrainedGrid() {
        let small = CGRect(x: 0, y: 0, width: 400, height: 300)
        let geometry = TilingEngine.layout(
            .content, count: 2, in: small, gap: 8, weights: [1, 1],
            minimums: [CGSize(width: 900, height: 300), CGSize(width: 900, height: 300)])
        XCTAssertEqual(geometry.unplacedCount, 2)
        XCTAssertTrue(geometry.fallback)
    }

    // MARK: - Ladder

    func testAHorizontalStepNeverGoesBelowTheFloor() {
        let states = TilingEngine.ladderRects(
            area: area, axis: .horizontal, orthogonal: 0...800,
            minimum: CGSize(width: 650, height: 0))
        XCTAssertEqual(states.count, 7)
        XCTAssertEqual(states[0].width, 650, accuracy: 0.01)
        XCTAssertEqual(states[1].width, 650, accuracy: 0.01)
        XCTAssertEqual(states[2].width, 1200 / TilingEngine.phi, accuracy: 0.01)
        XCTAssertEqual(states[3].width, 1200, accuracy: 0.01)
    }

    func testAVerticalStepNeverGoesBelowTheFloor() {
        let states = TilingEngine.ladderRects(
            area: area, axis: .vertical, orthogonal: 0...1200,
            minimum: CGSize(width: 0, height: 400))
        XCTAssertEqual(states.count, 7)
        XCTAssertEqual(states[0].height, 400, accuracy: 0.01)
        XCTAssertEqual(states[1].height, 400, accuracy: 0.01)
        XCTAssertEqual(states[3].height, 800, accuracy: 0.01)
    }

    func testAFloorBiggerThanTheAreaIsClampedToTheArea() {
        let states = TilingEngine.ladderRects(
            area: area, axis: .vertical, orthogonal: 0...1200,
            minimum: CGSize(width: 0, height: 5_000))
        XCTAssertEqual(states[0].height, 800, accuracy: 0.01)
        XCTAssertEqual(states[6].height, 800, accuracy: 0.01)
    }

    func testAWindowAtItsFloorReadsAsTheLowEnd() {
        let states = TilingEngine.ladderRects(
            area: area, axis: .vertical, orthogonal: 0...1200,
            minimum: CGSize(width: 0, height: 400))
        let atFloor = CGRect(x: 0, y: 0, width: 1200, height: 400)
        XCTAssertEqual(TilingEngine.slot(of: atFloor, area: area, axis: .vertical,
                                         states: states, minimumHeight: 400), .beforeStart)

        let aboveFloor = CGRect(x: 0, y: 0, width: 1200, height: 600)
        if case .beforeStart = TilingEngine.slot(of: aboveFloor, area: area, axis: .vertical,
                                                 states: states, minimumHeight: 400) {
            XCTFail("a window above its floor is on the ladder, not below it")
        }
    }
}
