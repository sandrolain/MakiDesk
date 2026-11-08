import CoreGraphics

/// What a frame write actually produced, judged from the frame the app reports.
///
/// The point is not to retry an app into submission. A frame within an app's
/// rounding is accepted, a frame whose size never moved may still take a
/// size-first retry, and a frame the app chose itself is a refusal that another
/// identical write cannot fix. Pure, so every case is a table test.
enum FrameMismatch: Equatable {
    /// Position and size are the ones asked for, within the normal tolerance.
    case accepted
    /// Position is right and the size is off only by rounding (a character
    /// cell, a title bar). Accepted, with the frame the app really has.
    case rounded
    /// Nothing has settled yet: the frame lies between where it was and the
    /// target. Read again; do not write.
    case settling
    /// The window moved to the target position but kept its previous size.
    /// One size-first retry can still work — an app that refuses a size while
    /// it is also being moved — and a second identical answer is a floor.
    case sizeIgnored
    /// The app chose a frame that is neither the target nor an animation
    /// towards it. Writing it again would only repeat the resize.
    case refused
    /// The frame could not be read. Says nothing about the geometry.
    case unreadable

    /// A couple of points of position, as before: some apps add a point of
    /// their own chrome, and a two-point difference was never a refusal.
    static let positionTolerance: CGFloat = 2
    /// A couple of points of size are the app's own chrome, not a refusal.
    static let sizeTolerance: CGFloat = 2
    /// Apps that quantize to character cells can be this far off and still be
    /// right. This is not a licence to move a window: it applies only when the
    /// position landed.
    static let roundingTolerance: CGFloat = 20

    private static let envelopeTolerance: CGFloat = 1
    private static let betweenSlack: CGFloat = 0.5

    /// Classifies one readback. `previous` is the frame before the command,
    /// which is what tells an app that ignored the write from an app that
    /// chose its own size.
    static func classify(wanted: CGRect, previous: CGRect, actual: CGRect?) -> FrameMismatch {
        guard let actual, isPlausible(actual) else { return .unreadable }
        if matches(wanted, actual) { return .accepted }
        if positionMatches(wanted, actual) {
            if sizeWithinRounding(wanted, actual) { return .rounded }
            if sizeIsSettling(from: previous, to: wanted, actual: actual) { return .settling }
            return sizeMoved(from: previous, actual: actual) ? .refused : .sizeIgnored
        }
        return withinEnvelope(actual, from: previous, to: wanted) ? .settling : .refused
    }

    private static func isPlausible(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }

    private static func matches(_ wanted: CGRect, _ actual: CGRect) -> Bool {
        distance(wanted, actual) <= positionTolerance
            && abs(wanted.width - actual.width) <= sizeTolerance
            && abs(wanted.height - actual.height) <= sizeTolerance
    }

    private static func positionMatches(_ wanted: CGRect, _ actual: CGRect) -> Bool {
        distance(wanted, actual) <= positionTolerance
    }

    private static func sizeWithinRounding(_ wanted: CGRect, _ actual: CGRect) -> Bool {
        abs(wanted.width - actual.width) <= roundingTolerance
            && abs(wanted.height - actual.height) <= roundingTolerance
    }

    private static func distance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        max(abs(lhs.minX - rhs.minX), abs(lhs.minY - rhs.minY))
    }

    private static func sizeMoved(from previous: CGRect, actual: CGRect) -> Bool {
        abs(actual.width - previous.width) > sizeTolerance
            || abs(actual.height - previous.height) > sizeTolerance
    }

    private static func sizeIsSettling(from previous: CGRect, to wanted: CGRect,
                                       actual: CGRect) -> Bool {
        between(actual.width, previous.width, wanted.width)
            || between(actual.height, previous.height, wanted.height)
    }

    /// True when `value` lies strictly between the two ends, with a small
    /// slack so a point of rounding is not read as movement.
    private static func between(_ value: CGFloat, _ first: CGFloat, _ second: CGFloat) -> Bool {
        let low = min(first, second), high = max(first, second)
        return value > low + betweenSlack && value < high - betweenSlack
    }

    /// Every component is inside the box the command spans, previous and
    /// wanted included. An axis outside it is not an animation towards the
    /// target.
    private static func withinEnvelope(_ actual: CGRect, from previous: CGRect,
                                       to wanted: CGRect) -> Bool {
        contains(min(previous.minX, wanted.minX), max(previous.minX, wanted.minX), actual.minX)
            && contains(min(previous.minY, wanted.minY), max(previous.minY, wanted.minY), actual.minY)
            && contains(min(previous.width, wanted.width), max(previous.width, wanted.width), actual.width)
            && contains(min(previous.height, wanted.height), max(previous.height, wanted.height), actual.height)
    }

    private static func contains(_ low: CGFloat, _ high: CGFloat, _ value: CGFloat) -> Bool {
        value >= low - envelopeTolerance && value <= high + envelopeTolerance
    }
}
