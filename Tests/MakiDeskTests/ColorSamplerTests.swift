import CoreGraphics
import XCTest
@testable import MakiDesk

/// T36: decoding one screen pixel and copying it in the chosen format.
final class ColorSamplerTests: XCTestCase {
    private func image(red: UInt8, green: UInt8, blue: UInt8) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255,
                             blue: CGFloat(blue) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return context.makeImage()!
    }

    // MARK: - Formats

    func testFormatsFromAKnownColour() {
        let color = SampledColor(red: 0x12, green: 0x34, blue: 0x56)
        XCTAssertEqual(color.hex, "#123456")
        XCTAssertEqual(color.hexWithAlpha, "#123456FF")
        XCTAssertEqual(color.rgb, "rgb(18, 52, 86)")
        XCTAssertEqual(color.nsColor,
                       "NSColor(srgbRed: 0.071, green: 0.204, blue: 0.337, alpha: 1.000)")
        XCTAssertEqual(ColorClipboardFormat.hex.string(for: color), "#123456")
        XCTAssertEqual(ColorClipboardFormat.rgb.string(for: color), "rgb(18, 52, 86)")
        XCTAssertEqual(ColorClipboardFormat.hexWithAlpha.string(for: color), "#123456FF")
        XCTAssertEqual(ColorClipboardFormat.nsColor.string(for: color), color.nsColor)
    }

    func testReadingAPixelThroughSRGBAveragesTheCrop() throws {
        let color = try XCTUnwrap(SampledColor(image: image(red: 0x12, green: 0x34, blue: 0x56)))
        // sRGB to sRGB is an identity apart from 8-bit rounding.
        XCTAssertLessThanOrEqual(abs(Int(color.red) - 0x12), 1)
        XCTAssertLessThanOrEqual(abs(Int(color.green) - 0x34), 1)
        XCTAssertLessThanOrEqual(abs(Int(color.blue) - 0x56), 1)
        XCTAssertEqual(color.alpha, 255)
    }

    func testStoredFormatFallsBackToHexForAnUnknownValue() {
        let suite = "MakiDeskColorFormat-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ColorSamplerController.storedFormat(defaults: defaults), .hex)
        defaults.set("printer", forKey: ColorSamplerController.formatDefaultsKey)
        XCTAssertEqual(ColorSamplerController.storedFormat(defaults: defaults), .hex)
        defaults.set("rgb", forKey: ColorSamplerController.formatDefaultsKey)
        XCTAssertEqual(ColorSamplerController.storedFormat(defaults: defaults), .rgb)
    }

    // MARK: - Command

    @MainActor
    func testSampleCopiesTheChosenFormatAndReportsTheColour() async {
        let selection = ScreenRegionSelector.Selection(
            rect: CGRect(x: 10, y: 10, width: 1, height: 1),
            display: ScreenRegionDisplay(id: 1,
                                         frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                         scale: 2),
            image: image(red: 0x12, green: 0x34, blue: 0x56),
            point: CGPoint(x: 10, y: 10)
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MakiDeskColor-\(UUID().uuidString)"))
        var feedback: [ColorSamplerController.Feedback] = []
        let controller = ColorSamplerController(
            selectPoint: { selection },
            pasteboard: pasteboard,
            format: { .rgb },
            feedback: { feedback.append($0) }
        )

        controller.sample()
        for _ in 0..<100 where feedback.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(pasteboard.string(forType: .string), "rgb(18, 52, 86)")
        guard case let .copied(color) = feedback.first else {
            return XCTFail("expected a copied colour, got \(feedback)")
        }
        XCTAssertEqual(color.hex, "#123456")
    }

    @MainActor
    func testSecondSampleWhileTheSelectorIsOpenReportsBusy() async {
        let gate = SelectionGate()
        let selection = ScreenRegionSelector.Selection(
            rect: CGRect(x: 1, y: 1, width: 1, height: 1),
            display: ScreenRegionDisplay(id: 1,
                                         frame: CGRect(x: 0, y: 0, width: 10, height: 10),
                                         scale: 1),
            image: image(red: 1, green: 2, blue: 3),
            point: CGPoint(x: 1, y: 1)
        )
        var feedback: [ColorSamplerController.Feedback] = []
        let controller = ColorSamplerController(
            selectPoint: { await gate.wait(); return selection },
            pasteboard: NSPasteboard(name: NSPasteboard.Name("MakiDeskColor-\(UUID().uuidString)")),
            format: { .hex },
            feedback: { feedback.append($0) }
        )

        controller.sample()
        for _ in 0..<100 where !gate.isWaiting {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        controller.sample()
        XCTAssertEqual(feedback, [.busy])

        gate.open()
        for _ in 0..<100 where feedback.count < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(feedback.count, 2)
        guard case .copied = feedback[1] else { return XCTFail("expected the copy to finish") }
    }

    @MainActor
    func testPermissionDenialIsReported() async {
        var feedback: [ColorSamplerController.Feedback] = []
        let controller = ColorSamplerController(
            selectPoint: { throw ScreenRegionError.permissionDenied },
            pasteboard: NSPasteboard(name: NSPasteboard.Name("MakiDeskColor-\(UUID().uuidString)")),
            format: { .hex },
            feedback: { feedback.append($0) }
        )

        controller.sample()
        for _ in 0..<100 where feedback.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(feedback, [.permissionDenied])
    }
}

@MainActor
private final class SelectionGate {
    private var release: (() -> Void)?
    private(set) var isWaiting = false

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation in
            release = { continuation.resume() }
        }
    }

    func open() {
        release?()
        release = nil
    }
}
