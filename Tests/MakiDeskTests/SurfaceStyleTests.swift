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
}
