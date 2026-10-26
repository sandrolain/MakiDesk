import ApplicationServices
import XCTest
@testable import MakiDesk

@MainActor
final class WindowFrameWriteTests: XCTestCase {
    func testOwnProcessDetection() {
        XCTAssertTrue(WindowController.isOwnProcess(AXUIElementCreateApplication(getpid())))
        // A pid that is not this process, whether or not it exists.
        XCTAssertFalse(WindowController.isOwnProcess(AXUIElementCreateApplication(12345)))
    }

    func testOurOwnWindowsNeverReachTheFrameWorker() async {
        let writer = RecordedFrameWriter()
        let coordinator = AXFrameWriteCoordinator { frame, _, _, order in
            writer.write(frame, order: order)
        }
        coordinator.enqueue(CGRect(x: 0, y: 0, width: 10, height: 10),
                            element: AXUIElementCreateApplication(getpid()),
                            identity: "own-window", order: .positionThenSize,
                            completion: nil)
        // Nothing may be written from the worker queue; this is the crash guard.
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(writer.frames.isEmpty)
    }

    func testOwnWindowFrameWriteCompletesOnTheMainActor() async {
        let written = expectation(description: "frame write completed")
        // An application element refuses position and size, but the point is the
        // synchronous main-actor path: it must not dispatch to the AX queue.
        WindowController.setFrameAsync(CGRect(x: 0, y: 0, width: 10, height: 10),
                                       for: AXUIElementCreateApplication(getpid()),
                                       identity: "own-window") {
            written.fulfill()
        }
        await fulfillment(of: [written], timeout: 2)
    }

    func testWritesAreSerializedAndIntermediateFramesAreCoalesced() async {
        let writer = RecordedFrameWriter()
        let coordinator = AXFrameWriteCoordinator { frame, _, _, order in
            writer.write(frame, order: order)
        }
        let element = AXUIElementCreateApplication(12345)
        coordinator.enqueue(CGRect(x: 0, y: 0, width: 100, height: 100),
                            element: element, identity: "window-A", order: .positionThenSize,
                            completion: nil)
        let firstStarted = await wait(for: writer.firstStarted)
        XCTAssertEqual(firstStarted, .success)

        coordinator.enqueue(CGRect(x: 10, y: 0, width: 100, height: 100),
                            element: element, identity: "window-A", order: .positionThenSize,
                            completion: nil)
        coordinator.enqueue(CGRect(x: 20, y: 0, width: 100, height: 100),
                            element: element, identity: "window-A", order: .positionThenSize,
                            completion: nil)
        let finalWritten = expectation(description: "last coalesced frame written")
        coordinator.enqueue(CGRect(x: 30, y: 0, width: 100, height: 100),
                            element: element, identity: "window-A", order: .sizeThenPosition) {
            finalWritten.fulfill()
        }
        writer.releaseFirst.signal()
        await fulfillment(of: [finalWritten], timeout: 3)

        XCTAssertEqual(writer.frames.map(\.origin.x), [0, 30])
        XCTAssertEqual(writer.orders, [.positionThenSize, .sizeThenPosition])
        XCTAssertEqual(writer.maximumConcurrentWrites, 1)
    }

    func testPositionWritesCoalesceAndSerialize() async {
        let writer = RecordedPositionWriter()
        let coordinator = AXFrameWriteCoordinator(frameWriter: { _, _, _, _ in },
                                                  positionWriter: { origin, _ in writer.write(origin) })
        let element = AXUIElementCreateApplication(12345)

        coordinator.enqueuePosition(CGPoint(x: 0, y: 0), element: element, identity: "window-A")
        let firstStarted = await wait(for: writer.firstStarted)
        XCTAssertEqual(firstStarted, .success)

        coordinator.enqueuePosition(CGPoint(x: 10, y: 0), element: element, identity: "window-A")
        let finished = expectation(description: "last position written")
        coordinator.enqueuePosition(CGPoint(x: 20, y: 0), element: element, identity: "window-A") {
            finished.fulfill()
        }
        writer.releaseFirst.signal()
        await fulfillment(of: [finished], timeout: 3)

        XCTAssertEqual(writer.positions.map(\.x), [0, 20])
        XCTAssertEqual(writer.maximumConcurrentWrites, 1)
    }

    func testPositionAndFrameForTheSameWindowSerialize() async {
        let writer = RecordedWriteSequence()
        let coordinator = AXFrameWriteCoordinator(
            frameWriter: { _, _, _, _ in writer.record("frame") },
            positionWriter: { _, _ in writer.record("position") }
        )
        let element = AXUIElementCreateApplication(12345)

        coordinator.enqueue(CGRect(x: 0, y: 0, width: 100, height: 100),
                            element: element, identity: "window-A",
                            order: .positionThenSize, completion: nil)
        let firstStarted = await wait(for: writer.firstStarted)
        XCTAssertEqual(firstStarted, .success)

        let finished = expectation(description: "position written after the frame")
        coordinator.enqueuePosition(CGPoint(x: 50, y: 50), element: element,
                                    identity: "window-A") { finished.fulfill() }
        writer.releaseFirst.signal()
        await fulfillment(of: [finished], timeout: 3)

        XCTAssertEqual(writer.calls, ["frame", "position"])
        XCTAssertEqual(writer.maximumConcurrentWrites, 1)
    }

    private func wait(for semaphore: DispatchSemaphore) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 3))
            }
        }
    }
}

private final class RecordedPositionWriter: @unchecked Sendable {
    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedPositions: [CGPoint] = []
    private var activeWrites = 0
    private var maximumActiveWrites = 0

    var positions: [CGPoint] {
        lock.lock()
        defer { lock.unlock() }
        return storedPositions
    }

    var maximumConcurrentWrites: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActiveWrites
    }

    func write(_ origin: CGPoint) {
        lock.lock()
        storedPositions.append(origin)
        activeWrites += 1
        maximumActiveWrites = max(maximumActiveWrites, activeWrites)
        let isFirst = storedPositions.count == 1
        lock.unlock()

        if isFirst {
            firstStarted.signal()
            releaseFirst.wait()
        }

        lock.lock()
        activeWrites -= 1
        lock.unlock()
    }
}

private final class RecordedWriteSequence: @unchecked Sendable {
    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedCalls: [String] = []
    private var activeWrites = 0
    private var maximumActiveWrites = 0

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedCalls
    }

    var maximumConcurrentWrites: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActiveWrites
    }

    func record(_ label: String) {
        lock.lock()
        storedCalls.append(label)
        activeWrites += 1
        maximumActiveWrites = max(maximumActiveWrites, activeWrites)
        let isFirst = storedCalls.count == 1
        lock.unlock()

        if isFirst {
            firstStarted.signal()
            releaseFirst.wait()
        }

        lock.lock()
        activeWrites -= 1
        lock.unlock()
    }
}

private final class RecordedFrameWriter: @unchecked Sendable {
    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedFrames: [CGRect] = []
    private var storedOrders: [WindowController.FrameWriteOrder] = []
    private var activeWrites = 0
    private var maximumActiveWrites = 0

    var frames: [CGRect] {
        lock.lock()
        defer { lock.unlock() }
        return storedFrames
    }

    var orders: [WindowController.FrameWriteOrder] {
        lock.lock()
        defer { lock.unlock() }
        return storedOrders
    }

    var maximumConcurrentWrites: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActiveWrites
    }

    func write(_ frame: CGRect, order: WindowController.FrameWriteOrder) {
        lock.lock()
        storedFrames.append(frame)
        storedOrders.append(order)
        activeWrites += 1
        maximumActiveWrites = max(maximumActiveWrites, activeWrites)
        let isFirst = storedFrames.count == 1
        lock.unlock()

        if isFirst {
            firstStarted.signal()
            releaseFirst.wait()
        }

        lock.lock()
        activeWrites -= 1
        lock.unlock()
    }
}
