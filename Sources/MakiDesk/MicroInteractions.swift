import SwiftUI

/// The small interactions that make a plain control feel alive.
///
/// The app uses flat buttons in several dense panels; macOS gives them no
/// hover or press feedback of its own. A short wash is enough, and Reduce
/// Motion removes the fade without removing the state.
private struct MakiHoverWash: ViewModifier {
    let tint: Color
    let radius: CGFloat
    let isEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(hovering && isEnabled ? tint : .clear)
            }
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12),
                       value: hovering)
    }
}

extension View {
    /// A quiet wash for plain text actions and keycaps. It never changes the
    /// measured size: only the background behind the control.
    func makiHoverWash(_ tint: Color,
                       radius: CGFloat = MakiRadius.keycap,
                       isEnabled: Bool = true) -> some View {
        modifier(MakiHoverWash(tint: tint, radius: radius,
                               isEnabled: isEnabled))
    }

    /// The same idea for a control that already paints its own background:
    /// the hover is an accent hairline instead of a fill behind it.
    func makiHoverBorder(_ tint: Color,
                         radius: CGFloat = MakiRadius.control) -> some View {
        modifier(MakiHoverBorder(tint: tint, radius: radius))
    }
}

private struct MakiHoverBorder: ViewModifier {
    let tint: Color
    let radius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(hovering ? tint : .clear, lineWidth: 1)
            }
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12),
                       value: hovering)
    }
}

/// A plain button with a visible press, for the footer actions whose only
/// feedback was the action itself.
struct MakiActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
