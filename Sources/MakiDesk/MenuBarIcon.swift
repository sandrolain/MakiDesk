import AppKit

/// The menu bar mark: the app icon in miniature — the golden split with the
/// maki in front — drawn as a template image so the system tints it for the
/// light and the dark menu bar.
enum MenuBarIcon {
    static func image(pointSize: CGFloat = 18) -> NSImage {
        let scale = pointSize / 44
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.saveGState()
            cg.scaleBy(x: scale, y: scale)

            // The two panes of the split: 2/3 and 1/3, with a gap between them.
            let inset: CGFloat = 4
            let gap: CGFloat = 3
            let height: CGFloat = 23
            let width: CGFloat = 44 - 2 * inset - gap
            let left = width * 0.66
            cg.setFillColor(NSColor.black.cgColor)
            cg.addPath(CGPath(roundedRect: CGRect(x: inset, y: 4, width: left, height: height),
                              cornerWidth: 4, cornerHeight: 4, transform: nil))
            cg.addPath(CGPath(roundedRect: CGRect(x: inset + left + gap, y: 4,
                                                  width: width - left, height: height),
                              cornerWidth: 4, cornerHeight: 4, transform: nil))
            cg.fillPath()

            // The roll in front: a clear ring keeps it detached from the panes,
            // so it reads as overlapping them rather than as a hole in them.
            cg.setBlendMode(.clear)
            cg.addPath(CGPath(ellipseIn: CGRect(x: 22 - 9.8, y: 31 - 9.8,
                                                width: 19.6, height: 19.6), transform: nil))
            cg.fillPath()
            cg.setBlendMode(.normal)
            cg.setFillColor(NSColor.black.cgColor)
            cg.addPath(CGPath(ellipseIn: CGRect(x: 22 - 7.6, y: 31 - 7.6,
                                                width: 15.2, height: 15.2), transform: nil))
            cg.fillPath()

            cg.restoreGState()
            return true
        }
        image.isTemplate = true
        return image
    }
}
