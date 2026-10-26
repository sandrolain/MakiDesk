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

    struct SnapResult: Equatable {
        var rect: CGRect
        var snappedX: Bool
        var snappedY: Bool
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

    /// Keeps a selection inside one display. A drag that leaves the display is
    /// clipped, never wrapped or moved to another screen.
    static func clamped(_ rect: CGRect, to display: ScreenRegionDisplay) -> CGRect {
        let bounds = display.frame
        let minX = max(bounds.minX, rect.minX)
        let minY = max(bounds.minY, rect.minY)
        let maxX = min(bounds.maxX, rect.maxX)
        let maxY = min(bounds.maxY, rect.maxY)
        return CGRect(x: minX, y: minY,
                      width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// Pulls one side per axis to the nearest candidate edge, but only within
    /// `tolerance` and never so far that the rectangle drops below `minimum`.
    /// The closest side wins, so grabbing a window corner feels like the corner
    /// snaps and not the opposite edge.
    static func snapped(_ rect: CGRect,
                        edgesX: [CGFloat], edgesY: [CGFloat],
                        tolerance: CGFloat,
                        minimum: CGFloat = minimumSide) -> SnapResult {
        let x = snapAxis(min: rect.minX, max: rect.maxX, to: edgesX,
                         tolerance: tolerance, minimum: minimum)
        let y = snapAxis(min: rect.minY, max: rect.maxY, to: edgesY,
                         tolerance: tolerance, minimum: minimum)
        return SnapResult(rect: CGRect(x: x.min, y: y.min,
                                       width: x.max - x.min, height: y.max - y.min),
                          snappedX: x.snapped, snappedY: y.snapped)
    }

    private static func snapAxis(min low: CGFloat, max high: CGFloat,
                                 to edges: [CGFloat], tolerance: CGFloat,
                                 minimum: CGFloat) -> (min: CGFloat, max: CGFloat, snapped: Bool) {
        var best: (distance: CGFloat, edge: CGFloat, movesLow: Bool)?
        for edge in edges {
            for (value, movesLow) in [(low, true), (high, false)] {
                let distance = abs(edge - value)
                guard distance <= tolerance else { continue }
                if best == nil || distance < best!.distance {
                    best = (distance, edge, movesLow)
                }
            }
        }
        guard let best else { return (low, high, false) }
        let newLow = best.movesLow ? best.edge : low
        let newHigh = best.movesLow ? high : best.edge
        // Snapping two sides onto the same edge would collapse the rectangle.
        guard newHigh - newLow >= minimum else { return (low, high, false) }
        return (newLow, newHigh, true)
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
