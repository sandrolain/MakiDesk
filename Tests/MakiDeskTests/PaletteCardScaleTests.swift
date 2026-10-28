import XCTest
@testable import MakiDesk

/// T57: the card size can follow the number of windows in the session. The
/// profile is pure, so a screen and a session are not needed to check it.
final class PaletteCardScaleTests: XCTestCase {
    private let screen = CGSize(width: 1440, height: 900)

    private func metrics(_ itemCount: Int, followsCount: Bool,
                         columns: Int = 0, maxCardWidth: CGFloat = 250,
                         layout: PaletteLayout = .compact,
                         available: CGSize? = nil) -> PaletteMetrics {
        PaletteLayoutEngine.metrics(itemCount: itemCount, layout: layout,
                                    columns: columns, maxCardWidth: maxCardWidth,
                                    available: available ?? screen,
                                    sizeFollowsCount: followsCount)
    }

    // MARK: - The profile

    func testTheFactorGrowsSmallerWithTheWindowCount() {
        XCTAssertEqual(PaletteCardScale.factor(for: 0), 1)
        XCTAssertEqual(PaletteCardScale.factor(for: 1), 1)
        XCTAssertEqual(PaletteCardScale.factor(for: 2), 0.95)
        XCTAssertEqual(PaletteCardScale.factor(for: 3), 0.88)
        XCTAssertEqual(PaletteCardScale.factor(for: 4), 0.88)
        XCTAssertEqual(PaletteCardScale.factor(for: 5), 0.78)
        XCTAssertEqual(PaletteCardScale.factor(for: 8), 0.78)
        XCTAssertEqual(PaletteCardScale.factor(for: 9), 0.70)
        XCTAssertEqual(PaletteCardScale.factor(for: 40), 0.70)

        var previous: CGFloat = 1
        for count in 1...20 {
            let factor = PaletteCardScale.factor(for: count)
            XCTAssertLessThanOrEqual(factor, previous, "count \(count)")
            previous = factor
        }
    }

    func testTheFactorChangesInStepsRatherThanOnEveryWindow() {
        // A window opening or closing must not move the card by a point.
        XCTAssertEqual(PaletteCardScale.factor(for: 6), PaletteCardScale.factor(for: 7))
        XCTAssertEqual(PaletteCardScale.factor(for: 3), PaletteCardScale.factor(for: 4))
    }

    func testTheSettingOffKeepsTheUsersMaximum() {
        XCTAssertEqual(PaletteCardScale.maximumCardWidth(250, itemCount: 20, followsCount: false), 250)
        XCTAssertEqual(PaletteCardScale.maximumCardWidth(480, itemCount: 1, followsCount: false), 480)
    }

    func testTheProfileScalesDownFromTheMaximumAndNeverBelowTheFloor() {
        XCTAssertEqual(PaletteCardScale.maximumCardWidth(250, itemCount: 1, followsCount: true), 250)
        XCTAssertEqual(PaletteCardScale.maximumCardWidth(250, itemCount: 10, followsCount: true), 175,
                       accuracy: 0.001)
        XCTAssertEqual(PaletteCardScale.maximumCardWidth(90, itemCount: 10, followsCount: true),
                       PaletteCardScale.floor,
                       "a small maximum cannot push the card below the floor")
    }

    // MARK: - Compact layout

    func testOneWindowGetsALargerPreviewThanTen() {
        let one = metrics(1, followsCount: true)
        let ten = metrics(10, followsCount: true)

        XCTAssertEqual(one.columns, 1)
        XCTAssertEqual(one.cardWidth, 250, accuracy: 0.001, "the largest the maximum allows")
        XCTAssertEqual(ten.cardWidth, 175, accuracy: 0.001)
        XCTAssertGreaterThan(one.thumbnailWidth, ten.thumbnailWidth * 1.3,
                             "the difference is visible, not a couple of points")
        XCTAssertGreaterThan(one.cardHeight, ten.cardHeight)
    }

    func testWithTheSettingOffTheCountDoesNotChangeTheCard() {
        let one = metrics(1, followsCount: false)
        let ten = metrics(10, followsCount: false)
        XCTAssertEqual(one.cardWidth, ten.cardWidth, accuracy: 0.001)
    }

    func testFixedColumnsStillLetTheProfileWorkInsideTheCell() {
        let two = metrics(2, followsCount: true, columns: 2)
        let ten = metrics(10, followsCount: true, columns: 2)
        XCTAssertEqual(two.columns, 2)
        XCTAssertEqual(ten.columns, 2)
        XCTAssertEqual(two.cardWidth, 250 * 0.95, accuracy: 0.001)
        XCTAssertEqual(ten.cardWidth, 175, accuracy: 0.001)
    }

    func testTheProfileIsClampedByTheScreenAndTheFloor() {
        let small = CGSize(width: 800, height: 500)
        let crowded = metrics(20, followsCount: true, columns: 8,
                              maxCardWidth: 480, available: small)
        XCTAssertGreaterThanOrEqual(crowded.cardWidth, PaletteCardScale.floor)
        XCTAssertLessThanOrEqual(crowded.cardWidth, 480)
        XCTAssertLessThanOrEqual(crowded.panelSize.width, small.width + 0.5,
                                 "a fixed grid still fits the display it was sized for")
    }

    // MARK: - Full screen

    func testFullScreenUsesTheSameProfile() {
        let one = metrics(1, followsCount: true, maxCardWidth: 300, layout: .fullScreen)
        let ten = metrics(10, followsCount: true, maxCardWidth: 300, layout: .fullScreen)

        XCTAssertEqual(one.layout, .fullScreen)
        XCTAssertEqual(one.panelSize, screen, "full screen still fills the display")
        XCTAssertLessThanOrEqual(ten.cardWidth, 300 * 0.70 + 0.001,
                                 "the profile caps the full-screen card too")
        XCTAssertGreaterThan(one.cardWidth, ten.cardWidth)
    }
}
