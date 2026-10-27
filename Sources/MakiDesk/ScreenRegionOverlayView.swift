import AppKit

/// Where the magnetic guides are, in the overlay's local coordinates (T39).
struct SnapGuides: Equatable {
    /// Every snapped side, one full-screen line each.
    var xs: [CGFloat] = []
    var ys: [CGFloat] = []
    /// The window that produced a snap: its other sides are drawn faintly.
    var context: CGRect?
    static let none = SnapGuides()
}

/// One screen's overlay in the shared region selector (T49): dims the screen,
/// draws the crosshair, the selection rectangle with its size, and a loupe fed
/// by the still capture.
///
/// The view only reports pointer positions in its own coordinates; all the
/// geometry lives in `ScreenRegionGeometry` and all the state in
/// `ScreenRegionSelector`, so this file stays a drawing surface.
@MainActor
final class ScreenRegionOverlayView: NSView {
    var accentColor: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }
    var showsLoupe = true {
        didSet { needsDisplay = true }
    }
    /// The colour picker shows the sampled colour next to the loupe (T36).
    var showsColorPreview = false {
        didSet { needsDisplay = true }
    }
    var hintText: String? {
        didSet { needsDisplay = true }
    }
    /// How dark the overlay makes the screen; the ruler asks for a lighter dim.
    var dimAlpha: CGFloat = 0.45 {
        didSet { needsDisplay = true }
    }
    /// Full-height/full-width guides at the snapped edges, set while dragging.
    var snapGuides = SnapGuides.none {
        didSet { if oldValue != snapGuides { needsDisplay = true } }
    }

    var onPointerMoved: ((CGPoint) -> Void)?
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?
    var onCancel: (() -> Void)?

    private(set) var pointer: CGPoint?
    private(set) var selection: CGRect?
    private var selectionLabel: String?
    private var snapshot: CGImage?
    private var snapshotDisplaySize: CGSize = .zero
    private var sampledPixel: (x: Int, y: Int)?
    private var sampledColor: SampledColor?
    private var trackingArea: NSTrackingArea?

    private let loupeSide: CGFloat = 112
    private let loupeMargin: CGFloat = 14
    /// How many points around the pointer the loupe magnifies.
    private let loupeSourcePoints: CGFloat = 15

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - State from the controller

    func setPointer(_ point: CGPoint?) {
        guard pointer != point else { return }
        pointer = point
        needsDisplay = true
    }

    func setSelection(_ rect: CGRect?, label: String?) {
        guard selection != rect || selectionLabel != label else { return }
        selection = rect
        selectionLabel = label
        needsDisplay = true
    }

    func setSnapshot(_ image: CGImage?, displaySize: CGSize) {
        snapshot = image
        snapshotDisplaySize = displaySize
        sampledPixel = nil
        sampledColor = nil
        needsDisplay = true
    }

    // MARK: - Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseExited(with event: NSEvent) {
        guard selection == nil else { return }
        setPointer(nil)
        snapGuides = .none
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setPointer(point)
        onPointerMoved?(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setPointer(point)
        onMouseDown?(point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setPointer(point)
        onMouseDragged?(point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onMouseUp?(point)
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        // Esc, and nothing else: the overlay is a modal selection, not an app.
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(dimAlpha)
        if let selection, selection.width > 0.5, selection.height > 0.5 {
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(rect: selection))
            path.windingRule = .evenOdd
            dim.setFill()
            path.fill()
            drawSnapGuides(selection)
            drawSelectionBorder(selection)
            drawHandles(selection)
            drawSizeLabel(selection)
        } else {
            dim.setFill()
            bounds.fill()
            drawSnapGuides(nil)
            drawHint()
        }

        drawCrosshair()
        drawLoupe()
    }

    /// A dashed accent line for every snapped side and a magnet dot on it. The
    /// window that produced the snap contributes a faint outline of its other
    /// sides. Without a selection this is the hover preview (T39).
    private func drawSnapGuides(_ selection: CGRect?) {
        if let context = snapGuides.context {
            drawContextOutline(context)
        }
        for x in snapGuides.xs where x >= bounds.minX - 1 && x <= bounds.maxX + 1 {
            drawGuideLine(from: CGPoint(x: x, y: bounds.minY),
                          to: CGPoint(x: x, y: bounds.maxY))
            if let selection {
                drawSnapDot(at: CGPoint(x: x, y: selection.midY))
            } else if let pointer {
                drawSnapDot(at: CGPoint(x: x, y: pointer.y))
            }
        }
        for y in snapGuides.ys where y >= bounds.minY - 1 && y <= bounds.maxY + 1 {
            drawGuideLine(from: CGPoint(x: bounds.minX, y: y),
                          to: CGPoint(x: bounds.maxX, y: y))
            if let selection {
                drawSnapDot(at: CGPoint(x: selection.midX, y: y))
            } else if let pointer {
                drawSnapDot(at: CGPoint(x: pointer.x, y: y))
            }
        }
    }

    /// A thin, faint outline of the snapped window; the primary bright lines
    /// cover the sides that actually snapped.
    private func drawContextOutline(_ rect: CGRect) {
        let line = NSBezierPath()
        line.lineWidth = 1
        line.setLineDash([2, 5], count: 2, phase: 0)
        let top = min(rect.maxY, bounds.maxY)
        let bottom = max(rect.minY, bounds.minY)
        let left = max(rect.minX, bounds.minX)
        let right = min(rect.maxX, bounds.maxX)
        guard right > left, top > bottom else { return }
        for x in [rect.minX, rect.maxX]
        where snapGuides.xs.allSatisfy({ abs($0 - x) >= 0.5 }) && x >= bounds.minX && x <= bounds.maxX {
            line.move(to: CGPoint(x: x, y: bottom))
            line.line(to: CGPoint(x: x, y: top))
        }
        for y in [rect.minY, rect.maxY]
        where snapGuides.ys.allSatisfy({ abs($0 - y) >= 0.5 }) && y >= bounds.minY && y <= bounds.maxY {
            line.move(to: CGPoint(x: left, y: y))
            line.line(to: CGPoint(x: right, y: y))
        }
        accentColor.withAlphaComponent(0.34).setStroke()
        line.stroke()
    }

    private func drawGuideLine(from start: CGPoint, to end: CGPoint) {
        let glow = NSBezierPath()
        glow.move(to: start)
        glow.line(to: end)
        glow.lineWidth = 3
        accentColor.withAlphaComponent(0.22).setStroke()
        glow.stroke()

        let line = NSBezierPath()
        line.move(to: start)
        line.line(to: end)
        line.lineWidth = 1
        line.setLineDash([5, 4], count: 2, phase: 0)
        accentColor.withAlphaComponent(0.95).setStroke()
        line.stroke()
    }

    private func drawSnapDot(at point: CGPoint) {
        let dot = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
        accentColor.setFill()
        NSBezierPath(ovalIn: dot).fill()
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: dot.insetBy(dx: 2.5, dy: 2.5)).fill()
    }

    private func drawCrosshair() {
        guard let pointer else { return }
        let color = NSColor.white.withAlphaComponent(0.55)
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: CGPoint(x: bounds.minX, y: pointer.y))
        path.line(to: CGPoint(x: bounds.maxX, y: pointer.y))
        path.move(to: CGPoint(x: pointer.x, y: bounds.minY))
        path.line(to: CGPoint(x: pointer.x, y: bounds.maxY))
        path.stroke()
    }

    private func drawSelectionBorder(_ rect: CGRect) {
        let border = NSBezierPath(rect: rect.insetBy(dx: 0.75, dy: 0.75))
        border.lineWidth = 1.5
        accentColor.setStroke()
        border.stroke()

        // A hairline of white under the accent keeps the edge readable on a
        // light desktop and over a dark one.
        let underlay = NSBezierPath(rect: rect.insetBy(dx: 1.5, dy: 1.5))
        underlay.lineWidth = 1
        NSColor.white.withAlphaComponent(0.55).setStroke()
        underlay.stroke()
    }

    private func drawHandles(_ rect: CGRect) {
        let side: CGFloat = 7
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)
        ]
        for corner in corners {
            let handle = CGRect(x: corner.x - side / 2, y: corner.y - side / 2,
                                width: side, height: side)
            let path = NSBezierPath(roundedRect: handle, xRadius: 1.5, yRadius: 1.5)
            NSColor.white.setFill()
            path.fill()
            accentColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func drawSizeLabel(_ rect: CGRect) {
        guard let selectionLabel, selectionLabel.isEmpty == false else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let text = selectionLabel as NSString
        // The ruler's label has three lines; short selections keep one.
        let bounding = text.boundingRect(
            with: CGSize(width: 360, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let size = CGSize(width: ceil(bounding.width), height: ceil(bounding.height))
        let padding = CGSize(width: 8, height: 5)
        var origin = CGPoint(x: rect.minX, y: rect.maxY + 10)
        if origin.y + size.height + padding.height * 2 > bounds.maxY - 8 {
            origin.y = rect.minY - 10 - size.height - padding.height * 2
        }
        origin.x = max(8, min(origin.x, bounds.maxX - size.width - padding.width * 2 - 8))
        origin.y = max(8, origin.y)

        let background = CGRect(x: origin.x, y: origin.y,
                                width: size.width + padding.width * 2,
                                height: size.height + padding.height * 2)
        let radius = min(8, background.height / 2)
        let pill = NSBezierPath(roundedRect: background,
                                xRadius: radius, yRadius: radius)
        NSColor.black.withAlphaComponent(0.62).setFill()
        pill.fill()
        accentColor.withAlphaComponent(0.9).setStroke()
        pill.lineWidth = 1
        pill.stroke()
        text.draw(with: CGRect(x: origin.x + padding.width, y: origin.y + padding.height,
                               width: size.width, height: size.height),
                  options: [.usesLineFragmentOrigin, .usesFontLeading],
                  attributes: attributes)
    }

    private func drawHint() {
        guard let hintText, hintText.isEmpty == false else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92)
        ]
        let text = hintText as NSString
        let size = text.size(withAttributes: attributes)
        let padding = CGSize(width: 12, height: 7)
        let width = size.width + padding.width * 2
        let height = size.height + padding.height * 2
        let rect = CGRect(x: bounds.midX - width / 2, y: bounds.maxY - height - 46,
                          width: width, height: height)
        let pill = NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2)
        NSColor.black.withAlphaComponent(0.55).setFill()
        pill.fill()
        text.draw(at: CGPoint(x: rect.minX + padding.width, y: rect.minY + padding.height),
                  withAttributes: attributes)
    }

    private func drawLoupe() {
        guard showsLoupe, let pointer, let snapshot,
              snapshotDisplaySize.width > 0, snapshotDisplaySize.height > 0 else { return }

        let scaleX = CGFloat(snapshot.width) / snapshotDisplaySize.width
        let scaleY = CGFloat(snapshot.height) / snapshotDisplaySize.height
        // Image rows go top-down while the view is bottom-up.
        let centerX = pointer.x * scaleX
        let centerY = (bounds.maxY - pointer.y) * scaleY
        let sourceWidth = loupeSourcePoints * scaleX
        let sourceHeight = loupeSourcePoints * scaleY
        let imageBounds = CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height)
        let source = CGRect(x: centerX - sourceWidth / 2, y: centerY - sourceHeight / 2,
                            width: sourceWidth, height: sourceHeight).integral
            .intersection(imageBounds)
        guard source.width >= 1, source.height >= 1,
              let crop = snapshot.cropping(to: source) else { return }

        var origin = CGPoint(x: pointer.x + 18, y: pointer.y + 18)
        if origin.x + loupeSide > bounds.maxX - loupeMargin { origin.x = pointer.x - 18 - loupeSide }
        if origin.y + loupeSide > bounds.maxY - loupeMargin { origin.y = pointer.y - 18 - loupeSide }
        origin.x = max(loupeMargin, min(origin.x, bounds.maxX - loupeSide - loupeMargin))
        origin.y = max(loupeMargin, min(origin.y, bounds.maxY - loupeSide - loupeMargin))
        let rect = CGRect(origin: origin, size: CGSize(width: loupeSide, height: loupeSide))

        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        clip.addClip()
        NSColor.black.setFill()
        rect.fill()
        NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))
            .draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                  respectFlipped: false,
                  hints: [.interpolation: NSImageInterpolation.none])
        NSGraphicsContext.restoreGraphicsState()

        let frame = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: 10, yRadius: 10)
        accentColor.setStroke()
        frame.lineWidth = 1
        frame.stroke()

        // Center mark: where the sample is taken from.
        let mark = NSBezierPath()
        mark.lineWidth = 1
        NSColor.white.withAlphaComponent(0.85).setStroke()
        mark.move(to: CGPoint(x: rect.midX - 5, y: rect.midY))
        mark.line(to: CGPoint(x: rect.midX + 5, y: rect.midY))
        mark.move(to: CGPoint(x: rect.midX, y: rect.midY - 5))
        mark.line(to: CGPoint(x: rect.midX, y: rect.midY + 5))
        mark.stroke()

        if showsColorPreview,
           let color = colorUnderPointer(centerX: centerX, centerY: centerY) {
            drawColorPreview(below: rect, color: color)
        }
    }

    /// The exact pixel under the pointer, cached by position: the loupe redraws
    /// on every mouse move.
    private func colorUnderPointer(centerX: CGFloat, centerY: CGFloat) -> SampledColor? {
        guard let snapshot else { return nil }
        let x = min(max(0, Int(centerX)), max(0, snapshot.width - 1))
        let y = min(max(0, Int(centerY)), max(0, snapshot.height - 1))
        if let sampledPixel, sampledPixel.x == x, sampledPixel.y == y {
            return sampledColor
        }
        guard let pixel = snapshot.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let color = SampledColor(image: pixel) else { return nil }
        sampledPixel = (x, y)
        sampledColor = color
        return color
    }

    /// A square with the sampled colour and its hex value, beside the loupe.
    private func drawColorPreview(below loupe: CGRect, color: SampledColor) {
        let side: CGFloat = 26
        let gap: CGFloat = 6
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let text = color.hex as NSString
        let textSize = text.size(withAttributes: attributes)
        let width = min(bounds.width - loupeMargin * 2, side + gap + textSize.width + 12)
        var y = loupe.minY - side - 8
        if y < loupeMargin { y = loupe.maxY + 8 }
        let bar = CGRect(x: loupe.minX, y: y, width: width, height: side)

        NSColor.black.withAlphaComponent(0.68).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 7, yRadius: 7).fill()

        let swatch = CGRect(x: bar.minX + 4, y: bar.minY + 4, width: side - 8, height: side - 8)
        NSColor(srgbRed: CGFloat(color.red) / 255,
                green: CGFloat(color.green) / 255,
                blue: CGFloat(color.blue) / 255,
                alpha: 1).setFill()
        NSBezierPath(roundedRect: swatch, xRadius: 3, yRadius: 3).fill()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let edge = NSBezierPath(roundedRect: swatch.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 3, yRadius: 3)
        edge.lineWidth = 1
        edge.stroke()

        text.draw(at: CGPoint(x: swatch.maxX + gap,
                              y: bar.midY - textSize.height / 2),
                  withAttributes: attributes)
    }
}
