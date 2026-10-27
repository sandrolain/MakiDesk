import CoreGraphics

/// One screen, as the shared region selector sees it: a frame in AppKit global
/// coordinates (origin bottom-left of the primary display, y up) and the
/// backing scale used to turn points into pixels.
struct ScreenRegionDisplay: Equatable, Sendable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let scale: CGFloat

    /// The display's size in points, as captured: one image pixel is `scale`.
    var size: CGSize { frame.size }
}

/// Pure geometry for the shared screen-region selector (T49).
///
/// It deliberately knows nothing about `NSScreen`, ScreenCaptureKit or
/// Accessibility: callers pass plain rectangles, so the conversion and snapping
/// rules can be tested without a desktop. Two coordinate spaces appear here:
///
/// - **global**: AppKit, origin bottom-left of the primary display, y up;
/// - **display-local**: origin top-left of a display, y down. This is the space
///   the captured image uses, and it is what turns a selection into a crop.
enum ScreenRegionGeometry {
    /// A selection shorter than this on either side is a click, not a region.
    static let minimumSide: CGFloat = 4

    /// The locked edges of one axis between drag events: hysteresis keeps a
    /// side on its candidate until the pointer pulls it away (T39).
    struct SnapAxisState: Equatable, Sendable {
        var lowEdge: CGFloat?
        var highEdge: CGFloat?

        static let none = SnapAxisState()
    }

    /// Which axis a guide belongs to, for matching a frame to an edge.
    enum Axis: Sendable {
        case x
        case y
    }

    struct SnapResult: Equatable {
        var rect: CGRect
        var snappedX: Bool
        var snappedY: Bool
        /// Every candidate the two sides moved to, in global coordinates.
        var edgesX: [CGFloat]
        var edgesY: [CGFloat]
        /// The locks to pass back on the next move, so a side stays snapped.
        var stateX: SnapAxisState
        var stateY: SnapAxisState
    }

    // MARK: - Rectangles

    /// The rectangle spanned by a drag, normalized for any direction. `nil` when
    /// the drag is too small to be a selection.
    static func rect(from start: CGPoint, to end: CGPoint,
                     minimum: CGFloat = minimumSide) -> CGRect? {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        guard rect.width >= minimum, rect.height >= minimum else { return nil }
        return rect
    }

    /// The rectangle of a measuring drag, before clamping and snapping.
    /// `⇧` keeps a square (the larger side wins), `⌥` grows from the press as
    /// the centre. Pure so the gesture can be tested without a desktop (T39).
    static func measureRect(from start: CGPoint, to end: CGPoint,
                            centered: Bool = false, square: Bool = false) -> CGRect {
        var target = end
        if square {
            let dx = end.x - start.x
            let dy = end.y - start.y
            let side = max(abs(dx), abs(dy))
            target = CGPoint(x: start.x + (dx < 0 ? -side : side),
                             y: start.y + (dy < 0 ? -side : side))
        }
        if centered {
            let halfWidth = abs(target.x - start.x)
            let halfHeight = abs(target.y - start.y)
            return CGRect(x: start.x - halfWidth, y: start.y - halfHeight,
                          width: halfWidth * 2, height: halfHeight * 2)
        }
        return CGRect(x: min(start.x, target.x), y: min(start.y, target.y),
                      width: abs(target.x - start.x), height: abs(target.y - start.y))
    }

    /// Keeps a selection inside one display. A drag that leaves the display is
    /// clipped, never wrapped or moved to another screen.
    static func clamped(_ rect: CGRect, to display: ScreenRegionDisplay) -> CGRect {
        clamped(rect, to: display.frame)
    }

    static func clamped(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let minX = max(bounds.minX, rect.minX)
        let minY = max(bounds.minY, rect.minY)
        let maxX = min(bounds.maxX, rect.maxX)
        let maxY = min(bounds.maxY, rect.maxY)
        return CGRect(x: minX, y: minY,
                      width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// Rounds the two sides of `rect` to whole points before snapping: sub-pixel
    /// jitter at the tolerance boundary would otherwise make the rectangle
    /// flicker between snapped and free (T39).
    static func rounded(_ rect: CGRect) -> CGRect {
        let minX = rect.minX.rounded()
        let minY = rect.minY.rounded()
        let maxX = rect.maxX.rounded()
        let maxY = rect.maxY.rounded()
        return CGRect(x: minX, y: minY,
                      width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// The frame that owns an edge, preferring the smallest one (a window over
    /// its display) for the contextual outline (T39).
    static func frame(owningEdge value: CGFloat, axis: Axis,
                      in frames: [CGRect]) -> CGRect? {
        var best: CGRect?
        for frame in frames {
            let candidates: [CGFloat] = axis == .x
                ? [frame.minX, frame.midX, frame.maxX]
                : [frame.minY, frame.midY, frame.maxY]
            guard candidates.contains(where: { abs($0 - value) < 0.5 }) else { continue }
            let area = frame.width * frame.height
            let bestArea = best.map { $0.width * $0.height } ?? .greatestFiniteMagnitude
            if area < bestArea { best = frame }
        }
        return best
    }

    /// Pulls the moving sides to the nearest candidate, one per side, with
    /// optional hysteresis and display limits. Only moving sides snap, so the
    /// corner where the drag started cannot steal the snap and make the
    /// rectangle jump between two positions (T39). The defaults (both sides
    /// moving, no limits) keep the behaviour used by text recognition.
    static func snapped(_ rect: CGRect,
                        edgesX: [CGFloat], edgesY: [CGFloat],
                        tolerance: CGFloat,
                        minimum: CGFloat = minimumSide,
                        limits: CGRect? = nil,
                        movingX: (low: Bool, high: Bool) = (true, true),
                        movingY: (low: Bool, high: Bool) = (true, true),
                        previousX: SnapAxisState = .none,
                        previousY: SnapAxisState = .none,
                        releaseTolerance: CGFloat? = nil) -> SnapResult {
        let release = releaseTolerance ?? tolerance
        let x = snapAxis(low: rect.minX, high: rect.maxX, to: edgesX,
                         movingLow: movingX.low, movingHigh: movingX.high,
                         previous: previousX, tolerance: tolerance, release: release,
                         limits: limits.map { $0.minX...$0.maxX }, minimum: minimum)
        let y = snapAxis(low: rect.minY, high: rect.maxY, to: edgesY,
                         movingLow: movingY.low, movingHigh: movingY.high,
                         previous: previousY, tolerance: tolerance, release: release,
                         limits: limits.map { $0.minY...$0.maxY }, minimum: minimum)
        return SnapResult(
            rect: CGRect(x: x.low, y: y.low, width: x.high - x.low, height: y.high - y.low),
            snappedX: x.edges.isEmpty == false,
            snappedY: y.edges.isEmpty == false,
            edgesX: x.edges, edgesY: y.edges,
            stateX: x.state, stateY: y.state
        )
    }

    private static func snapAxis(low: CGFloat, high: CGFloat,
                                 to edges: [CGFloat],
                                 movingLow: Bool, movingHigh: Bool,
                                 previous: SnapAxisState,
                                 tolerance: CGFloat, release: CGFloat,
                                 limits: ClosedRange<CGFloat>?,
                                 minimum: CGFloat)
        -> (low: CGFloat, high: CGFloat, edges: [CGFloat], state: SnapAxisState) {
        func isAllowed(_ edge: CGFloat) -> Bool {
            guard let limits else { return true }
            return edge >= limits.lowerBound && edge <= limits.upperBound
        }
        func nearest(to value: CGFloat) -> CGFloat? {
            var best: (distance: CGFloat, edge: CGFloat)?
            for edge in edges where isAllowed(edge) {
                let distance = abs(edge - value)
                guard distance <= tolerance else { continue }
                if best == nil || distance < best!.distance { best = (distance, edge) }
            }
            return best?.edge
        }
        func side(_ raw: CGFloat, moving: Bool,
                  locked: CGFloat?) -> (value: CGFloat, edge: CGFloat?) {
            guard moving else { return (raw, nil) }
            if let locked, abs(raw - locked) <= release, isAllowed(locked) {
                return (locked, locked)
            }
            if let edge = nearest(to: raw) { return (edge, edge) }
            return (raw, nil)
        }
        let lowSide = side(low, moving: movingLow, locked: previous.lowEdge)
        let highSide = side(high, moving: movingHigh, locked: previous.highEdge)
        // Two sides on the same edge would collapse the rectangle: refuse the
        // snap instead of producing a sliver.
        guard highSide.value - lowSide.value >= minimum else {
            return (low, high, [], .none)
        }
        return (lowSide.value, highSide.value,
                [lowSide.edge, highSide.edge].compactMap { $0 }.sorted(),
                SnapAxisState(lowEdge: lowSide.edge, highEdge: highSide.edge))
    }

    /// The closest candidate within `tolerance`, for the magnetic hover
    /// preview (T39). `nil` when nothing is close enough.
    static func nearestEdge(to value: CGFloat, in edges: [CGFloat],
                            tolerance: CGFloat) -> CGFloat? {
        var best: (distance: CGFloat, edge: CGFloat)?
        for edge in edges {
            let distance = abs(edge - value)
            guard distance <= tolerance else { continue }
            if best == nil || distance < best!.distance { best = (distance, edge) }
        }
        return best?.edge
    }

    /// The press point after the magnetic guides lock on screen: the visible
    /// hover candidate becomes the anchor of the drag (T39). Candidates outside
    /// `limits` are ignored, so an off-screen window edge cannot move the
    /// anchor outside the display.
    static func snappedOrigin(_ point: CGPoint,
                              edgesX: [CGFloat], edgesY: [CGFloat],
                              tolerance: CGFloat,
                              limits: CGRect) -> (point: CGPoint,
                                                  edgeX: CGFloat?, edgeY: CGFloat?) {
        let x = nearestEdge(to: point.x,
                            in: edgesX.filter { $0 >= limits.minX && $0 <= limits.maxX },
                            tolerance: tolerance)
        let y = nearestEdge(to: point.y,
                            in: edgesY.filter { $0 >= limits.minY && $0 <= limits.maxY },
                            tolerance: tolerance)
        return (CGPoint(x: x ?? point.x, y: y ?? point.y), x, y)
    }

    /// Every vertical and horizontal line worth snapping to, sorted and unique.
    static func edges(of frames: [CGRect]) -> (x: [CGFloat], y: [CGFloat]) {
        var xs = Set<CGFloat>(), ys = Set<CGFloat>()
        for frame in frames {
            xs.insert(frame.minX); xs.insert(frame.maxX)
            ys.insert(frame.minY); ys.insert(frame.maxY)
        }
        return (xs.sorted(), ys.sorted())
    }

    // MARK: - Displays

    /// The display under a global point. Displays can leave gaps between them,
    /// so a point outside every frame falls back to the nearest one: releasing
    /// outside a screen must still produce a selection.
    static func display(containing point: CGPoint,
                        in displays: [ScreenRegionDisplay]) -> ScreenRegionDisplay? {
        if let hit = displays.first(where: { $0.frame.contains(point) }) { return hit }
        return displays.min { squaredDistance(from: point, to: $0.frame) < squaredDistance(from: point, to: $1.frame) }
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let x = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let y = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return x * x + y * y
    }

    // MARK: - Pixels

    /// A global rectangle in the display's own top-left coordinate space.
    static func displayLocalRect(_ rect: CGRect, in display: ScreenRegionDisplay) -> CGRect {
        CGRect(x: rect.minX - display.frame.minX,
               y: display.frame.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }

    /// The crop inside a captured display image.
    ///
    /// The scale is derived from the image itself rather than from
    /// `NSScreen.backingScaleFactor`: ScreenCaptureKit may round the capture to
    /// whole pixels, and a crop computed from the nominal scale would then be
    /// shifted by a pixel at the edges.
    static func pixelRect(for local: CGRect, imageSize: CGSize, displaySize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              displaySize.width > 0, displaySize.height > 0 else { return .zero }
        let scaleX = imageSize.width / displaySize.width
        let scaleY = imageSize.height / displaySize.height
        let x = min(max(0, (local.minX * scaleX).rounded()), imageSize.width)
        let y = min(max(0, (local.minY * scaleY).rounded()), imageSize.height)
        let width = min((local.width * scaleX).rounded(), imageSize.width - x)
        let height = min((local.height * scaleY).rounded(), imageSize.height - y)
        return CGRect(x: x, y: y, width: max(0, width), height: max(0, height))
    }

    // MARK: - Labels

    /// "320 × 180 pt · 640 × 360 px" on a Retina display, points only at 1×.
    static func sizeLabel(for rect: CGRect, scale: CGFloat) -> String {
        let width = Int(rect.width.rounded())
        let height = Int(rect.height.rounded())
        guard scale > 1.01 else { return "\(width) × \(height) pt" }
        let pixelWidth = Int((rect.width * scale).rounded())
        let pixelHeight = Int((rect.height * scale).rounded())
        return "\(width) × \(height) pt · \(pixelWidth) × \(pixelHeight) px"
    }
}
