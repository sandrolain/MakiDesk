import AppKit
import XCTest
@testable import MakiDesk

/// The surface recipes are a design decision, not an implementation detail:
/// these tests keep Liquid Glass on chrome and floating panels and keep the
/// reading surfaces solid (analysis 2026-11-09, phase B).
final class SurfaceStyleTests: XCTestCase {
    func testLiquidGlassIsReservedForChromeAndFloatingPanels() {
        for role in MakiSurfaceRole.allCases {
            let recipe = MakiSurfaceRecipe.forRole(role)
            switch role {
            case .chrome, .floatingPanel:
                XCTAssertTrue(recipe.usesLiquidGlass, "\(role) should adopt glass")
                XCTAssertNotNil(recipe.material, "\(role) needs a macOS 14–25 material")
            case .window, .passiveCard, .overlay:
                XCTAssertFalse(recipe.usesLiquidGlass, "\(role) must stay solid")
                XCTAssertNil(recipe.material, "\(role) must stay solid")
            }
        }
    }

    func testChromeIsTheOnlyEdgeToEdgeStrip() {
        let chrome = MakiSurfaceRecipe.forRole(.chrome)
        XCTAssertEqual(chrome.cornerRadius, 0)
        if case .bottom = chrome.border {
            // The bar sits against the menu bar: no top or side hairline.
        } else {
            XCTFail("The utility bar has only a bottom hairline")
        }
        XCTAssertEqual(MakiSurfaceRecipe.forRole(.window).cornerRadius, 0)
    }

    func testPassiveCardsShareTheCardRadius() {
        XCTAssertEqual(MakiSurfaceRecipe.forRole(.passiveCard).cornerRadius,
                       MakiRadius.card)
        XCTAssertEqual(MakiSurfaceRecipe.forRole(.overlay).cornerRadius,
                       MakiRadius.card)
        XCTAssertEqual(MakiSurfaceRecipe.forRole(.floatingPanel).cornerRadius,
                       MakiRadius.panel)
    }

    /// SynthWave 84 keeps surface and background a few RGB steps apart: the
    /// derived card tone is what keeps a card visible there.
    func testRaisedSurfaceLiftsCardsInAClosePalette() throws {
        let theme = PaletteTheme.named("synthwave-84")
        let raised = try XCTUnwrap(NSColor(theme.raisedSurface).usingColorSpace(.sRGB))
        let surface = try XCTUnwrap(NSColor(theme.surface).usingColorSpace(.sRGB))
        let background = try XCTUnwrap(NSColor(theme.background).usingColorSpace(.sRGB))

        XCTAssertGreaterThan(luminance(raised), luminance(surface))
        XCTAssertGreaterThan(luminance(raised), luminance(background) + 0.02)
    }

    /// The lift must not quietly trade away readability in palettes that are
    /// already close to the contrast floor.
    func testRaisedSurfaceKeepsTheThemesTextContrast() throws {
        for theme in PaletteTheme.all where theme.followsSystemAppearance == false {
            let text = try XCTUnwrap(NSColor(theme.text).usingColorSpace(.sRGB))
            let surface = try XCTUnwrap(NSColor(theme.surface).usingColorSpace(.sRGB))
            let raised = try XCTUnwrap(NSColor(theme.raisedSurface).usingColorSpace(.sRGB))

            let before = contrast(text, surface)
            let after = contrast(text, raised)
            XCTAssertGreaterThanOrEqual(after, min(4.5, before) - 0.02,
                                        "\(theme.id) lost text contrast on cards")
        }
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let first = luminance(a)
        let second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent)
            + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }
}
