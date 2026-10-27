import AppKit
import CoreGraphics
import XCTest
@testable import MakiDesk

@MainActor
final class TextRecognitionControllerTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var feedback: FeedbackRecorder!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: .init("MakiDeskOCR-\(UUID().uuidString)"))
        pasteboard.clearContents()
        feedback = FeedbackRecorder()
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        pasteboard = nil
        feedback = nil
    }

    func testCopiesRecognizedTextAndReportsIt() async {
        let result = TextRecognitionResult(text: "Hello\nWorld", durationMilliseconds: 12,
                                           scaled: false)
        let controller = makeController(recognizer: StubRecognizer(outcome: .success(result)))

        controller.recognizeArea()
        await waitUntil { self.feedback.values.isEmpty == false }

        XCTAssertEqual(feedback.values, [.copied(result)])
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello\nWorld")
    }

    func testNoTextReportsItWithoutWritingThePasteboard() async {
        let controller = makeController(
            recognizer: StubRecognizer(outcome: .failure(.noText))
        )

        controller.recognizeArea()
        await waitUntil { self.feedback.values.isEmpty == false }

        XCTAssertEqual(feedback.values, [.noText])
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testCancelledSelectionStaysQuietAndCopiesNothing() async {
        let controller = makeController(
            recognizer: StubRecognizer(outcome: .failure(.noText)),
            selectRegion: { throw ScreenRegionError.cancelled }
        )

        controller.recognizeArea()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(feedback.values.isEmpty)
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testPermissionDeniedIsReported() async {
        let controller = makeController(
            recognizer: StubRecognizer(outcome: .failure(.noText)),
            selectRegion: { throw ScreenRegionError.permissionDenied }
        )

        controller.recognizeArea()
        await waitUntil { self.feedback.values.isEmpty == false }

        XCTAssertEqual(feedback.values, [.permissionDenied])
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testAStaleRecognitionCannotOverwriteANewerOne() async {
        let first = TextRecognitionResult(text: "first", durationMilliseconds: 1, scaled: false)
        let second = TextRecognitionResult(text: "second", durationMilliseconds: 1, scaled: false)
        let recognizer = GatedRecognizer(first: first, second: second)
        let controller = makeController(recognizer: recognizer)

        controller.recognizeArea()
        await recognizer.waitForFirstStart()

        controller.recognizeArea()
        await waitUntil { self.feedback.values.isEmpty == false }
        XCTAssertEqual(feedback.values, [.copied(second)])
        XCTAssertEqual(pasteboard.string(forType: .string), "second")

        // The first request finishes after the newer one: its answer belongs to
        // a generation that no longer exists and must be discarded.
        await recognizer.releaseFirst()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(feedback.values, [.copied(second)])
        XCTAssertEqual(pasteboard.string(forType: .string), "second")
    }

    // MARK: - Helpers

    private func makeController(
        recognizer: TextRecognizing,
        selectRegion: @escaping TextRecognitionController.RegionSelector = {
            TextRecognitionControllerTests.selection()
        }
    ) -> TextRecognitionController {
        TextRecognitionController(
            recognizer: recognizer,
            pasteboard: pasteboard,
            selectRegion: selectRegion,
            feedback: { [weak self] in self?.feedback.record($0) }
        )
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool,
                           timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while condition() == false && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func selection() -> ScreenRegionSelector.Selection {
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let image = context.makeImage()!
        return ScreenRegionSelector.Selection(
            rect: CGRect(x: 10, y: 10, width: 4, height: 4),
            display: ScreenRegionDisplay(id: 1,
                                         frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                         scale: 1),
            image: image,
            point: nil
        )
    }
}

@MainActor
private final class FeedbackRecorder {
    private(set) var values: [TextRecognitionController.Feedback] = []

    func record(_ feedback: TextRecognitionController.Feedback) {
        values.append(feedback)
    }
}

private enum StubOutcome: Sendable {
    case success(TextRecognitionResult)
    case failure(TextRecognitionError)
}

private struct StubRecognizer: TextRecognizing {
    let outcome: StubOutcome

    func recognize(_ image: CGImage,
                   options: TextRecognitionOptions) async throws -> TextRecognitionResult {
        switch outcome {
        case let .success(result): return result
        case let .failure(error): throw error
        }
    }
}

/// Holds the first recognition until the test releases it, so a second request
/// can finish first.
private actor GatedRecognizer: TextRecognizing {
    private let first: TextRecognitionResult
    private let second: TextRecognitionResult
    private var calls = 0
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    init(first: TextRecognitionResult, second: TextRecognitionResult) {
        self.first = first
        self.second = second
    }

    func recognize(_ image: CGImage,
                   options: TextRecognitionOptions) async throws -> TextRecognitionResult {
        calls += 1
        if calls == 1 {
            startedWaiters.forEach { $0.resume() }
            startedWaiters.removeAll()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                release = continuation
            }
            return first
        }
        return second
    }

    func waitForFirstStart() async {
        if calls > 0 { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func releaseFirst() {
        release?.resume()
        release = nil
    }
}
