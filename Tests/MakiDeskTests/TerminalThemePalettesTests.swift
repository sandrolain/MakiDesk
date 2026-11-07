import XCTest
import MakiShared
@testable import MakiDesk

final class TerminalThemePalettesTests: XCTestCase {
    func testEveryThemeHasSixteenValidColours() {
        for theme in PaletteTheme.all {
            let colours = TerminalThemePalettes.ansi(for: theme.id)
            XCTAssertEqual(colours.count, 16, theme.id)
            for colour in colours {
                XCTAssertTrue(isHex(colour), "\(theme.id): \(colour)")
            }
        }
    }

    func testTheNamedThemesReuseTheirSourcePalette() {
        XCTAssertEqual(TerminalThemePalettes.ansi(for: "plum").first, "#21222C")
        XCTAssertEqual(TerminalThemePalettes.ansi(for: "arctic").first, "#3B4252")
        XCTAssertEqual(TerminalThemePalettes.ansi(for: "midnight").first, "#15161E")
        XCTAssertEqual(TerminalThemePalettes.ansi(for: "caramel").first, "#282828")
        XCTAssertEqual(TerminalThemePalettes.ansi(for: "graphite").first, "#282C34")
    }

    func testAnUnknownThemeFallsBack() {
        XCTAssertEqual(TerminalThemePalettes.ansi(for: "nope"),
                       TerminalThemeDocument.standardANSI)
    }

    func testTheGeneratedThemeCarriesItsPalette() {
        let plum = PaletteTheme.named("plum")
        let document = TerminalThemeDocument(palette: plum)
        XCTAssertEqual(document.id, "plum")
        XCTAssertEqual(document.ansi.first, "#21222C")
    }

    private func isHex(_ value: String) -> Bool {
        value.count == 7 && value.hasPrefix("#")
            && value.dropFirst().allSatisfy { $0.isHexDigit }
    }
}
