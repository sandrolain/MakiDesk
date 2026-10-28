import XCTest
@testable import MakiDesk

/// T56: the app icon beside the name, with the app name a little larger than the
/// window title. The numbers are pure, so they are checked without rendering a
/// card.
final class PaletteCardLabelTests: XCTestCase {
    func testTheAppNameIsSlightlyLargerThanTheTitle() {
        for fontSize in [12.0, 14.0, 20.0] as [CGFloat] {
            let title = PaletteCardLabel.titleSize(fontSize: fontSize)
            let name = PaletteCardLabel.appNameSize(fontSize: fontSize)
            XCTAssertGreaterThan(name, title, "font \(fontSize)")
            XCTAssertLessThan(name / title, 1.2, "“slightly” larger, not a different scale")
        }
    }

    func testTheLabelGrowsWithTheCard() {
        XCTAssertGreaterThan(PaletteCardLabel.titleSize(fontSize: 20),
                             PaletteCardLabel.titleSize(fontSize: 12))
        XCTAssertGreaterThan(PaletteCardLabel.appNameSize(fontSize: 20),
                             PaletteCardLabel.appNameSize(fontSize: 12))
    }

    func testTheIconIsBoundedAndShrinksOnANarrowCard() {
        // The windowed card: 30 pt.
        XCTAssertEqual(PaletteCardLabel.iconSize(fontSize: 12, thumbnailWidth: 230), 30)
        // A full-screen card stops at 36 pt instead of growing without a limit.
        XCTAssertEqual(PaletteCardLabel.iconSize(fontSize: 20, thumbnailWidth: 400), 36)
        // A card at the floor keeps room for the name.
        XCTAssertEqual(PaletteCardLabel.iconSize(fontSize: 12, thumbnailWidth: 60), 18)
        // Never larger than the cap, never below the floor.
        for width in [60.0, 120.0, 230.0, 400.0] as [CGFloat] {
            let size = PaletteCardLabel.iconSize(fontSize: 12, thumbnailWidth: width)
            XCTAssertGreaterThanOrEqual(size, 18)
            XCTAssertLessThanOrEqual(size, 36)
        }
    }

    func testTheIconNeverEatsTheNameOnAWindowedCard() {
        let icon = PaletteCardLabel.iconSize(fontSize: 12, thumbnailWidth: 230)
        let spacing: CGFloat = 8
        XCTAssertLessThan(icon + spacing, 230 / 3,
                          "the label keeps at least two thirds of the card width")
    }
}
