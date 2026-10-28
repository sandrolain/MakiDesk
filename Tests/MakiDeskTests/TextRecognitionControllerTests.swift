import AppKit
import CoreGraphics
import XCTest
@testable import MakiDesk

@MainActor
final class TextRecognitionControllerTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var history: ClipboardHistory!
    private var feedback: FeedbackRecorder!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: .init("MakiDeskOCR-\(UUID().uuidString)"))
        pasteboard.clearContents()
        history = ClipboardHistory(pasteboard: pasteboard, limit: 50, secureInput: { false })
        feedback = FeedbackRecorder()
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        pasteboard = nil
        history = nil
        feedback = nil
    }

    func testCopiesRecognizedTextAndReportsIt() async {
        let result = TextRecognitionResult(text: "Hello\nWorld", durationMilliseconds: 12,
                                           scaled: false)
        let controller = makeController(recognizer: StubRecognizer(outcome: .success(result)))

        controller.recognizeArea()
        await waitUntil { self.feedback.values.isEmpty == false }

        XCTAssertEqual(feedback.values, [.copied(result, .pasteboardAndHistory)])
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello\nWorld")
        XCTAssertEqual(history.entries.map(\.text), ["Hello\nWorld"])
    }

    func testTextReadWhileSecureInputIsOnIsMarkedConcealedOnThePasteboard() async {
        let result = TextRecognitionResult(text: "s3cret", durationMilliseconds: 5, scaled: false)
        let controller = makeController(recognizer: StubRecognizer(outcome: .success(result)),
                                        secureInput: { true })

        controller.recognizeArea(output: .pasteboard)
        await waitUntil { self.feedback.values.isEmpty == false }

        XCTAssertEqual(pasteboard.string(forType: .string), "s3cret")
        XCTAssertTrue(pasteboard.types?.contains(ClipboardHistory.concealedMarker) == true)
    }

    func testOrdinaryTextIsNotMarkedConcealed() async {
        let result = TextRecognitionResult(text: "plain", durationMilliseconds: 5, scaled: false)
        let controller = makeController(recognizer: StubRecognizer(outcome: .success(result)))

        controller.recognizeArea(output: .pasteboard)
        await waitUntil { self.feedback.values.isEmpty == false }

        XCTAssertEqual(pasteboard.types?.contains(ClipboardHistory.concealedMarker), false)
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
        let reveal = RevealSpy()
        let controller = makeController(recognizer: recognizer,
                                        showHistory: { reveal.count += 1 })

        controller.recognizeArea(reveal: .always)
        await recognizer.waitForFirstStart()

        controller.recognizeArea(reveal: .always)
        await waitUntil { self.feedback.values.isEmpty == false }
        XCTAssertEqual(feedback.values, [.copied(second, .pasteboardAndHistory)])
        XCTAssertEqual(pasteboard.string(forType: .string), "second")
        XCTAssertEqual(reveal.count, 1)

        // The first request finishes after the newer one: its answer belongs to
        // a generation that no longer exists and must be discarded.
        await recognizer.releaseFirst()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(feedback.values, [.copied(second, .pasteboardAndHistory)])
        XCTAssertEqual(pasteboard.string(forType: .string), "second")
        XCTAssertEqual(reveal.count, 1, "a stale result must not open the history")
    }

    // MARK: - Output destinations (T54)

    func testHistoryOnlyLeavesThePasteboardUntouched() async {
        let result = TextRecognitionResult(text: "secret", durationMilliseconds: 1, scaled: false)
        let before = pasteboard.changeCount
        let controller = makeController(recognizer: StubRecognizer(outcome: .success(result)))

        controller.recognizeArea(output: .historyOnly)
        await waitUntil { self.feedback.values.isEmpty == false }

        XCTAssertEqual(pasteboard.changeCount, before)
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertEqual(history.entries.map(\.text), ["secret"])
        XCTAssertEqual(feedback.values, [.copied(result, .historyOnly)])
    }

    func testPasteboardOnlyDoesNotAddToHistory() async {
        let result = TextRecognitionResult(text: "copied", durationMilliseconds: 1, scaled: false)
        let controller = makeController(recognizer: StubRecognizer(outcome: .success(result)))

        controller.recognizeArea(output: .pasteboard)
        await waitUntil { self.feedback.values.isEmpty == false }
        history.poll()

        XCTAssertEqual(pasteboard.string(forType: .string), "copied")
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testPasteboardAndHistoryAddsOneEntryImmediately() async {
        let result = TextRecognitionResult(text: "both", durationMilliseconds: 1, scaled: false)
        let controller = makeController(recognizer: StubRecognizer(outcome: .success(result)))

        controller.recognizeArea(output: .pasteboardAndHistory)
        await waitUntil { self.feedback.values.isEmpty == false }

        XCTAssertEqual(history.entries.map(\.text), ["both"])
        history.poll()
        XCTAssertEqual(history.entries.map(\.text), ["both"])
    }

    func testRevealPreferenceOpensTheHistoryOnlyWhenItShould() async {
        let result = TextRecognitionResult(text: "x", durationMilliseconds: 1, scaled: false)
        let always = RevealSpy()
        let alwaysController = makeController(
            recognizer: StubRecognizer(outcome: .success(result)),
            showHistory: { always.count += 1 }
        )
        alwaysController.recognizeArea(output: .pasteboard, reveal: .always)
        await waitUntil { always.count > 0 }
        XCTAssertEqual(always.count, 1)

        let never = RevealSpy()
        let neverBaseline = feedback.values.count
        let neverController = makeController(
            recognizer: StubRecognizer(outcome: .success(result)),
            showHistory: { never.count += 1 }
        )
        neverController.recognizeArea(output: .historyOnly, reveal: .never)
        await waitUntil { self.feedback.values.count > neverBaseline }
        XCTAssertEqual(never.count, 0)

        let onlyHistory = RevealSpy()
        let onlyController = makeController(
            recognizer: StubRecognizer(outcome: .success(result)),
            showHistory: { onlyHistory.count += 1 }
        )
        let onlyBaseline = feedback.values.count
        onlyController.recognizeArea(output: .pasteboard, reveal: .historyOnly)
        await waitUntil { self.feedback.values.count > onlyBaseline }
        XCTAssertEqual(onlyHistory.count, 0)
        onlyController.recognizeArea(output: .historyOnly, reveal: .historyOnly)
        await waitUntil { onlyHistory.count > 0 }
        XCTAssertEqual(onlyHistory.count, 1)
    }

    func testRevealDoesNotOpenAfterTheUserSwitchesApp() async {
        let result = TextRecognitionResult(text: "x", durationMilliseconds: 1, scaled: false)
        let spy = RevealSpy()
        let pids = PIDSequence([42, 43])
        let controller = makeController(
            recognizer: StubRecognizer(outcome: .success(result)),
            frontmostPID: { pids.next() },
            showHistory: { spy.count += 1 }
        )

        controller.recognizeArea(output: .historyOnly, reveal: .always)
        await waitUntil { self.feedback.values.isEmpty == false }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(spy.count, 0)
    }

    // MARK: - Helpers

    private func makeController(
        recognizer: TextRecognizing,
        selectRegion: @escaping TextRecognitionController.RegionSelector = {
            TextRecognitionControllerTests.selection()
        },
        frontmostPID: @escaping TextRecognitionController.PIDProvider = { 42 },
        secureInput: @escaping () -> Bool = { false },
        showHistory: @escaping TextRecognitionController.HistoryPresenter = {}
    ) -> TextRecognitionController {
        TextRecognitionController(
            recognizer: recognizer,
            pasteboard: pasteboard,
            history: history,
            selectRegion: selectRegion,
            frontmostPID: frontmostPID,
            secureInput: secureInput,
            showHistory: showHistory,
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


@MainActor
private final class RevealSpy {
    var count = 0
}

@MainActor
private final class PIDSequence {
    private var values: [pid_t?]

    init(_ values: [pid_t?]) {
        self.values = values
    }

    func next() -> pid_t? {
        values.isEmpty ? nil : values.removeFirst()
    }
}
