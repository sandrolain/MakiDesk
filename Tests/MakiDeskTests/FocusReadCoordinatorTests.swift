import XCTest
@testable import MakiDesk

/// B01: the focus read policy, driven with an injected reader and no
/// Accessibility.
@MainActor
final class FocusReadCoordinatorTests: XCTestCase {
    private final class ReadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let gate = DispatchSemaphore(value: 0)

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }

        var total: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private struct Delivered {
        let pid: pid_t?
        let purposes: Set<FocusReadCoordinator.Purpose>
    }

    private func makeCoordinator(
        log: ReadLog,
        target: @escaping () -> FocusReadCoordinator.Target?,
        holdFirstRead: Bool = false,
        delivered: XCTestExpectation,
        into results: @escaping (Delivered) -> Void
    ) -> FocusReadCoordinator {
        FocusReadCoordinator(
            frontmostTarget: target,
            indexedWindows: { [] },
            read: { _, _, _ in
                let call = log.next()
                if holdFirstRead, call == 1 { log.gate.wait() }
                return .desktop
            },
            deliver: { _, pid, purposes in
                results(Delivered(pid: pid, purposes: purposes))
                delivered.fulfill()
            }
        )
    }

    func testOneRequestIsReadOnceAndDeliveredWithItsPurpose() async {
        let log = ReadLog()
        let done = expectation(description: "delivered")
        var results: [Delivered] = []
        let coordinator = makeCoordinator(
            log: log, target: { .init(pid: 42, appName: "App") },
            delivered: done, into: { results.append($0) })

        coordinator.request(.now)
        await fulfillment(of: [done], timeout: 5)

        XCTAssertEqual(log.total, 1)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.pid, 42)
        XCTAssertEqual(results.first?.purposes, [.now])
    }

    func testNoFrontmostAppDeliversNothingFocusedWithoutReading() async {
        let log = ReadLog()
        let done = expectation(description: "delivered")
        var results: [Delivered] = []
        let coordinator = makeCoordinator(
            log: log, target: { nil }, delivered: done, into: { results.append($0) })

        coordinator.request(.inventory)
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(log.total, 0)
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results.first?.pid)
        XCTAssertEqual(results.first?.purposes, [.inventory])
    }

    func testARequestDuringAReadMakesItStaleAndOneMoreReadCoversBoth() async {
        let log = ReadLog()
        let done = expectation(description: "delivered")
        var results: [Delivered] = []
        let coordinator = makeCoordinator(
            log: log, target: { .init(pid: 7, appName: nil) },
            holdFirstRead: true, delivered: done, into: { results.append($0) })

        coordinator.request(.now)
        coordinator.request(.change)
        log.gate.signal()
        await fulfillment(of: [done], timeout: 5)

        XCTAssertEqual(log.total, 2, "the stale first answer is not delivered")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.purposes, [.now, .change])
    }

    func testAnAppThatIsNoLongerFrontmostIsRetriedThenDeliveredAsNone() async {
        let log = ReadLog()
        let done = expectation(description: "delivered")
        var results: [Delivered] = []
        var targets = 0
        // Every look at the frontmost app sees a different one.
        let coordinator = makeCoordinator(
            log: log,
            target: { targets += 1; return .init(pid: pid_t(targets), appName: nil) },
            delivered: done, into: { results.append($0) })

        coordinator.request(.change)
        await fulfillment(of: [done], timeout: 5)

        XCTAssertEqual(log.total, FocusReadCoordinator.maximumRepeats + 1)
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results.first?.pid)
    }
}
