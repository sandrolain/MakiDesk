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

    /// Keeps a window's size when moving it between displays, shrinking only
    /// when the destination cannot contain the current frame.
    static func sizeFitting(_ size: CGSize, in bounds: CGRect) -> CGSize {
        CGSize(width: min(size.width, bounds.width), height: min(size.height, bounds.height))
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
    /// vertical steps only change y/height. A step that would go below a known
    /// floor is raised to it: the seven states stay seven, and a window the app
    /// will not shrink further simply stops moving instead of being asked for
    /// an impossible size.
    static func ladderRects(area: CGRect, axis: Axis,
                            orthogonal: ClosedRange<CGFloat>,
                            minimum: CGSize = .zero) -> [CGRect] {
        let low = orthogonal.lowerBound
        let span = orthogonal.upperBound - orthogonal.lowerBound
        return ladder.map { state in
            switch axis {
            case .horizontal:
                let width = min(max(state.fraction * area.width, minimum.width), area.width)
                let x = state.anchor == .start ? area.minX : area.maxX - width
                return CGRect(x: x, y: low, width: width, height: span)
            case .vertical:
                let height = min(max(state.fraction * area.height, minimum.height), area.height)
                let y = state.anchor == .start ? area.minY : area.maxY - height
                return CGRect(x: low, y: y, width: span, height: height)
            }
        }
    }

    /// The full extent of `area` on `axis`, keeping the window's current size
    /// and position across the other one. It is the ladder's fourth state
    /// (`ladder[3]`), reachable directly by holding both arrows of a pair
    /// (S03) instead of walking to it.
    static func fullSpan(of rect: CGRect, in area: CGRect, axis: Axis) -> CGRect {
        switch axis {
        case .horizontal:
            return CGRect(x: area.minX, y: rect.minY, width: area.width, height: rect.height)
        case .vertical:
            return CGRect(x: rect.minX, y: area.minY, width: rect.width, height: area.height)
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
    /// testable, unlike the previous per-axis heuristic. `minimumHeight` is the
    /// floor the ladder may not shrink below, so a window parked at the app's
    /// own minimum still reads as the low end.
    static func slot(of rect: CGRect, area: CGRect, axis: Axis, states: [CGRect],
                     minimumHeight: CGFloat = TilingEngine.minimumHeight) -> LadderSlot {
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
        // Keep every cell inside the available area, even when there are more
        // windows than fit at the preferred minimum size. Oversized frames
        // silently moved windows onto neighboring displays for large groups.
        let cellWidth = max(1, (screen.width - gap * CGFloat(columns - 1)) / CGFloat(columns))
        let cellHeight = max(1, (screen.height - gap * CGFloat(rows - 1)) / CGFloat(rows))
        return (0..<count).map { index in
            let column = index % columns
            let row = index / columns
            return CGRect(x: screen.minX + CGFloat(column) * (cellWidth + gap),
                          y: screen.minY + CGFloat(row) * (cellHeight + gap),
                          width: cellWidth, height: cellHeight)
        }
    }

    /// One preset applied to an area, with what could not be placed.
    ///
    /// `frames` is aligned with the input order; an unplaced window keeps a
    /// zero rect, so a caller can tell a deliberate omission from a frame at
    /// the origin. `fallback` says the requested preset was replaced (a
    /// treemap that could not hold a minimum becomes a grid).
    struct LayoutGeometry: Equatable {
        var frames: [CGRect] = []
        var fallback = false

        var unplacedCount: Int { frames.filter { Self.isPlaced($0) == false }.count }

        static func isPlaced(_ frame: CGRect) -> Bool {
            frame.width >= 1 && frame.height >= 1
                && frame.minX.isFinite && frame.minY.isFinite
        }
    }

    /// The frames for laying `count` windows out with a preset. The grid leaves
    /// `gap` around and between cells; the golden spiral insets each slot by
    /// `gap/2`, exactly as the keyboard auto-layout applies it.
    static func frames(for preset: LayoutPreset, count: Int, in area: CGRect, gap: CGFloat,
                       weights: [Double] = []) -> [CGRect] {
        layout(preset, count: count, in: area, gap: gap, weights: weights).frames
    }

    /// Applies a preset while honouring the size floors apps have shown.
    ///
    /// A window whose minimum cannot fit is left in place (a zero frame), and
    /// the remaining windows are laid out without it; a grid loses windows from
    /// the end, a spiral reduces its slot count, and a treemap that cannot hold
    /// every minimum falls back to the constrained grid. Everything is pure and
    /// deterministic, so the same limits always produce the same layout.
    static func layout(_ preset: LayoutPreset, count: Int, in area: CGRect, gap: CGFloat,
                       weights: [Double] = [], minimums: [CGSize] = []) -> LayoutGeometry {
        guard count > 0 else { return LayoutGeometry() }
        guard area.width > 1, area.height > 1 else {
            return LayoutGeometry(frames: Array(repeating: .zero, count: count), fallback: true)
        }
        let limits = (0..<count).map { index in
            index < minimums.count ? minimums[index] : .zero
        }
        switch preset {
        case .grid:
            return gridGeometry(count: count, in: area, gap: gap, minimums: limits)
        case .goldenSpiral:
            return spiralGeometry(count: count, in: area, gap: gap, minimums: limits)
        case .content:
            guard weights.count == count else {
                return gridGeometry(count: count, in: area, gap: gap, minimums: limits)
            }
            return contentGeometry(weights: weights, in: area, gap: gap,
                                   minimums: limits)
        }
    }

    /// Whether a frame can hold a window's known floor. A point of slack keeps
    /// a rounded readback from turning a fitting cell into a refusal.
    static func fits(_ frame: CGRect, minimum: CGSize, tolerance: CGFloat = 1) -> Bool {
        (minimum.width <= 0 || frame.width + tolerance >= minimum.width)
            && (minimum.height <= 0 || frame.height + tolerance >= minimum.height)
    }

    // MARK: - Constrained presets

    /// The grid for `count` windows, or nil when the known floors cannot fit in
    /// this area at all. Cells in one column share a width, so a wide window
    /// widens its whole column; the leftover is then shared equally.
    static func constrainedGrid(count: Int, in area: CGRect, gap: CGFloat,
                                minimums: [CGSize]) -> [CGRect]? {
        guard count > 0, area.width > 1, area.height > 1 else { return nil }
        let active = minimums.prefix(count)
        if active.allSatisfy({ $0 == .zero }) {
            return gridFrames(count: count, in: area, gap: gap)
        }

        let screen = area.insetBy(dx: gap, dy: gap)
        guard screen.width > 1, screen.height > 1 else { return nil }
        let columns = max(1, Int(ceil(sqrt(Double(count)))))
        let rows = Int(ceil(Double(count) / Double(columns)))
        let totalGapX = gap * CGFloat(columns - 1)
        let totalGapY = gap * CGFloat(rows - 1)
        var columnWidths = Array(repeating: max(1, (screen.width - totalGapX) / CGFloat(columns)),
                                 count: columns)
        var rowHeights = Array(repeating: max(1, (screen.height - totalGapY) / CGFloat(rows)),
                               count: rows)

        // A floor belongs to every cell in its column and row, so one wide
        // window widens its column; the room comes from columns that have no
        // floor, never from another window's minimum.
        var columnFloors = Array(repeating: CGFloat(1), count: columns)
        var rowFloors = Array(repeating: CGFloat(1), count: rows)
        for index in 0..<count {
            let minimum = index < minimums.count ? minimums[index] : .zero
            columnFloors[index % columns] = max(columnFloors[index % columns], minimum.width)
            rowFloors[index / columns] = max(rowFloors[index / columns], minimum.height)
        }

        /// Raises a base length to its floors, takes any overshoot from the
        /// columns or rows that have slack above their own floor, and shares
        /// what is left. Returns false when even the floors do not fit.
        func allocate(_ lengths: inout [CGFloat], floors: [CGFloat],
                      available: CGFloat, gapTotal: CGFloat) -> Bool {
            for index in lengths.indices {
                lengths[index] = max(lengths[index], floors[index])
            }
            let required = lengths.reduce(0, +) + gapTotal
            if required > available + 0.5 {
                var deficit = required - available
                let capacity = zip(lengths, floors).reduce(0.0) {
                    $0 + max(0, $1.0 - $1.1)
                }
                guard capacity >= deficit - 0.5 else { return false }
                for index in lengths.indices {
                    let take = min(max(0, lengths[index] - floors[index]), deficit)
                    lengths[index] -= take
                    deficit -= take
                    if deficit <= 0.5 { break }
                }
            }
            let leftover = max(0, available - (lengths.reduce(0, +) + gapTotal))
            if leftover > 0 {
                let share = leftover / CGFloat(lengths.count)
                for index in lengths.indices { lengths[index] += share }
            }
            return true
        }

        guard allocate(&columnWidths, floors: columnFloors,
                       available: screen.width, gapTotal: totalGapX),
              allocate(&rowHeights, floors: rowFloors,
                       available: screen.height, gapTotal: totalGapY) else { return nil }

        var xs: [CGFloat] = []
        var x = screen.minX
        for width in columnWidths {
            xs.append(x)
            x += width + gap
        }
        var ys: [CGFloat] = []
        var y = screen.minY
        for height in rowHeights {
            ys.append(y)
            y += height + gap
        }

        let frames = (0..<count).map { index in
            CGRect(x: xs[index % columns], y: ys[index / columns],
                   width: columnWidths[index % columns], height: rowHeights[index / columns])
        }
        guard zip(frames, minimums).allSatisfy({ fits($0, minimum: $1) }) else { return nil }
        return frames
    }

    private static func gridGeometry(count: Int, in area: CGRect, gap: CGFloat,
                                     minimums: [CGSize]) -> LayoutGeometry {
        for fitting in stride(from: count, through: 1, by: -1) {
            if let frames = constrainedGrid(count: fitting, in: area, gap: gap,
                                            minimums: Array(minimums.prefix(fitting))) {
                return LayoutGeometry(frames: frames + zeros(count - fitting),
                                      fallback: fitting != count)
            }
        }
        return LayoutGeometry(frames: zeros(count), fallback: true)
    }

    private static func spiralGeometry(count: Int, in area: CGRect, gap: CGFloat,
                                       minimums: [CGSize]) -> LayoutGeometry {
        let cap = min(count, maxGoldenSpiralSlots)
        var fitting = cap
        while fitting >= 1 {
            let frames = goldenSpiralSlots(area: area, count: fitting).map {
                $0.insetBy(dx: gap / 2, dy: gap / 2).integral
            }
            if frames.count == fitting,
               zip(frames, minimums).allSatisfy({ fits($0, minimum: $1) }) {
                return LayoutGeometry(frames: frames + zeros(count - fitting),
                                      fallback: fitting != cap)
            }
            fitting -= 1
        }
        return LayoutGeometry(frames: zeros(count), fallback: true)
    }

    private static func contentGeometry(weights: [Double], in area: CGRect, gap: CGFloat,
                                        minimums: [CGSize]) -> LayoutGeometry {
        let count = weights.count
        if let frames = weightedFramesFitting(weights: weights, in: area, gap: gap,
                                              minimums: minimums) {
            return LayoutGeometry(frames: frames)
        }
        // A treemap that cannot hold every minimum loses the lightest windows,
        // which the caller sorts first. If even one is impossible, a constrained
        // grid is the honest fallback: it still keeps the windows on screen.
        var fitting = count
        while fitting > 1 {
            fitting -= 1
            if let frames = weightedFramesFitting(
                weights: Array(weights.prefix(fitting)), in: area, gap: gap,
                minimums: Array(minimums.prefix(fitting))) {
                return LayoutGeometry(frames: frames + zeros(count - fitting),
                                      fallback: true)
            }
        }
        var grid = gridGeometry(count: count, in: area, gap: gap, minimums: minimums)
        grid.fallback = true
        return grid
    }

    /// The treemap with per-window floors. Areas start proportional to the
    /// weights; a window below its minimum area is raised to it, and the
    /// deficit is taken proportionally from the windows above theirs. The
    /// result is squarified, then checked on both axes, because enough area is
    /// not the same as a wide enough slot.
    private static func weightedFramesFitting(weights: [Double], in area: CGRect,
                                              gap: CGFloat,
                                              minimums: [CGSize]) -> [CGRect]? {
        let count = weights.count
        guard count > 0 else { return nil }
        let totalArea = Double(area.width * area.height)
        let minimumAreas = minimums.map { max(1.0, Double($0.width * $0.height)) }
        guard minimumAreas.reduce(0, +) <= totalArea + 1 else { return nil }

        let clean = weights.map { value -> Double in
            value.isFinite && value > 0 ? value : 0.001
        }
        let totalWeight = clean.reduce(0, +)
        guard totalWeight > 0 else { return nil }
        var areas = clean.map { totalArea * $0 / totalWeight }

        for _ in 0..<4 {
            let deficit = (0..<count).reduce(0.0) { partial, index in
                partial + max(0, minimumAreas[index] - areas[index])
            }
            if deficit <= 0.5 { break }
            for index in 0..<count where areas[index] < minimumAreas[index] {
                areas[index] = minimumAreas[index]
            }
            let above = (0..<count).reduce(0.0) { partial, index in
                partial + max(0, areas[index] - minimumAreas[index])
            }
            guard above > 0.5 else { return nil }
            for index in 0..<count where areas[index] > minimumAreas[index] {
                areas[index] -= deficit * (areas[index] - minimumAreas[index]) / above
            }
        }

        let frames = weightedFrames(weights: areas, in: area, gap: gap)
        guard frames.count == count,
              zip(frames, minimums).allSatisfy({ fits($0, minimum: $1) }) else { return nil }
        return frames
    }

    private static func zeros(_ count: Int) -> [CGRect] {
        Array(repeating: .zero, count: max(0, count))
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
