import ApplicationServices
import XCTest
@testable import MakiDesk

@MainActor
final class WindowFrameWriteTests: XCTestCase {
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

    private func wait(for semaphore: DispatchSemaphore) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 3))
            }
        }
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
