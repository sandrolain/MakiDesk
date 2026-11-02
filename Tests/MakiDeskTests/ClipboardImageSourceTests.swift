import AppKit
import CoreGraphics
import XCTest
@testable import MakiDesk

@MainActor
final class ClipboardImageSourceTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: .init("MakiDeskImage-\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
    }

    // MARK: - Helpers

    private func pngData(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.systemRed.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let representation = NSBitmapImageRep(cgImage: image)
        return representation.representation(using: .png, properties: [:]) ?? Data()
    }

    private func payload() -> ClipboardImageSource.Payload? {
        guard case let .success(payload) = ClipboardImageSource.payload(from: pasteboard) else {
            return nil
        }
        return payload
    }

    // MARK: - Reading

    func testReadsPNGData() {
        XCTAssertTrue(pasteboard.setData(pngData(width: 40, height: 20), forType: .png))
        let payload = payload()
        XCTAssertNotNil(payload)
        let decoded = payload.flatMap { ClipboardImageSource.decode($0) }
        XCTAssertEqual(decoded?.image.width, 40)
        XCTAssertEqual(decoded?.image.height, 20)
    }

    func testReadsTIFFWhenThereIsNoPNG() {
        let image = NSImage(size: NSSize(width: 30, height: 10))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 30, height: 10).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation else { return XCTFail("no TIFF") }
        XCTAssertTrue(pasteboard.setData(tiff, forType: .tiff))
        XCTAssertNotNil(payload())
    }

    func testReadsJPEGData() {
        let context = CGContext(data: nil, width: 24, height: 12,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.systemGreen.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 12))
        let representation = NSBitmapImageRep(cgImage: context.makeImage()!)
        guard let jpeg = representation.representation(using: .jpeg,
                                                       properties: [.compressionFactor: 0.7]) else {
            return XCTFail("no JPEG")
        }
        XCTAssertTrue(pasteboard.setData(jpeg, forType: NSPasteboard.PasteboardType("public.jpeg")))
        XCTAssertNotNil(payload())
    }

    func testNoImageOnThePasteboard() {
        pasteboard.clearContents()
        pasteboard.setString("just text", forType: .string)
        XCTAssertEqual(ClipboardImageSource.payload(from: pasteboard), .failure(.noImage))
    }

    func testEmptyPasteboardIsNoImage() {
        XCTAssertEqual(ClipboardImageSource.payload(from: pasteboard), .failure(.noImage))
    }

    func testConcealedCopyIsRefused() {
        pasteboard.setData(pngData(width: 10, height: 10), forType: .png)
        pasteboard.setData(Data(), forType: ClipboardHistory.concealedMarker)
        XCTAssertEqual(ClipboardImageSource.payload(from: pasteboard), .failure(.concealed))
    }

    func testUnreadableDataIsRejected() {
        pasteboard.setData(Data([0, 1, 2, 3, 4]), forType: .png)
        guard let payload = payload() else { return XCTFail("no payload") }
        XCTAssertNil(ClipboardImageSource.decode(payload))
    }

    // MARK: - Downscale

    func testLargeImageIsDownscaledToTheMaximumSide() {
        XCTAssertTrue(pasteboard.setData(pngData(width: 200, height: 100), forType: .png))
        guard let payload = payload(),
              let decoded = ClipboardImageSource.decode(payload, maximumDimension: 50) else {
            return XCTFail("no image")
        }
        XCTAssertEqual(decoded.image.width, 50)
        XCTAssertEqual(decoded.image.height, 25)
    }

    func testSmallImageIsNotUpscaled() {
        XCTAssertTrue(pasteboard.setData(pngData(width: 20, height: 10), forType: .png))
        guard let payload = payload(),
              let decoded = ClipboardImageSource.decode(payload, maximumDimension: 4000) else {
            return XCTFail("no image")
        }
        XCTAssertEqual(decoded.image.width, 20)
        XCTAssertEqual(decoded.image.height, 10)
    }

    func testTallImageUsesTheLongestSide() {
        XCTAssertTrue(pasteboard.setData(pngData(width: 100, height: 400), forType: .png))
        guard let payload = payload(),
              let decoded = ClipboardImageSource.decode(payload, maximumDimension: 100) else {
            return XCTFail("no image")
        }
        XCTAssertEqual(decoded.image.height, 100)
        XCTAssertEqual(decoded.image.width, 25)
    }
}
