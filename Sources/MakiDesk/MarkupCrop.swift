import CoreGraphics

/// Cropping the capture inside the editor (T40).
///
/// The base image is replaced by the chosen rectangle and every mark is mapped
/// into the new normalised space, so the marks stay where they were drawn
/// instead of drifting with the new origin. Pure geometry, checked without a
/// window server.
enum MarkupCrop {
    /// The cropped image and the marks moved into its coordinates.
    ///
    /// `rect` is normalised (0…1, top-left origin) like every `Markup` point.
    /// Marks completely outside the crop are dropped; the others keep their
    /// points, which can now fall slightly outside the image — the renderer's
    /// context clips them instead of bending them onto the border.
    static func crop(_ base: CGImage, marks: [Markup],
                     rect: CGRect) -> (base: CGImage, marks: [Markup]) {
        let normalized = rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard normalized.width > 0, normalized.height > 0 else { return (base, marks) }
        let pixels = CGRect(
            x: (normalized.minX * CGFloat(base.width)).rounded(.down),
            y: (normalized.minY * CGFloat(base.height)).rounded(.down),
            width: (normalized.width * CGFloat(base.width)).rounded(.up),
            height: (normalized.height * CGFloat(base.height)).rounded(.up)
        ).intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard pixels.width >= 1, pixels.height >= 1,
              let cropped = base.cropping(to: pixels) else { return (base, marks) }

        let mapped = marks.compactMap { mark -> Markup? in
            let points = mark.points.map { point in
                CGPoint(x: (point.x - normalized.minX) / normalized.width,
                        y: (point.y - normalized.minY) / normalized.height)
            }
            // A mark with nothing left in the crop would be invisible anyway.
            guard points.contains(where: { $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 }) else {
                return nil
            }
            var copy = mark
            copy.points = points
            return copy
        }
        return (cropped, mapped)
    }
}
