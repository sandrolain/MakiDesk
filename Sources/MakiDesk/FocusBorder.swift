import CoreGraphics

/// Geometry for the border that marks the focused window.
///
/// The values are kept apart from the panel and from the settings so the
/// placement can be checked without a window server: the panel is outset by
/// `width + 1` and the stroke hugs the window's own edge.
enum FocusBorder {
    static let widthRange: ClosedRange<Double> = 1...8
    static let defaultWidth = 3.0

    static func clampedWidth(_ value: Double) -> Double {
        min(max(value, widthRange.lowerBound), widthRange.upperBound)
    }

    /// How far the panel reaches past the window: the stroke itself plus the
    /// one-point margin that keeps the panel's own edge out of the drawing.
    static func outwardReach(_ width: Double) -> CGFloat {
        CGFloat(clampedWidth(width)) + 1
    }

    /// The panel frame in Cocoa coordinates for a window frame in AX
    /// coordinates. The caller flips the window first; this only grows it.
    static func panelFrame(for windowFrame: CGRect, width: Double) -> CGRect {
        let reach = outwardReach(width)
        return windowFrame.insetBy(dx: -reach, dy: -reach)
    }

    /// The corner radius of the stroke centreline. A small window must not
    /// turn its border into a circle.
    static func cornerRadius(for frame: CGRect, width: Double) -> CGFloat {
        let inset = CGFloat(clampedWidth(width)) / 2
        let available = max(0, min(frame.width, frame.height) / 2 - inset - 1)
        return min(11, available)
    }
}
