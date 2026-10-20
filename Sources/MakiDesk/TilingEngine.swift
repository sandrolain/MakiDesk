import AppKit
import CoreGraphics

/// The two ways MakiDesk can lay windows out, and the only ones (T18): the
/// grid gives every window an equal cell, the golden spiral gives the first
/// window the widest slot and the rest smaller ones.
///
/// A layout is never a property of a group: a group remembers the arrangement
/// the user gave its windows (T15), and a preset is applied on request, to
/// whatever is visible on screen.
enum LayoutPreset: Equatable {
    case grid
    case goldenSpiral
    /// Areas proportional to each window's weight (T30). The weights come from
    /// `weightedFrames`; without them the preset falls back to the grid.
    case content

    var label: String {
        switch self {
        case .grid: return "Grid"
        case .goldenSpiral: return "Golden spiral"
        case .content: return "Content"
        }
    }
}

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

    /// The fractions the ladder snaps to, shared with Ctrl+Opt+drag so the
    /// preview matches the frame that is finally applied.
    static let snapFractions: [CGFloat] = [1 - 1 / phi, 0.5, 1 / phi, 1.0]

    /// A position on one ladder axis: one of the seven states, or just past
    /// either end (a window shrunk to the minimum height, or pushed fully off
    /// the screen by another app). Replaces the previous geometric heuristic
    /// (A7). There is no parking state: MakiDesk never moves a window off the
    /// edge itself (T19).
    enum LadderSlot: Equatable {
        /// Just before the first state: off the start edge (horizontal) or
        /// shrunk to the minimum height (vertical).
        case beforeStart
        /// One of `TilingEngine.ladder.count` states, from the start edge in.
        case step(Int)
        /// Just after the last state: off the end edge (horizontal) or
        /// minimised (vertical).
        case afterEnd

        /// Signed position on the ladder: -1, 0…`ladder.count-1`, `ladder.count`.
        var index: Int {
            switch self {
            case .beforeStart: return -1
            case let .step(value): return value
            case .afterEnd: return TilingEngine.ladder.count
            }
        }

        init(index: Int) {
            if index < 0 {
                self = .beforeStart
            } else if index >= TilingEngine.ladder.count {
                self = .afterEnd
            } else {
                self = .step(index)
            }
        }

        /// Moves `direction` steps (-1 towards the start, +1 towards the end),
        /// clamped at both extremes.
        func advanced(by direction: Int) -> LadderSlot {
            LadderSlot(index: min(max(index + direction, -1), TilingEngine.ladder.count))
        }
    }

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

    /// The half / golden band nearest to a normalised position `t` (0 = start
    /// edge, 1 = end edge) on one axis: the edge you are closest to, and the
    /// closest of `snapFractions`. The further from an edge, the wider the band,
    /// so `t = 0.5` is full width/height. Used by the mouse drag preview so it
    /// always shows one of the same positions the keyboard can reach.
    static func edgeSlot(at t: CGFloat) -> (anchor: Anchor, fraction: CGFloat) {
        let clamped = min(max(t, 0), 1)
        let anchor: Anchor = clamped < 0.5 ? .start : .end
        let distance = min(clamped, 1 - clamped)
        let target = 2 * distance
        let fraction = snapFractions.min { abs($0 - target) < abs($1 - target) } ?? 1
        return (anchor, fraction)
    }

    /// The snap zone a window lands in when the mouse is released at `point`:
    /// the nearest horizontal × vertical half / golden band. Pure geometry so
    /// the drag overlay and the frame finally applied (with the gap inset)
    /// always agree. No edge zone parks the window (T19).
    static func dragZone(area: CGRect, point: CGPoint) -> CGRect {
        guard area.width > 0, area.height > 0 else { return area }
        let u = (point.x - area.minX) / area.width
        let horizontal = edgeSlot(at: u)
        let vertical = edgeSlot(at: (point.y - area.minY) / area.height)
        let h = edgeRect(area: area, axis: .horizontal, anchor: horizontal.anchor, fraction: horizontal.fraction)
        let v = edgeRect(area: area, axis: .vertical, anchor: vertical.anchor, fraction: vertical.fraction)
        return CGRect(x: h.minX, y: v.minY, width: h.width, height: v.height)
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

    /// Where `rect` sits on the ladder for the given axis. Explicit and
    /// testable, unlike the previous per-axis heuristic.
    static func slot(of rect: CGRect, area: CGRect, axis: Axis, states: [CGRect]) -> LadderSlot {
        switch axis {
        case .horizontal:
            if rect.midX < area.minX { return .beforeStart }
            if rect.midX >= area.maxX { return .afterEnd }
        case .vertical:
            if rect.height <= minimumHeight + 2 { return .beforeStart }
            if rect.midY >= area.maxY { return .afterEnd }
        }
        return .step(nearestIndex(to: rect, among: states))
    }

    /// Snaps `value` to the nearest ladder fraction of `total` within
    /// `tolerance`, else returns it unchanged.
    static func snapped(_ value: CGFloat, total: CGFloat, tolerance: CGFloat = 22) -> CGFloat {
        guard total > 0 else { return value }
        for fraction in snapFractions {
            let candidate = fraction * total
            if abs(value - candidate) < tolerance { return candidate }
        }
        return value
    }

    // MARK: - Auto layout geometry (T14)

    /// The most slots the golden spiral will produce: beyond this the last slots
    /// would be sliver thin, so extra windows are left where they are.
    static let maxGoldenSpiralSlots = 6

    /// The golden-spiral slots for `count` windows, up to
    /// `maxGoldenSpiralSlots`. Each step takes `1/φ` of the remaining area,
    /// alternating the cut axis, and the last slot takes whatever is left — so
    /// the area is covered exactly (the first three slots reproduce the original
    /// three-window spiral). Recursion across the remainder is what lets the
    /// spiral serve more than three windows.
    static func goldenSpiralSlots(area: CGRect, count: Int) -> [CGRect] {
        let total = min(max(count, 0), maxGoldenSpiralSlots)
        guard total > 0, area.width > 1, area.height > 1 else { return [] }
        var slots: [CGRect] = []
        var remaining = area
        var cutHorizontal = true
        for index in 0..<total {
            if index == total - 1 {
                slots.append(remaining)
                break
            }
            if cutHorizontal {
                let width = remaining.width / phi
                guard width > 1 else { break }
                slots.append(CGRect(x: remaining.minX, y: remaining.minY,
                                    width: width, height: remaining.height))
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY,
                                   width: remaining.width - width, height: remaining.height)
            } else {
                let height = remaining.height / phi
                guard height > 1 else { break }
                slots.append(CGRect(x: remaining.minX, y: remaining.minY,
                                    width: remaining.width, height: height))
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height,
                                   width: remaining.width, height: remaining.height - height)
            }
            cutHorizontal.toggle()
        }
        return slots
    }

    /// The grid frames for `count` windows tiled in `area` with a `gap` between
    /// cells and at the edges. Same maths the keyboard tiling always used, now
    /// shared so a layout can be applied to any subset.
    static func gridFrames(count: Int, in area: CGRect, gap: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let screen = area.insetBy(dx: gap, dy: gap)
        let columns = max(1, Int(ceil(sqrt(Double(count)))))
        let rows = Int(ceil(Double(count) / Double(columns)))
        let cellWidth = max(180, (screen.width - gap * CGFloat(columns - 1)) / CGFloat(columns))
        let cellHeight = max(140, (screen.height - gap * CGFloat(rows - 1)) / CGFloat(rows))
        return (0..<count).map { index in
            let column = index % columns
            let row = index / columns
            return CGRect(x: screen.minX + CGFloat(column) * (cellWidth + gap),
                          y: screen.minY + CGFloat(row) * (cellHeight + gap),
                          width: cellWidth, height: cellHeight)
        }
    }

    /// The frames for laying `count` windows out with a preset. The grid leaves
    /// `gap` around and between cells; the golden spiral insets each slot by
    /// `gap/2`, exactly as the keyboard auto-layout applies it.
    static func frames(for preset: LayoutPreset, count: Int, in area: CGRect, gap: CGFloat,
                       weights: [Double] = []) -> [CGRect] {
        switch preset {
        case .grid:
            return gridFrames(count: count, in: area, gap: gap)
        case .goldenSpiral:
            return goldenSpiralSlots(area: area, count: count).map {
                $0.insetBy(dx: gap / 2, dy: gap / 2).integral
            }
        case .content:
            if weights.count == count {
                return weightedFrames(weights: weights, in: area, gap: gap)
            }
            return gridFrames(count: count, in: area, gap: gap)
        }
    }

    /// The squarified treemap of Bruls, Huizing and van Wijk (2000): each
    /// window gets an area proportional to its weight, while rows are kept as
    /// square as the remaining space allows. Frames come back in the same order
    /// as `weights`, already inset by `gap / 2` like the golden spiral.
    ///
    /// Pure and deterministic: the input order is the tie-breaker, so the same
    /// weights always produce the same frames.
    static func weightedFrames(weights: [Double], in area: CGRect, gap: CGFloat) -> [CGRect] {
        let count = weights.count
        guard count > 0, area.width > 1, area.height > 1 else { return [] }
        if count == 1 {
            return [area.insetBy(dx: gap / 2, dy: gap / 2).integral]
        }

        let clean = weights.map { value -> Double in
            value.isFinite && value > 0 ? value : 0.001
        }
        let total = clean.reduce(0, +)
        guard total > 0 else { return [] }
        let scale = Double(area.width * area.height) / total

        struct Item {
            let index: Int
            let area: Double
        }
        var items = clean.enumerated().map { Item(index: $0.offset, area: $0.element * scale) }
        items.sort { lhs, rhs in
            if lhs.area != rhs.area { return lhs.area > rhs.area }
            return lhs.index < rhs.index
        }

        var frames = [CGRect](repeating: .zero, count: count)
        var remaining = area

        /// The worst aspect ratio of a row of items laid on `side`; the smaller,
        /// the more square the row is.
        func worst(_ row: [Int], side: Double) -> Double {
            let areas = row.map { items[$0].area }
            let sum = areas.reduce(0, +)
            guard sum > 0, let largest = areas.max(), let smallest = areas.min(),
                  smallest > 0, side > 0 else { return .infinity }
            return max((side * side * largest) / (sum * sum),
                       (sum * sum) / (side * side * smallest))
        }

        var start = 0
        while start < items.count {
            let side = Double(min(remaining.width, remaining.height))
            guard side > 1 else {
                for index in start..<items.count {
                    frames[items[index].index] = remaining
                }
                break
            }

            var row = [start]
            var end = start + 1
            while end < items.count,
                  worst(row + [end], side: side) <= worst(row, side: side) {
                row.append(end)
                end += 1
            }

            let rowArea = row.reduce(0.0) { $0 + items[$1].area }
            let horizontal = remaining.width <= remaining.height
            let thickness = min(Double(horizontal ? remaining.height : remaining.width),
                                rowArea / side)
            var offset: CGFloat = 0

            for (position, itemIndex) in row.enumerated() {
                let last = position == row.count - 1
                if horizontal {
                    let width = last
                        ? max(0, remaining.width - offset)
                        : CGFloat(items[itemIndex].area / thickness)
                    frames[items[itemIndex].index] = CGRect(
                        x: remaining.minX + offset, y: remaining.minY,
                        width: width, height: CGFloat(thickness)
                    )
                    offset += width
                } else {
                    let height = last
                        ? max(0, remaining.height - offset)
                        : CGFloat(items[itemIndex].area / thickness)
                    frames[items[itemIndex].index] = CGRect(
                        x: remaining.minX, y: remaining.minY + offset,
                        width: CGFloat(thickness), height: height
                    )
                    offset += height
                }
            }

            if horizontal {
                remaining = CGRect(x: remaining.minX, y: remaining.minY + CGFloat(thickness),
                                   width: remaining.width,
                                   height: max(0, remaining.height - CGFloat(thickness)))
            } else {
                remaining = CGRect(x: remaining.minX + CGFloat(thickness), y: remaining.minY,
                                   width: max(0, remaining.width - CGFloat(thickness)),
                                   height: remaining.height)
            }
            start = end
        }

        return frames.map { $0.insetBy(dx: gap / 2, dy: gap / 2).integral }
    }
}
