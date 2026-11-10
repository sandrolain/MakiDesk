import SwiftUI

/// The surface roles MakiDesk paints, and the recipe each one follows.
///
/// A recipe is not a theme. Colours still come from `PaletteTheme`; a recipe
/// states how a surface is built — corner radius, border, and whether the
/// system may supply the fill — so two cards meant to look alike cannot drift
/// apart one modifier at a time (analysis 2026-11-09, phase B).
enum MakiSurfaceRole: CaseIterable {
    /// A regular window whose content is painted edge to edge.
    case window
    /// Navigation chrome and floating controls: the utility bar.
    case chrome
    /// An interactive panel placed over other apps: the command box.
    case floatingPanel
    /// A read-only card: the checklist and the timers.
    case passiveCard
    /// A compact card above the desktop that must stay legible: the timer
    /// overlay. Kept solid even under the System theme.
    case overlay
}

/// The radii the app is allowed to use. Small controls, fields, cards and
/// panels were each being given a different number by each caller.
enum MakiRadius {
    static let control: CGFloat = 6
    static let field: CGFloat = 7
    static let card: CGFloat = 12
    static let panel: CGFloat = 14
}

/// How one surface is drawn. `material` and `usesLiquidGlass` are only
/// consulted for the System theme without Reduce Transparency; every other
/// case gets the theme fill, which is deterministic and readable.
struct MakiSurfaceRecipe {
    enum Material {
        case bar
        case regular
    }

    enum Border {
        case all
        case bottom
        case none
    }

    let cornerRadius: CGFloat
    let border: Border
    let borderOpacity: Double
    let material: Material?
    let usesLiquidGlass: Bool

    static func forRole(_ role: MakiSurfaceRole) -> MakiSurfaceRecipe {
        switch role {
        case .window:
            return MakiSurfaceRecipe(cornerRadius: 0, border: .none, borderOpacity: 0,
                                     material: nil, usesLiquidGlass: false)
        case .chrome:
            // A full-width strip has no corners and only a bottom hairline.
            return MakiSurfaceRecipe(cornerRadius: 0, border: .bottom, borderOpacity: 0.7,
                                     material: .bar, usesLiquidGlass: true)
        case .floatingPanel:
            return MakiSurfaceRecipe(cornerRadius: MakiRadius.panel, border: .all,
                                     borderOpacity: 0.6, material: .regular,
                                     usesLiquidGlass: true)
        case .passiveCard, .overlay:
            return MakiSurfaceRecipe(cornerRadius: MakiRadius.card, border: .all,
                                     borderOpacity: 0.6, material: nil,
                                     usesLiquidGlass: false)
        }
    }
}

extension View {
    /// Builds this view's surface with the recipe for `role`.
    ///
    /// Custom palettes stay opaque and keep their exact colours. The System
    /// theme borrows a system material — Liquid Glass on macOS 26 and later —
    /// so the chrome can look native without simulating it by hand.
    /// Reduce Transparency always wins and gets an opaque fill.
    func makiSurface(_ role: MakiSurfaceRole,
                     theme: PaletteTheme,
                     fill: Color,
                     borderOpacity: Double? = nil) -> some View {
        modifier(MakiSurfaceModifier(role: role, theme: theme, fill: fill,
                                     borderOpacity: borderOpacity))
    }

    /// The inset surface of a text field: the shared field radius and a
    /// hairline that keeps the control visible against a card, with the
    /// accent when the field owns the keyboard.
    func makiField(theme: PaletteTheme, focused: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: MakiRadius.field,
                                     style: .continuous)
        let border = focused
            ? theme.accent.opacity(0.8)
            : theme.border.opacity(0.45)
        return background(shape.fill(theme.background.opacity(0.55)))
            .overlay(shape.strokeBorder(border, lineWidth: 1))
    }
}

private struct MakiSurfaceModifier: ViewModifier {
    let role: MakiSurfaceRole
    let theme: PaletteTheme
    let fill: Color
    let borderOpacity: Double?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let recipe = MakiSurfaceRecipe.forRole(role)
        let shape = RoundedRectangle(cornerRadius: recipe.cornerRadius,
                                     style: .continuous)
        // Increase Contrast asks for visible edges; it must not wait for a
        // border colour that is already too close to the fill.
        let base = borderOpacity ?? recipe.borderOpacity
        let opacity = min(1, base + (contrast == .increased ? 0.25 : 0))
        let borders = theme.border.opacity(opacity)
        let prefersTranslucency = theme.followsSystemAppearance
            && reduceTransparency == false

        if #available(macOS 26.0, *), prefersTranslucency,
           recipe.usesLiquidGlass {
            // Liquid Glass is applied to the surface itself, the documented
            // shape: no hand-built blur and no transparent colour pretending
            // to be glass.
            content
                .glassEffect(.regular, in: shape)
                .overlay { border(recipe.border, in: shape, color: borders) }
        } else {
            content
                .background {
                    if prefersTranslucency {
                        systemFill(recipe: recipe, shape: shape)
                    } else {
                        shape.fill(fill)
                    }
                }
                .overlay { border(recipe.border, in: shape, color: borders) }
        }
    }

    @ViewBuilder
    private func systemFill(recipe: MakiSurfaceRecipe,
                            shape: RoundedRectangle) -> some View {
        if let material = recipe.material {
            switch material {
            case .bar:
                shape.fill(.bar)
            case .regular:
                shape.fill(.regularMaterial)
            }
        } else {
            shape.fill(fill)
        }
    }

    @ViewBuilder
    private func border(_ border: MakiSurfaceRecipe.Border,
                        in shape: RoundedRectangle,
                        color: Color) -> some View {
        switch border {
        case .all:
            shape.strokeBorder(color, lineWidth: 1)
        case .bottom:
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle().fill(color).frame(height: 1)
            }
        case .none:
            EmptyView()
        }
    }
}
