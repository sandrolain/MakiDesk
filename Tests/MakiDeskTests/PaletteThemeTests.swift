import XCTest
@testable import MakiDesk

/// T42: the Settings window paints itself with the palette theme. The window
/// also flips its native appearance to match how light or dark that theme is,
/// so switches, popups and the titlebar stay readable.
final class PaletteThemeTests: XCTestCase {
    func testLatteIsTheOnlyLightTheme() {
        XCTAssertFalse(PaletteTheme.named("latte").isDark)
        XCTAssertEqual(PaletteTheme.all.filter(\.isDark).count, PaletteTheme.all.count - 1)
    }

    func testEveryDarkThemeIsClassifiedFromItsBackground() {
        for theme in PaletteTheme.all where theme.id != "latte" {
            XCTAssertTrue(theme.isDark, "\(theme.id) should read as dark")
        }
    }
}
