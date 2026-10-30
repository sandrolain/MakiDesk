import CoreGraphics
import XCTest
@testable import MakiDesk

/// T40: the marks are rendered into pixels, so what the editor shows and what
/// lands on the shelf come from the same function. These check the result by
/// reading pixels, without a screen.
final class MarkupTests: XCTestCase {
    private let space = CGColorSpaceCreateDeviceRGB()

    private func image(width: Int = 100, height: Int = 100,
                       colour: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Draw one-point rectangles: the callback decides the pattern.
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = colour(x, y)
                context.setFillColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255,
                                     blue: CGFloat(b) / 255, alpha: 1)
                context.fill(CGRect(x: x, y: height - 1 - y, width: 1, height: 1))
            }
        }
        return context.makeImage()!
    }

    private func white(width: Int = 100, height: Int = 100) -> CGImage {
        image(width: width, height: height) { _, _ in (255, 255, 255) }
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let offset = ((height - 1 - y) * width + x) * 4
        return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
    }

    // MARK: - Rendering

    func testAnArrowPaintsAlongTheLine() throws {
        let base = white()
        let arrow = Markup(tool: .arrow, points: [CGPoint(x: 0.1, y: 0.5),
                                                  CGPoint(x: 0.9, y: 0.5)], colourIndex: 0)
        let result = try XCTUnwrap(MarkupRenderer.render(base, marks: [arrow]))
        let middle = pixel(result, x: 50, y: 50)
        XCTAssertGreaterThan(middle.r, 140)
        XCTAssertLessThan(middle.g, 140)
        // Well away from the line the capture is untouched.
        let corner = pixel(result, x: 5, y: 5)
        XCTAssertGreaterThan(corner.r, 245)
    }

    func testARectangleIsStrokedAndNotFilled() throws {
        let base = white()
        let rectangle = Markup(tool: .rectangle,
                               points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8)],
                               colourIndex: 0)
        let result = try XCTUnwrap(MarkupRenderer.render(base, marks: [rectangle]))
        let edge = pixel(result, x: 50, y: 20)
        XCTAssertGreaterThan(edge.r, 140)
        XCTAssertLessThan(edge.g, 140)
        let centre = pixel(result, x: 50, y: 50)
        XCTAssertGreaterThan(centre.r, 245)
        XCTAssertGreaterThan(centre.g, 245)
    }

    func testTheHighlighterLeavesWhatIsUnderneathReadable() throws {
        let base = white()
        let mark = Markup(tool: .highlighter,
                          points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)],
                          colourIndex: 1)
        let result = try XCTUnwrap(MarkupRenderer.render(base, marks: [mark]))
        let line = pixel(result, x: 50, y: 50)
        // Yellow over white: red and green stay high, blue is pulled down but
        // not to zero.
        XCTAssertGreaterThan(line.r, 200)
        XCTAssertGreaterThan(line.b, 90)
        XCTAssertLessThan(line.b, 240)
    }

    func testHidingDetailsAveragesTheBlockInsteadOfKeepingThem() throws {
        // One-pixel vertical stripes: details that a mosaic must destroy.
        let striped = image { x, _ in x % 2 == 0 ? (0, 0, 0) : (255, 255, 255) }
        let mark = Markup(tool: .pixelate,
                          points: [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.7, y: 0.7)],
                          colourIndex: 0)
        let result = try XCTUnwrap(MarkupRenderer.render(striped, marks: [mark]))
        let inside = pixel(result, x: 50, y: 50)
        XCTAssertGreaterThan(inside.r, 70)
        XCTAssertLessThan(inside.r, 185)
        // Outside the region the stripes are still stripes.
        let blackStripe = pixel(result, x: 2, y: 2)
        let whiteStripe = pixel(result, x: 3, y: 2)
        XCTAssertLessThan(blackStripe.r, 40)
        XCTAssertGreaterThan(whiteStripe.r, 215)
    }

    func testPointsOutsideTheImageAreClampedInsteadOfCrashing() throws {
        let base = white()
        let mark = Markup(tool: .pen,
                          points: [CGPoint(x: -2, y: -2), CGPoint(x: 4, y: 4)],
                          colourIndex: 2)
        XCTAssertEqual(mark.points.first, CGPoint(x: 0, y: 0))
        XCTAssertEqual(mark.points.last, CGPoint(x: 1, y: 1))
        let result = try XCTUnwrap(MarkupRenderer.render(base, marks: [mark]))
        // The line runs corner to corner: the middle of the image is on it.
        let middle = pixel(result, x: 50, y: 50)
        XCTAssertLessThan(middle.b, 250)
    }

    func testNoMarksReturnsTheCaptureAsItWas() throws {
        let base = white()
        let result = try XCTUnwrap(MarkupRenderer.render(base, marks: []))
        XCTAssertEqual(result.width, base.width)
        XCTAssertEqual(pixel(result, x: 50, y: 50).r, 255)
    }

    func testATypedLabelPaintsPixels() throws {
        let base = white(width: 240, height: 100)
        let label = Markup(tool: .text, points: [CGPoint(x: 0.06, y: 0.25)],
                           colourIndex: 3, text: "Hello")
        let result = try XCTUnwrap(MarkupRenderer.render(base, marks: [label]))
        // The label starts at the top-left anchor: some pixel down and right of
        // it must be dark, while a corner far away stays white.
        var darkest = 255
        for x in 10..<200 {
            for y in 20..<70 {
                darkest = min(darkest, pixel(result, x: x, y: y).r)
            }
        }
        XCTAssertLessThan(darkest, 120)
        XCTAssertGreaterThan(pixel(result, x: 230, y: 90).r, 245)
    }

    func testAnEmptyLabelDrawsNothing() throws {
        let base = white()
        let label = Markup(tool: .text, points: [CGPoint(x: 0.5, y: 0.5)],
                           colourIndex: 3, text: "   ".trimmingCharacters(in: .whitespaces))
        let result = try XCTUnwrap(MarkupRenderer.render(base, marks: [label]))
        XCTAssertEqual(pixel(result, x: 50, y: 50).r, 255)
    }

    // MARK: - Crop

    func testCropMovesTheMarksIntoTheNewImage() throws {
        let base = white(width: 200, height: 100)
        let mark = Markup(tool: .rectangle,
                          points: [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.75)],
                          colourIndex: 0)
        let result = MarkupCrop.crop(base, marks: [mark],
                                     rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        XCTAssertEqual(result.base.width, 100)
        XCTAssertEqual(result.base.height, 50)
        let moved = try XCTUnwrap(result.marks.first)
        XCTAssertEqual(moved.points[0].x, 0, accuracy: 0.001)
        XCTAssertEqual(moved.points[0].y, 0, accuracy: 0.001)
        XCTAssertEqual(moved.points[1].x, 1, accuracy: 0.001)
        XCTAssertEqual(moved.points[1].y, 1, accuracy: 0.001)
    }

    func testCropDropsAMarkThatIsGone() {
        let base = white()
        let outside = Markup(tool: .pen, points: [CGPoint(x: 0.05, y: 0.05),
                                                  CGPoint(x: 0.1, y: 0.1)])
        let result = MarkupCrop.crop(base, marks: [outside],
                                     rect: CGRect(x: 0.5, y: 0.5, width: 0.4, height: 0.4))
        XCTAssertEqual(result.base.width, 40)
        XCTAssertTrue(result.marks.isEmpty)
    }

    func testCropIsClippedToTheImage() {
        let base = white()
        let result = MarkupCrop.crop(base, marks: [],
                                     rect: CGRect(x: 0.5, y: 0.5, width: 2, height: 2))
        XCTAssertEqual(result.base.width, 50)
        XCTAssertEqual(result.base.height, 50)
    }

    func testAnEmptyCropChangesNothing() {
        let base = white()
        let result = MarkupCrop.crop(base, marks: [], rect: .zero)
        XCTAssertEqual(result.base.width, base.width)
        XCTAssertEqual(result.base.height, base.height)
    }

    // MARK: - Palette and names

    func testThePaletteIndexIsClamped() {
        XCTAssertEqual(MarkupPalette.clamped(-3), 0)
        XCTAssertEqual(MarkupPalette.clamped(0), 0)
        XCTAssertEqual(MarkupPalette.clamped(99), MarkupPalette.colours.count - 1)
        XCTAssertEqual(MarkupPalette.colours.map(\.name), ["Red", "Yellow", "Blue", "Black"])
    }

    func testTheFileNameSaysWhatItIs() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let name = ScreenshotNaming.name(at: date)
        XCTAssertTrue(name.hasPrefix("MakiDesk Screenshot "), name)
        XCTAssertTrue(name.hasSuffix(".png"), name)
        XCTAssertTrue(name.contains(" at "), name)
    }

    func testTheRecordingFileNameSaysWhatItIs() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let name = RecordingNaming.name(at: date)
        XCTAssertTrue(name.hasPrefix("MakiDesk Recording "), name)
        XCTAssertTrue(name.hasSuffix(".mov"), name)
    }

    func testTheLineWidthGrowsWithTheImageAndTheTool() {
        let small = CGSize(width: 400, height: 300)
        let large = CGSize(width: 3000, height: 2000)
        XCTAssertGreaterThan(MarkupRenderer.lineWidth(for: .pen, in: large),
                             MarkupRenderer.lineWidth(for: .pen, in: small))
        XCTAssertGreaterThan(MarkupRenderer.lineWidth(for: .highlighter, in: large),
                             MarkupRenderer.lineWidth(for: .pen, in: large))
        XCTAssertEqual(MarkupRenderer.lineWidth(for: .pixelate, in: large), 0)
    }
}
