import XCTest
@testable import MakiDesk

/// T42: the Settings window paints itself with the palette theme. The window
/// also flips its native appearance to match how light or dark that theme is,
/// so switches, popups and the titlebar stay readable.
@MainActor
final class PaletteThemeTests: XCTestCase {
    private let lightThemeIDs: Set<String> = ["latte", "macos-light", "solarized-light"]

    func testFixedLightThemesAreClassifiedFromTheirBackground() {
        for id in lightThemeIDs {
            XCTAssertFalse(PaletteTheme.named(id).isDark, "\(id) should read as light")
        }
    }

    func testEveryOtherFixedThemeIsDark() {
        for theme in PaletteTheme.all
        where theme.id != "system" && lightThemeIDs.contains(theme.id) == false {
            XCTAssertTrue(theme.isDark, "\(theme.id) should read as dark")
        }
    }

    func testRequestedThemesAreAvailable() {
        let requested = [
            ("shades-of-purple", "Shades of Purple"),
            ("synthwave-84", "SynthWave 84"),
            ("cyberpunk", "Cyberpunk")
        ]
        for (id, name) in requested {
            let theme = PaletteTheme.named(id)
            XCTAssertEqual(theme.id, id)
            XCTAssertEqual(theme.name, name)
            XCTAssertTrue(theme.isDark)
        }
        XCTAssertTrue(PaletteTheme.named("system").followsSystemAppearance)
    }
}
