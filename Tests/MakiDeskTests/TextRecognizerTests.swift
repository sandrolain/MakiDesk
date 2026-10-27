import AppKit
import CoreText
import XCTest
@testable import MakiDesk

final class TextRecognizerTests: XCTestCase {
    func testTargetSizeKeepsSmallImagesAndDownscalesTheLongSide() {
        XCTAssertEqual(
            TextRecognitionImage.targetSize(for: CGSize(width: 1000, height: 500),
                                            maxDimension: 3000),
            CGSize(width: 1000, height: 500)
        )
        XCTAssertEqual(
            TextRecognitionImage.targetSize(for: CGSize(width: 4000, height: 1000),
                                            maxDimension: 3000),
            CGSize(width: 3000, height: 750)
        )
        XCTAssertEqual(
            TextRecognitionImage.targetSize(for: CGSize(width: 1000, height: 4000),
                                            maxDimension: 3000),
            CGSize(width: 750, height: 3000)
        )
        XCTAssertEqual(
            TextRecognitionImage.targetSize(for: CGSize(width: 3000, height: 2000),
                                            maxDimension: 3000),
            CGSize(width: 3000, height: 2000)
        )
    }

    func testPreparedImageIsScaledAtNativePixelSize() {
        let image = Self.blankImage(width: 4000, height: 100)
        let prepared = TextRecognitionImage.prepared(image, maxDimension: 3000)
        XCTAssertTrue(prepared.scaled)
        XCTAssertEqual(prepared.image.width, 3000)
        XCTAssertEqual(prepared.image.height, 75)

        let small = TextRecognitionImage.prepared(Self.blankImage(width: 800, height: 200),
                                                  maxDimension: 3000)
        XCTAssertFalse(small.scaled)
        XCTAssertEqual(small.image.width, 800)
        XCTAssertEqual(small.image.height, 200)
    }

    func testLinesAreOrderedTopToBottomThenLeftToRight() {
        let blocks: [TextRecognitionLayout.Block] = [
            .init(text: "bottom", box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05)),
            .init(text: "right", box: CGRect(x: 0.5, y: 0.8, width: 0.2, height: 0.05)),
            .init(text: "left", box: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.05)),
            .init(text: "   ", box: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.05)),
        ]
        XCTAssertEqual(TextRecognitionLayout.joined(from: blocks), "left\nright\nbottom")
    }

    func testPreviewKeepsFourLinesAndCutsLongOnes() {
        let long = String(repeating: "a", count: 140)
        let result = TextRecognitionResult(
            text: "one\n\ntwo\nthree\nfour\nfive\n\(long)",
            durationMilliseconds: 12,
            scaled: false
        )
        let lines = result.preview.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], "one")
        XCTAssertEqual(lines[1], "two")
        XCTAssertEqual(lines[2], "three")
        XCTAssertEqual(lines[3], "four")
        XCTAssertEqual(result.lineCount, 6)
        XCTAssertGreaterThan(result.characterCount, 140)

        let cut = TextRecognitionResult(text: long, durationMilliseconds: 1, scaled: false)
        XCTAssertTrue(cut.preview.hasSuffix("…"))
        XCTAssertEqual(cut.preview.count, 101)
    }

    func testVisionReadsRenderedText() async throws {
        let image = Self.renderedText("MAKIDESK OCR")
        let result = try await TextRecognizer().recognize(
            image,
            options: TextRecognitionOptions(quality: .accurate,
                                            usesLanguageCorrection: false,
                                            languages: ["en-US"])
        )
        XCTAssertTrue(result.text.uppercased().contains("MAKIDESK"),
                      "Vision returned \(result.text.debugDescription)")
        XCTAssertGreaterThan(result.characterCount, 0)
        XCTAssertFalse(result.scaled)
    }

    // MARK: - Images

    private static func blankImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private static func renderedText(_ text: String, width: Int = 1000,
                                     height: Int = 220) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 100, weight: .bold),
            .foregroundColor: NSColor.black,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        context.textPosition = CGPoint(x: 30, y: 60)
        CTLineDraw(line, context)
        return context.makeImage()!
    }
}
