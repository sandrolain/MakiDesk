import CoreGraphics

/// What one window did with the frame a layout command asked for.
enum FrameOutcome: Equatable {
    case accepted(CGRect)
    case refused(CGRect?)
    case timedOut
}

/// What a whole layout command produced: how many windows took their frame, how
/// many kept their own size, and whether the result still holds together.
///
/// A layout is applied as a set, not window by window: the verdict is taken
/// after every write has answered (or the run has waited long enough), so the
/// feedback can say "5 of 6, one kept its size, no overlaps" once instead of
/// six separate messages.
struct LayoutVerdict: Equatable {
    var placed = 0
    var refused = 0
    var timedOut = 0
    /// Pairs whose actual frames overlap by more than a point on both axes.
    var overlaps = 0
    /// Pairs that should have kept the gap and came closer than it.
    var gapErosions = 0
    /// Frames that left their display's usable area by more than a point.
    var escapes = 0

    var isClean: Bool {
        refused == 0 && timedOut == 0 && overlaps == 0
            && gapErosions == 0 && escapes == 0
    }

    /// Short enough for a status line; no window titles, no app names.
    var summary: String {
        var parts: [String] = []
        if refused > 0 { parts.append("\(refused) kept size") }
        if timedOut > 0 { parts.append("\(timedOut) unconfirmed") }
        if overlaps > 0 { parts.append("\(overlaps) overlap") }
        if gapErosions > 0 { parts.append("\(gapErosions) gap") }
        if escapes > 0 { parts.append("\(escapes) outside") }
        return parts.isEmpty ? "clean" : parts.joined(separator: " · ")
    }

    /// Judges one command's outcomes. Every target carries the intended frame,
    /// its display's usable area and what the window actually did; the frame a
    /// refusal left behind is still where the window is, so it is judged too.
    static func evaluate(
        _ targets: [(intended: CGRect, area: CGRect, outcome: FrameOutcome)],
        gap: CGFloat
    ) -> LayoutVerdict {
        var verdict = LayoutVerdict()
        var actual: [(intended: CGRect, frame: CGRect, area: CGRect)] = []

        for target in targets {
            let frame: CGRect
            switch target.outcome {
            case let .accepted(value):
                frame = value
                verdict.placed += 1
            case let .refused(value):
                frame = value ?? target.intended
                verdict.refused += 1
            case .timedOut:
                frame = target.intended
                verdict.timedOut += 1
            }
            let reachable = target.area.insetBy(dx: -1, dy: -1)
            if frame.width >= 1, frame.height >= 1, reachable.contains(frame) == false {
                verdict.escapes += 1
            }
            actual.append((target.intended, frame, target.area))
        }

        for first in actual.indices {
            for second in actual.indices where second > first {
                let a = actual[first]
                let b = actual[second]
                // Frames on different displays never share a point; a point
                // intersection is rounding, not a layout problem.
                let hit = a.frame.intersection(b.frame)
                if hit.isNull == false, hit.width > 1, hit.height > 1 {
                    verdict.overlaps += 1
                } else if erodesGap(a.intended, b.intended, a.frame, b.frame, gap: gap) {
                    verdict.gapErosions += 1
                }
            }
        }
        return verdict
    }

    /// The intended frames were siblings across one axis and overlapped on the
    /// other; the actual frames came closer together than the gap allows.
    private static func erodesGap(_ intendedA: CGRect, _ intendedB: CGRect,
                                  _ actualA: CGRect, _ actualB: CGRect,
                                  gap: CGFloat) -> Bool {
        guard gap > 1 else { return false }
        let minimum = gap - 1
        let overlapX = intendedA.minX < intendedB.maxX && intendedA.maxX > intendedB.minX
        let overlapY = intendedA.minY < intendedB.maxY && intendedA.maxY > intendedB.minY

        if overlapY {
            if intendedA.maxX <= intendedB.minX {
                let actual = actualB.minX - actualA.maxX
                if actual >= -1, actual < minimum { return true }
            }
            if intendedB.maxX <= intendedA.minX {
                let actual = actualA.minX - actualB.maxX
                if actual >= -1, actual < minimum { return true }
            }
        }
        if overlapX {
            if intendedA.maxY <= intendedB.minY {
                let actual = actualB.minY - actualA.maxY
                if actual >= -1, actual < minimum { return true }
            }
            if intendedB.maxY <= intendedA.minY {
                let actual = actualA.minY - actualB.maxY
                if actual >= -1, actual < minimum { return true }
            }
        }
        return false
    }
}
