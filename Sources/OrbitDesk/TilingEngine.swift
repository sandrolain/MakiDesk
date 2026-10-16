import AppKit
import CoreGraphics

/// Geometry for placing a window on the single screen.
///
/// Positions never depend on the other windows, so commands are never blocked by
/// overlaps. All maths happens on *logical* rects; the visual gap is applied
/// afterwards by insetting the final frame.
enum TilingEngine {
    static let phi: CGFloat = (1 + sqrt(5.0)) / 2

    /// Minimum height a window can be shrunk to before the vertical ladder
    /// minimises it.
    static let minimumHeight: CGFloat = 88

    enum Axis { case horizontal, vertical }
    enum Anchor { case start, end }

    /// A region anchored to one edge, spanning the full orthogonal dimension.
    static func edgeRect(area: CGRect, axis: Axis, anchor: Anchor, fraction: CGFloat) -> CGRect {
        switch axis {
        case .horizontal:
            let width = fraction * area.width
            let x = anchor == .start ? area.minX : area.maxX - width
            return CGRect(x: x, y: area.minY, width: width, height: area.height)
        case .vertical:
            let height = fraction * area.height
            let y = anchor == .start ? area.minY : area.maxY - height
            return CGRect(x: area.minX, y: y, width: area.width, height: height)
        }
    }

    /// A sub-region given in normalised coordinates (0...1) of the area.
    static func regionRect(area: CGRect, relative: CGRect) -> CGRect {
        CGRect(x: area.minX + relative.minX * area.width,
               y: area.minY + relative.minY * area.height,
               width: relative.width * area.width,
               height: relative.height * area.height)
    }

    /// The seven ladder states on one axis, ordered as a sweep from the start
    /// edge to the end edge: start-minor, start-half, start-major, full,
    /// end-major, end-half, end-minor.
    static let ladder: [(anchor: Anchor, fraction: CGFloat)] = [
        (.start, 1 - 1 / phi),
        (.start, 0.5),
        (.start, 1 / phi),
        (.start, 1),
        (.end, 1 / phi),
        (.end, 0.5),
        (.end, 1 - 1 / phi)
    ]

    /// Ladder rects constrained to `orthogonal` (the window's current extent
    /// across the other axis), so horizontal steps only change x/width and
    /// vertical steps only change y/height.
    static func ladderRects(area: CGRect, axis: Axis, orthogonal: ClosedRange<CGFloat>) -> [CGRect] {
        let low = orthogonal.lowerBound
        let span = orthogonal.upperBound - orthogonal.lowerBound
        return ladder.map { state in
            switch axis {
            case .horizontal:
                let width = state.fraction * area.width
                let x = state.anchor == .start ? area.minX : area.maxX - width
                return CGRect(x: x, y: low, width: width, height: span)
            case .vertical:
                let height = state.fraction * area.height
                let y = state.anchor == .start ? area.minY : area.maxY - height
                return CGRect(x: low, y: y, width: span, height: height)
            }
        }
    }

    /// Index of the ladder state closest to `rect`.
    static func nearestIndex(to rect: CGRect, among rects: [CGRect]) -> Int {
        var best = 0
        var bestScore = CGFloat.greatestFiniteMagnitude
        for (index, candidate) in rects.enumerated() {
            let score = abs(candidate.minX - rect.minX) + abs(candidate.maxX - rect.maxX)
                + abs(candidate.minY - rect.minY) + abs(candidate.maxY - rect.maxY)
            if score < bestScore - 0.001 {
                bestScore = score
                best = index
            }
        }
        return best
    }
}
