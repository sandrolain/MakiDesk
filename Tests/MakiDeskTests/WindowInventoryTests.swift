import XCTest
import ApplicationServices
@testable import MakiDesk

@MainActor
final class WindowInventoryTests: XCTestCase {
    private func window(_ identity: String, elementPID: pid_t, frame: CGRect = .zero, ownerPID: pid_t = 7) -> WindowController.WindowInfo {
        WindowController.WindowInfo(id: identity, title: identity, appName: "Test",
            element: AXUIElementCreateApplication(elementPID), frame: frame, pid: ownerPID)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testInsertionBeforeKnownWindowCannotDuplicateItsFallbackID() {
        let known = window("7-idx0", elementPID: 101)
        let inserted = window("7-idx0", elementPID: 102)
        let renumbered = window("7-idx1", elementPID: 101)
        let result = WindowIndex.reconcile(previous: [known], discovered: [inserted, renumbered])
        XCTAssertEqual(result[1].id, known.id)
        XCTAssertNotEqual(result[0].id, known.id)
        XCTAssertEqual(Set(result.map(\.id)).count, 2)
        let again = WindowIndex.reconcile(previous: result, discovered: [renumbered, inserted])
        XCTAssertEqual(again.map(\.id), [result[1].id, result[0].id])
    }

    func testNewWindowDoesNotReuseRetiredEnumerationIdentity() {
        let result = WindowIndex.reconcile(previous: [window("7-idx0", elementPID: 101)],
                                           discovered: [window("7-idx0", elementPID: 102)])
        XCTAssertNotEqual(result[0].id, "7-idx0")
    }

    func testUnavailableApplicationKeepsKnownWindowsWithoutDuplicatingFreshResults() {
        let first = window("A", elementPID: 101)
        let second = window("B", elementPID: 102)
        let retained = WindowIndex.retainingUnavailable(previous: [first, second],
            read: WindowController.WindowInventoryRead(windows: [first], unavailablePIDs: [7]))
        XCTAssertEqual(retained.map(\.id), ["A", "B"])
        XCTAssertFalse(retained[0].temporarilyUnavailable)
        XCTAssertTrue(retained[1].temporarilyUnavailable)
        let removed = WindowIndex.retainingUnavailable(previous: retained,
            read: WindowController.WindowInventoryRead(windows: []))
        XCTAssertTrue(removed.isEmpty, "A successful empty inventory removes closed windows")
    }

    func testInvalidatedScanCannotPublishAndWaitersJoinFollowupScan() async {
        var work: [() -> Void] = []
        var samples = [[window("old", elementPID: 101)], [window("new", elementPID: 102)]]
        let index = WindowIndex(discover: { samples.removeFirst() }, scheduleDiscovery: { work.append($0) })
        var published: [[String]] = []
        index.refreshAsync { published.append($0.map(\.id)) }
        work.removeFirst()()
        index.invalidate()
        index.refreshAsync { published.append($0.map(\.id)) }
        await drainMainQueue()
        XCTAssertTrue(published.isEmpty)
        XCTAssertTrue(index.snapshot().isEmpty)
        XCTAssertEqual(work.count, 1)
        work.removeFirst()()
        await drainMainQueue()
        XCTAssertEqual(published, [["new"], ["new"]])
    }

    func testGeometryWrittenDuringDiscoveryWinsOverOldScanFrame() async {
        var work: [() -> Void] = []
        let sample = window("known", elementPID: 101)
        let index = WindowIndex(discover: { [sample] }, scheduleDiscovery: { work.append($0) })
        let frame = CGRect(x: 20, y: 40, width: 800, height: 600)
        index.refreshAsync { _ in }
        work.removeFirst()()
        index.updateFrame(frame, for: sample.element)
        await drainMainQueue()
        XCTAssertEqual(index.snapshot().first?.frame, frame)
    }

    func testSingleApplicationRefreshDoesNotScanOrRemoveOtherApplications() async {
        var work: [() -> Void] = []
        let first = window("A", elementPID: 101)
        let other = window("B", elementPID: 102, ownerPID: 8)
        var globalReads = 0
        var scopes: [Set<pid_t>] = []
        let index = WindowIndex(discover: { globalReads += 1; return [first, other] },
            readForPIDs: { pids in scopes.append(pids); return .init(windows: []) },
            scheduleDiscovery: { work.append($0) })
        index.refreshAsync { _ in }
        work.removeFirst()()
        await drainMainQueue()
        index.invalidate(pid: 7)
        index.refreshChangedAsync { _ in }
        work.removeFirst()()
        await drainMainQueue()
        XCTAssertEqual(globalReads, 1)
        XCTAssertEqual(scopes, [[7]])
        XCTAssertEqual(index.snapshot().map(\.id), ["B"])
    }

    func testGlobalRequestDuringPartialScanWaitsForCompleteInventory() async {
        var work: [() -> Void] = []
        let sample = window("A", elementPID: 101)
        var globalReads = 0
        let index = WindowIndex(discover: { globalReads += 1; return [sample] },
            readForPIDs: { _ in .init(windows: []) }, scheduleDiscovery: { work.append($0) })
        index.refreshAsync { _ in }
        work.removeFirst()()
        await drainMainQueue()
        index.invalidate(pid: 7)
        var delivered = 0
        index.refreshChangedAsync { _ in delivered += 1 }
        work.removeFirst()()
        index.refreshAsync { _ in delivered += 1 }
        await drainMainQueue()
        XCTAssertEqual(delivered, 0)
        XCTAssertEqual(work.count, 1)
        work.removeFirst()()
        await drainMainQueue()
        XCTAssertEqual(globalReads, 2)
        XCTAssertEqual(delivered, 2)
        XCTAssertEqual(index.snapshot().map(\.id), ["A"])
    }
}
