import CoreGraphics
import CoreText
import Foundation

/// The quick tools of the screenshot editor (T40).
///
/// The list is deliberately short: a capture is annotated in one pass, without
/// leaving the panel, so every tool is a single drag.
enum MarkupTool: String, CaseIterable, Identifiable, Sendable {
    case arrow
    case rectangle
    case pen
    case highlighter
    case pixelate
    /// A typed label, placed with one click (T40).
    case text
    /// Not a mark: the editor's crop rectangle, applied to the capture itself.
    case crop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .pixelate: return "Hide details"
        case .text: return "Text"
        case .crop: return "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .pixelate: return "squareshape.split.3x3"
        case .text: return "textformat"
        case .crop: return "crop"
        }
    }

    /// Tools drawn between two points, rather than following the hand.
    var isTwoPoint: Bool {
        self == .arrow || self == .rectangle || self == .pixelate || self == .crop
    }

    /// Tools that turn a finished mark into pixels. Crop changes the capture
    /// instead, and text is typed rather than dragged.
    var isMark: Bool {
        self != .crop
    }
}

/// One mark, in normalised coordinates (0…1, origin at the top-left), so the
/// editor's zoom and the exported pixels cannot disagree.
struct Markup: Identifiable, Equatable, Sendable {
    let id: UUID
    var tool: MarkupTool
    var points: [CGPoint]
    var colourIndex: Int
    /// The label of the text tool; empty for every other tool.
    var text: String

    init(id: UUID = UUID(), tool: MarkupTool, points: [CGPoint], colourIndex: Int = 0,
         text: String = "") {
        self.id = id
        self.tool = tool
        self.points = points.map(Self.clamped)
        self.colourIndex = colourIndex
        self.text = text
    }

    static func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }
}

/// The colours the editor offers: a red for the eye, yellow for the
/// highlighter, blue and black.
enum MarkupPalette {
    static let colours: [(name: String, red: Double, green: Double, blue: Double)] = [
        ("Red", 0.90, 0.20, 0.22),
        ("Yellow", 0.98, 0.80, 0.16),
        ("Blue", 0.20, 0.48, 0.95),
        ("Black", 0.06, 0.06, 0.07),
    ]

    static func colour(_ index: Int, alpha: Double = 1) -> CGColor {
        let entry = colours[min(max(index, 0), colours.count - 1)]
        return CGColor(srgbRed: CGFloat(entry.red), green: CGFloat(entry.green),
                       blue: CGFloat(entry.blue), alpha: CGFloat(alpha))
    }

    static func clamped(_ index: Int) -> Int {
        min(max(index, 0), colours.count - 1)
    }
}

/// Turns the marks into pixels. The same function feeds the editor's preview
/// and the file that goes to the shelf, so what is seen is what is saved.
enum MarkupRenderer {
    static func render(_ base: CGImage, marks: [Markup]) -> CGImage? {
        let width = base.width
        let height = base.height
        guard width > 0, height > 0 else { return nil }
        // An opaques canvas: a screenshot may carry alpha, and a flattened
        // result is what every consumer (clipboard, shelf, OCR) expects.
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        for mark in marks {
            draw(mark, in: context, base: base, size: CGSize(width: width, height: height))
        }
        return context.makeImage()
    }

    /// Normalised (top-left) to the context's pixels (bottom-left origin).
    ///
    /// Points outside 0…1 are left outside instead of being pulled onto the
    /// edge: after a crop a stroke can cross the new border, and the context's
    /// own clip does the cutting without bending the line.
    static func point(_ normalized: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: normalized.x * size.width,
                y: (1 - normalized.y) * size.height)
    }

    /// The point size the text tool uses on an image of this size.
    static func textSize(in size: CGSize) -> CGFloat {
        min(max(min(size.width, size.height) * 0.03, 15), 140)
    }

    /// The stroke a tool uses on an image of this size, in pixels.
    static func lineWidth(for tool: MarkupTool, in size: CGSize) -> CGFloat {
        let base = min(size.width, size.height) * 0.0038
        switch tool {
        case .highlighter: return min(max(base * 4.2, 10), 60)
        case .pixelate: return 0
        case .crop: return 0
        default: return min(max(base, 3), 16)
        }
    }

    private static func draw(_ mark: Markup, in context: CGContext,
                             base: CGImage, size: CGSize) {
        guard mark.points.isEmpty == false else { return }
        switch mark.tool {
        case .pixelate:
            guard mark.points.count >= 2 else { return }
            pixelate(mark, in: context, base: base, size: size)
        case .rectangle:
            guard mark.points.count >= 2 else { return }
            let first = point(mark.points[0], in: size)
            let second = point(mark.points[1], in: size)
            let rect = CGRect(x: min(first.x, second.x), y: min(first.y, second.y),
                              width: abs(second.x - first.x), height: abs(second.y - first.y))
            guard rect.width > 0.5, rect.height > 0.5 else { return }
            context.setStrokeColor(MarkupPalette.colour(mark.colourIndex))
            context.setLineWidth(lineWidth(for: .rectangle, in: size))
            context.stroke(rect)
        case .arrow:
            guard mark.points.count >= 2 else { return }
            arrow(from: point(mark.points[0], in: size),
                  to: point(mark.points[1], in: size),
                  colour: mark.colourIndex, width: lineWidth(for: .arrow, in: size),
                  in: context)
        case .text:
            text(mark, in: context, size: size)
        case .crop:
            break
        case .pen, .highlighter:
            let points = mark.points.map { point($0, in: size) }
            guard points.count >= 2 else { return }
            let width = lineWidth(for: mark.tool, in: size)
            let alpha: CGFloat = mark.tool == .highlighter ? 0.45 : 1
            context.setStrokeColor(MarkupPalette.colour(mark.colourIndex, alpha: Double(alpha)))
            context.setLineWidth(width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.beginPath()
            context.move(to: points[0])
            for point in points.dropFirst() { context.addLine(to: point) }
            context.strokePath()
        }
    }

    /// The label, one line per newline, its top-left corner at the anchor.
    /// CoreText draws at a baseline, so the position is lifted by the ascent.
    private static func text(_ mark: Markup, in context: CGContext, size: CGSize) {
        guard mark.text.isEmpty == false, let anchor = mark.points.first else { return }
        let fontSize = textSize(in: size)
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let colour = MarkupPalette.colour(mark.colourIndex)
        let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        let origin = point(anchor, in: size)
        context.saveGState()
        // A soft shadow keeps the label readable over a light or a busy area.
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: fontSize * 0.12,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55))
        for (row, line) in mark.text.components(separatedBy: "\n").enumerated() {
            guard line.isEmpty == false else { continue }
            let attributed = CFAttributedStringCreate(nil, line as CFString, [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: colour,
            ] as CFDictionary)
            guard let attributed else { continue }
            let ctLine = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: origin.x,
                                           y: origin.y - CTFontGetAscent(font) - CGFloat(row) * lineHeight)
            CTLineDraw(ctLine, context)
        }
        context.restoreGState()
    }

    private static func arrow(from start: CGPoint, to end: CGPoint, colour: Int,
                              width: CGFloat, in context: CGContext) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 1 else { return }
        let angle = atan2(dy, dx)
        let head = min(max(width * 3.4, 9), 46)
        let spread = CGFloat.pi / 7
        context.setStrokeColor(MarkupPalette.colour(colour))
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.beginPath()
        context.move(to: start)
        context.addLine(to: end)
        context.move(to: end)
        context.addLine(to: CGPoint(x: end.x - head * cos(angle - spread),
                                    y: end.y - head * sin(angle - spread)))
        context.move(to: end)
        context.addLine(to: CGPoint(x: end.x - head * cos(angle + spread),
                                    y: end.y - head * sin(angle + spread)))
        context.strokePath()
    }

    /// A mosaic of the pixels already there: the details are gone, the
    /// surrounding image is untouched. Cropping and redrawing keeps it honest —
    /// no blur that can be reversed by guessing.
    private static func pixelate(_ mark: Markup, in context: CGContext,
                                 base: CGImage, size: CGSize) {
        let first = point(mark.points[0], in: size)
        let second = point(mark.points[1], in: size)
        let rect = CGRect(x: min(first.x, second.x), y: min(first.y, second.y),
                          width: abs(second.x - first.x), height: abs(second.y - first.y)).integral
        guard rect.width >= 2, rect.height >= 2 else { return }

        // CGImage crops in its own top-left space.
        let crop = CGRect(x: rect.minX, y: size.height - rect.maxY,
                          width: rect.width, height: rect.height).integral
        guard let region = base.cropping(to: crop) else { return }

        let block = min(max(min(size.width, size.height) * 0.006, 6), 26)
        let columns = max(2, Int(rect.width / block))
        let rows = max(2, Int(rect.height / block))
        guard let small = CGContext(
            data: nil, width: columns, height: rows, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        small.interpolationQuality = .high
        small.draw(region, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        guard let mosaic = small.makeImage() else { return }
        context.interpolationQuality = .none
        context.draw(mosaic, in: rect)
    }
}

/// A readable, collision-free name for the recording that goes on the shelf.
enum RecordingNaming {
    static func name(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "MakiDesk Recording \(formatter.string(from: date)).mov"
    }
}

/// A readable, collision-free name for the file that goes on the shelf.
enum ScreenshotNaming {
    static func name(at date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "MakiDesk Screenshot \(formatter.string(from: date)).png"
    }
}
