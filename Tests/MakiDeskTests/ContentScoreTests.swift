import XCTest
import AppKit
@testable import MakiDesk

/// The content measure behind the golden spiral: a window full of text must
/// outrank a nearly empty one with a few hard edges. On the coarse grid this
/// used to use, a page of small text averaged away into flat grey and the
/// mostly empty window won — which is what the spiral then picked first.
final class ContentScoreTests: XCTestCase {
    private func image(width: Int, height: Int, _ body: (CGContext) -> Void) -> NSImage {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        body(context)
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: width, height: height))
    }

    private func fill(_ context: CGContext, _ gray: CGFloat) {
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
    }

    /// A dark editor window: a page of small light text lines, drawn in
    /// proportions so the same content can be rendered at any window size.
    private func textPage(width: Int, height: Int) -> NSImage {
        image(width: width, height: height) { context in
            fill(context, 0.12)
            context.setFillColor(CGColor(gray: 0.85, alpha: 1))
            let lineHeight = max(1.0, Double(height) / 84)      // ~14 pt text
            let step = lineHeight * 2.6
            let dash = lineHeight * 2.5
            var y = step
            while y < Double(height) - step {
                var x = step
                while x < Double(width) - dash {
                    context.fill(CGRect(x: x, y: y, width: dash, height: lineHeight))
                    x += dash * 1.7
                }
                y += step
            }
        }
    }

    /// A file manager window: light, with a few icons and a sidebar.
    private func sparseWindow(width: Int = 400, height: Int = 250) -> NSImage {
        image(width: width, height: height) { context in
            fill(context, 0.95)
            context.setFillColor(CGColor(gray: 0.75, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 90, height: height))
            context.setFillColor(CGColor(gray: 0.35, alpha: 1))
            for (x, y) in [(140, 170), (230, 170), (320, 170), (140, 60)] {
                context.fill(CGRect(x: x, y: y, width: 48, height: 48))
            }
        }
    }

    /// Nothing but a background.
    private func emptyWindow(width: Int = 400, height: Int = 250) -> NSImage {
        image(width: width, height: height) { context in fill(context, 0.5) }
    }

    /// What `WindowCapture` does before measuring: a screenshot capped at 400 pt
    /// on its long side, so the sampling scale depends on the window's
    /// proportions and not on how big it happens to be.
    private func captured(_ image: NSImage, maxDimension: CGFloat = 400) -> NSImage {
        let size = image.size
        let scale = min(1, maxDimension / max(size.width, size.height))
        let width = max(2, Int((size.width * scale).rounded()))
        let height = max(2, Int((size.height * scale).rounded()))
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .medium
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: width, height: height))
    }

    func testAPageOfTextOutranksASparseWindow() {
        let text = WindowCapture.edgeEnergy(captured(textPage(width: 1600, height: 1000)))
        let sparse = WindowCapture.edgeEnergy(captured(sparseWindow()))
        let empty = WindowCapture.edgeEnergy(emptyWindow())
        XCTAssertGreaterThan(text, sparse, "a full page of text must carry more detail than a few icons")
        XCTAssertGreaterThan(sparse, empty)
        XCTAssertGreaterThan(text, 4)
        XCTAssertLessThan(empty, 0.5)
    }

    func testTheSameContentScoresTheSameAtAnyWindowSize() {
        // A density measure: a small and a large window holding the same content
        // must not be ranked by their size.
        let small = WindowCapture.edgeEnergy(captured(textPage(width: 800, height: 500)))
        let large = WindowCapture.edgeEnergy(captured(textPage(width: 1600, height: 1000)))
        XCTAssertEqual(small, large, accuracy: 2, "the same content, sampled the same way")
    }

    func testAWiderSamplingSeesTextTheCoarseGridLost() {
        // The regression that mattered: on the old 48 × 32 grid a page of text
        // scored exactly zero — every sample covered a whole text line, so the
        // detail averaged away and any window with a couple of hard edges won.
        let page = captured(textPage(width: 1600, height: 1000))
        XCTAssertGreaterThan(WindowCapture.edgeEnergy(page), 4)
        XCTAssertLessThan(coarseScore(page), 1, "what the old grid saw of a full page of text")
    }

    /// The measure as it was: a 48 × 32 grid, horizontal differences only.
    private func coarseScore(_ image: NSImage) -> Double {
        let width = 48, height = 32
        var pixels = [UInt8](repeating: 0, count: width * height)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
            context.interpolationQuality = .low
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return 0 }
        var total = 0.0
        for y in 0..<height {
            for x in 1..<width {
                total += abs(Double(pixels[y * width + x]) - Double(pixels[y * width + x - 1]))
            }
        }
        return total / Double((width - 1) * height)
    }
}
