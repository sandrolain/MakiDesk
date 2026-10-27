import XCTest
@testable import MakiDesk

@MainActor
final class ScreenshotLibraryTests: XCTestCase {
    func testOverlappingRefreshRequestsCoalesceToOneFollowUpScan() async {
        let gate = ScreenshotScanGate()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDeskScreenshotScan-\(UUID().uuidString)", isDirectory: true)
        let model = ScreenshotLibraryModel(folderURL: folder) { path, prefixes, extensions, _ in
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
        let model = ScreenshotLibraryModel(folderURL: folder) { path, _, _, _ in
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
        let model = ScreenshotLibraryModel(folderURL: oldFolder) { path, _, _, _ in
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

    // MARK: - T48: system folder, Spotlight and scan merge

    func testScanMergesRenamedCapturesFromTheIndexWithoutDuplicates() throws {
        let folder = temporaryFolder("Merge")
        defer { try? FileManager.default.removeItem(at: folder) }
        let named = folder.appendingPathComponent("Screenshot 2026-01-02.png")
        let renamed = folder.appendingPathComponent("holiday.png")
        let text = folder.appendingPathComponent("notes.txt")
        let nested = folder.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedCapture = nested.appendingPathComponent("screenshot nested.png")
        for url in [named, renamed, text, nestedCapture] {
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data([0x89, 0x50])))
        }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)],
                                             ofItemAtPath: named.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)],
                                             ofItemAtPath: renamed.path)

        let result = ScreenshotLibraryModel.scan(
            path: folder.path,
            prefixes: ["screenshot"],
            extensions: ["png"],
            indexedPaths: [renamed.path, named.path, text.path, nestedCapture.path]
        )

        XCTAssertNil(result.error)
        // The renamed capture comes from the index, the duplicate is absorbed,
        // the text file and the nested capture stay out.
        XCTAssertEqual(result.files.map(\.name), ["Screenshot 2026-01-02.png", "holiday.png"])
    }

    func testChoosingAFolderPersistsAndUseSystemFolderClearsIt() {
        let suite = "MakiDeskScreenshotDefaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let system = temporaryFolder("System")
        let custom = temporaryFolder("Custom")
        defer {
            try? FileManager.default.removeItem(at: system)
            try? FileManager.default.removeItem(at: custom)
        }
        let model = ScreenshotLibraryModel(defaults: defaults, systemFolder: { system },
                                           index: FakeScreenshotIndex())
        XCTAssertEqual(model.folderURL.standardizedFileURL, system.standardizedFileURL)
        XCTAssertTrue(model.isUsingSystemFolder)

        model.chooseFolder(custom)
        XCTAssertEqual(model.folderURL.standardizedFileURL, custom.standardizedFileURL)
        XCTAssertFalse(model.isUsingSystemFolder)
        XCTAssertEqual(defaults.string(forKey: "screenshotLibraryFolderPath"),
                       custom.standardizedFileURL.path)

        model.useSystemFolder()
        XCTAssertEqual(model.folderURL.standardizedFileURL, system.standardizedFileURL)
        XCTAssertTrue(model.isUsingSystemFolder)
        XCTAssertNil(defaults.string(forKey: "screenshotLibraryFolderPath"))

        // Picking exactly the system folder means following it, so the key
        // must not freeze today's path.
        model.chooseFolder(custom)
        XCTAssertNotNil(defaults.string(forKey: "screenshotLibraryFolderPath"))
        model.chooseFolder(system)
        XCTAssertTrue(model.isUsingSystemFolder)
        XCTAssertNil(defaults.string(forKey: "screenshotLibraryFolderPath"))
    }

    func testStoredFolderIsUsedOnTheNextLaunch() {
        let suite = "MakiDeskScreenshotDefaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let system = temporaryFolder("System")
        let custom = temporaryFolder("Custom")
        defer {
            try? FileManager.default.removeItem(at: system)
            try? FileManager.default.removeItem(at: custom)
        }
        defaults.set(custom.standardizedFileURL.path, forKey: "screenshotLibraryFolderPath")
        let model = ScreenshotLibraryModel(defaults: defaults, systemFolder: { system },
                                           index: FakeScreenshotIndex())
        XCTAssertEqual(model.folderURL.standardizedFileURL, custom.standardizedFileURL)
        XCTAssertFalse(model.isUsingSystemFolder)
    }

    func testShowScansWithIndexedPathsAndPublishesRenamedCaptures() async throws {
        let folder = temporaryFolder("Indexed")
        defer { try? FileManager.default.removeItem(at: folder) }
        let named = folder.appendingPathComponent("Screenshot 1.png")
        let renamed = folder.appendingPathComponent("holiday.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: named.path, contents: Data([0x89, 0x50])))
        XCTAssertTrue(FileManager.default.createFile(atPath: renamed.path, contents: Data([0x89, 0x50])))

        let suite = "MakiDeskScreenshotDefaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let index = FakeScreenshotIndex()
        index.paths = [renamed.path]
        let model = ScreenshotLibraryModel(folderURL: folder, defaults: defaults,
                                           systemFolder: { folder }, index: index)

        model.show()
        defer { model.hide() }
        for _ in 0..<100 where model.files.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(Set(model.files.map(\.name)), ["Screenshot 1.png", "holiday.png"])
        XCTAssertEqual(index.startedFolders.map { $0.standardizedFileURL.path },
                       [folder.standardizedFileURL.path])
        XCTAssertEqual(model.indexState, .indexed)
    }

    private func temporaryFolder(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDeskScreenshot-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

@MainActor
private final class FakeScreenshotIndex: ScreenshotIndexProvider {
    var state: ScreenshotIndexState = .idle
    var paths: [String] = []
    var onChange: (() -> Void)?
    private(set) var startedFolders: [URL] = []

    func start(folder: URL) {
        startedFolders.append(folder)
        state = paths.isEmpty ? .empty : .indexed
    }

    func stop() {
        state = .idle
    }
}
