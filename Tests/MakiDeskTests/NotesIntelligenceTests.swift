import XCTest
@testable import MakiDesk

/// T66: the controller streams a proposal and owns its revisions. A fake engine
/// stands in for the on-device model, so the checks run on any macOS.
@MainActor
final class NotesIntelligenceTests: XCTestCase {
    private final class FakeEngine: NotesRewriteEngine, @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [AsyncThrowingStream<NotesRewriteDraft, Error>.Continuation] = []

        func stream(prompt: String, action: NotesRewriteAction) -> AsyncThrowingStream<NotesRewriteDraft, Error> {
            let (stream, continuation) = AsyncThrowingStream<NotesRewriteDraft, Error>.makeStream()
            lock.lock()
            continuations.append(continuation)
            lock.unlock()
            return stream
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return continuations.count
        }

        func continuation(_ index: Int) -> AsyncThrowingStream<NotesRewriteDraft, Error>.Continuation {
            lock.lock()
            defer { lock.unlock() }
            return continuations[index]
        }
    }

    private var controller: NotesRewriteController { .shared }

    private func prepare(_ engine: FakeEngine) {
        controller.reset()
        controller.availabilityProvider = { .available }
        controller.engineProvider = { engine }
    }

    /// Bounded wait: the stream is fed by the test, so this only gives the
    /// main-actor task the turns it needs to consume what was already yielded.
    private func wait(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }

    func testAStreamFillsThePreviewAndFinishesReady() async {
        let engine = FakeEngine()
        prepare(engine)
        controller.start(action: .format, source: "note", noteID: UUID())
        XCTAssertEqual(controller.phase, .running)
        let opened = await wait { engine.count == 1 }
        XCTAssertTrue(opened)

        engine.continuation(0).yield(NotesRewriteDraft(
            title: "Plan",
            sections: [.init(level: 1, heading: "Steps", paragraphs: ["One."])]
        ))
        let previewed = await wait { self.controller.preview.contains("## Steps") }
        XCTAssertTrue(previewed)

        engine.continuation(0).finish()
        let ready = await wait { self.controller.phase == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(controller.preview, "# Plan\n\n## Steps\n\nOne.\n")
    }

    func testANewerRequestDropsTheOldStream() async {
        let engine = FakeEngine()
        prepare(engine)
        controller.start(action: .improve, source: "first", noteID: UUID())
        _ = await wait { engine.count == 1 }
        engine.continuation(0).yield(NotesRewriteDraft(sections: [.init(paragraphs: ["First."])]))
        _ = await wait { self.controller.preview.contains("First.") }

        controller.start(action: .improve, source: "second", noteID: UUID())
        let reopened = await wait { engine.count == 2 }
        XCTAssertTrue(reopened)
        // The old stream keeps talking: its result must not land.
        engine.continuation(0).yield(NotesRewriteDraft(sections: [.init(paragraphs: ["Late."])]))
        engine.continuation(1).yield(NotesRewriteDraft(sections: [.init(paragraphs: ["Second."])]))
        engine.continuation(1).finish()

        let ready = await wait { self.controller.phase == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(controller.preview, "Second.\n")
        engine.continuation(0).finish()
    }

    func testCancelStopsTheStream() async {
        let engine = FakeEngine()
        prepare(engine)
        controller.start(action: .summarize, source: "note", noteID: UUID())
        _ = await wait { engine.count == 1 }
        controller.cancel()
        engine.continuation(0).yield(NotesRewriteDraft(summary: "ignored"))
        engine.continuation(0).finish()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.preview, "")
    }

    func testAnUnavailableModelStartsNothing() {
        let engine = FakeEngine()
        controller.reset()
        controller.availabilityProvider = { .unavailable("Apple Intelligence is off.") }
        controller.engineProvider = { engine }
        controller.start(action: .improve, source: "note", noteID: UUID())
        XCTAssertEqual(controller.phase, .failed("Apple Intelligence is off."))
        XCTAssertEqual(engine.count, 0)
        XCTAssertEqual(controller.preview, "")
    }

    func testAnEmptyNoteStartsNothing() {
        let engine = FakeEngine()
        prepare(engine)
        controller.start(action: .improve, source: "   \n ", noteID: UUID())
        XCTAssertEqual(controller.phase, .failed("There is nothing to rewrite."))
        XCTAssertEqual(engine.count, 0)
    }
}
