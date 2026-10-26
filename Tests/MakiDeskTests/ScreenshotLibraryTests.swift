import XCTest
@testable import MakiDesk

@MainActor
final class ScreenshotLibraryTests: XCTestCase {
    func testOverlappingRefreshRequestsCoalesceToOneFollowUpScan() async {
        let gate = ScreenshotScanGate()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDeskScreenshotScan-\(UUID().uuidString)", isDirectory: true)
        let model = ScreenshotLibraryModel(folderURL: folder) { path, prefixes, extensions in
            gate.scan()
            return ScreenshotScan(files: [], error: nil)
        }

        model.show()
        let firstStarted = await wait(for: gate.firstStarted)
        XCTAssertEqual(firstStarted, .success)
        for _ in 0..<20 { model.refresh() }
        gate.releaseFirst.signal()

        let secondFinished = await wait(for: gate.secondFinished)
        XCTAssertEqual(secondFinished, .success)
        XCTAssertEqual(gate.callCount, 2)
        XCTAssertEqual(gate.maximumConcurrentScans, 1)
        model.hide()
    }

    func testThumbnailRevisionChangesWhenContentsAtSamePathChange() {
        let path = "/tmp/screenshot.png"
        let before = ScreenshotFile(path: path, name: "screenshot.png",
                                    modified: Date(timeIntervalSince1970: 100), byteCount: 100)
        let after = ScreenshotFile(path: path, name: "screenshot.png",
                                   modified: Date(timeIntervalSince1970: 101), byteCount: 120)
        XCTAssertEqual(before.id, after.id)
        XCTAssertNotEqual(before.thumbnailRevision, after.thumbnailRevision)
    }

    func testHidingDuringAScanDiscardsTheResultAndStopsScanning() async throws {
        let gate = ScreenshotScanGate()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDeskScreenshotHide-\(UUID().uuidString)", isDirectory: true)
        let model = ScreenshotLibraryModel(folderURL: folder) { path, _, _ in
            gate.scan()
            return ScreenshotScan(files: [ScreenshotFile(path: path + "/a.png",
                                                         name: "a.png",
                                                         modified: Date(), byteCount: 1)],
                                  error: nil)
        }

        model.show()
        let started = await wait(for: gate.firstStarted)
        XCTAssertEqual(started, .success)

        model.hide()
        gate.releaseFirst.signal()
        try await Task.sleep(nanoseconds: 150_000_000)

        // The scan that was in flight must not publish, and nothing else starts.
        XCTAssertTrue(model.files.isEmpty)
        XCTAssertEqual(gate.callCount, 1)

        model.refresh()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(gate.callCount, 1, "a closed library must not scan")
    }

    func testChangingFolderDuringAScanPublishesOnlyTheNewFolder() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDeskScreenshotSwitch-\(UUID().uuidString)", isDirectory: true)
        let oldFolder = base.appendingPathComponent("Old", isDirectory: true)
        let newFolder = base.appendingPathComponent("New", isDirectory: true)
        let gate = ScreenshotScanGate()
        let model = ScreenshotLibraryModel(folderURL: oldFolder) { path, _, _ in
            gate.scan()
            let name = path == newFolder.path ? "new.png" : "old.png"
            return ScreenshotScan(files: [ScreenshotFile(path: path + "/" + name,
                                                         name: name,
                                                         modified: Date(), byteCount: 1)],
                                  error: nil)
        }

        model.show()
        let started = await wait(for: gate.firstStarted)
        XCTAssertEqual(started, .success)

        model.chooseFolder(newFolder)
        gate.releaseFirst.signal()
        let second = await wait(for: gate.secondFinished)
        XCTAssertEqual(second, .success)

        // The publication is a main-actor hop after the scan returns.
        for _ in 0..<50 where model.files.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(model.folderURL.standardizedFileURL, newFolder.standardizedFileURL)
        XCTAssertEqual(model.files.map(\.name), ["new.png"])
        model.hide()
    }

    private func wait(for semaphore: DispatchSemaphore) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 3))
            }
        }
    }
}

private final class ScreenshotScanGate: @unchecked Sendable {
    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let secondFinished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    private var active = 0
    private var maximumActive = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var maximumConcurrentScans: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActive
    }

    func scan() {
        lock.lock()
        calls += 1
        let call = calls
        active += 1
        maximumActive = max(maximumActive, active)
        lock.unlock()

        if call == 1 {
            firstStarted.signal()
            releaseFirst.wait()
        }

        lock.lock()
        active -= 1
        let finishedSecond = call == 2
        lock.unlock()
        if finishedSecond { secondFinished.signal() }
    }
}
