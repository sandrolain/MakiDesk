import CoreGraphics

/// Where the mini map goes when the checklist card is in the way (T59).
///
/// The map keeps the corner chosen in Settings. When that corner is taken, it
/// steps **below** the card (above, for the lower corners) and only then to the
/// side, always with a margin and always inside the display, so two small
/// panels never sit on top of each other.
enum MiniMapPlacement {
    /// Air between the map and the card, and the distance that already counts
    /// as an overlap.
    static let spacing: CGFloat = 8

    static func frame(size: CGSize, position: PalettePosition, screen: CGRect,
                      avoiding obstacle: CGRect?, spacing: CGFloat = spacing) -> CGRect {
        let base = CGRect(origin: position.origin(size: size, in: screen), size: size)
        guard let obstacle, obstacle.isEmpty == false else { return base }
        let blocked = obstacle.insetBy(dx: -spacing, dy: -spacing)
        guard base.intersects(blocked) else { return base }

        // 1. Straight out of the corner: under the card, or over it for the
        //    lower corners, whichever the anchor implies.
        var frame = base
        let above = obstacle.maxY + spacing
        let below = obstacle.minY - spacing - size.height
        switch position {
        case .topLeft, .topCenter, .topRight:
            frame.origin.y = below
        case .bottomLeft, .bottomCenter, .bottomRight:
            frame.origin.y = above
        case .middleLeft, .center, .middleRight:
            frame.origin.y = below >= screen.minY ? below : above
        }
        frame = clamped(frame, in: screen, size: size)
        if frame.intersects(blocked) == false { return frame }

        // 2. Beside it, keeping the vertical anchor of the corner.
        frame = base
        let left = obstacle.minX - spacing - size.width
        let right = obstacle.maxX + spacing
        switch position {
        case .topLeft, .middleLeft, .bottomLeft:
            frame.origin.x = right
        case .topRight, .middleRight, .bottomRight:
            frame.origin.x = left
        case .topCenter, .center, .bottomCenter:
            let rightFits = right + size.width <= screen.maxX
            frame.origin.x = rightFits ? right : left
        }
        frame = clamped(frame, in: screen, size: size)
        if frame.intersects(blocked) == false { return frame }

        // 3. A card almost as large as the display: the vertical move is still
        //    the least bad answer, and it stays on the screen.
        var fallback = base
        fallback.origin.y = position.origin(size: size, in: screen).y < obstacle.minY ? below : above
        return clamped(fallback, in: screen, size: size)
    }

    private static func clamped(_ frame: CGRect, in screen: CGRect, size: CGSize) -> CGRect {
        CGRect(x: min(max(frame.minX, screen.minX), max(screen.minX, screen.maxX - size.width)),
               y: min(max(frame.minY, screen.minY), max(screen.minY, screen.maxY - size.height)),
               width: size.width,
               height: size.height)
    }
}
