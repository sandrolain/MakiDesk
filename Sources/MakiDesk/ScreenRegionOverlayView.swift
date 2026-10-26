import AppKit

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
    var hintText: String? {
        didSet { needsDisplay = true }
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
    private var trackingArea: NSTrackingArea?

    private let dimAlpha: CGFloat = 0.45
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
            drawSelectionBorder(selection)
            drawHandles(selection)
            drawSizeLabel(selection)
        } else {
            dim.setFill()
            bounds.fill()
            drawHint()
        }

        drawCrosshair()
        drawLoupe()
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
        let size = text.size(withAttributes: attributes)
        let padding = CGSize(width: 7, height: 4)
        var origin = CGPoint(x: rect.minX, y: rect.maxY + 10)
        if origin.y + size.height + padding.height * 2 > bounds.maxY - 8 {
            origin.y = rect.minY - 10 - size.height - padding.height * 2
        }
        origin.x = max(8, min(origin.x, bounds.maxX - size.width - padding.width * 2 - 8))
        origin.y = max(8, origin.y)

        let background = CGRect(x: origin.x, y: origin.y,
                                width: size.width + padding.width * 2,
                                height: size.height + padding.height * 2)
        let pill = NSBezierPath(roundedRect: background,
                                xRadius: background.height / 2, yRadius: background.height / 2)
        NSColor.black.withAlphaComponent(0.62).setFill()
        pill.fill()
        accentColor.withAlphaComponent(0.9).setStroke()
        pill.lineWidth = 1
        pill.stroke()
        text.draw(at: CGPoint(x: origin.x + padding.width, y: origin.y + padding.height),
                  withAttributes: attributes)
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
    }
}
