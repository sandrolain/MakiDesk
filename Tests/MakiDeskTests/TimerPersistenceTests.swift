import XCTest
import MakiShared
@testable import MakiDesk

/// R07: the fifth store. Its quarantine was there before the shared one, and it
/// was destructive — it deleted the previous `.bak` before moving the new file
/// into place, so the copy a user would have recovered from was the one that
/// went away.
final class TimerPersistenceTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDeskTimers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private var file: URL { directory.appendingPathComponent("timers.json") }

    func testAFileThatIsNotThereMeansNoTimers() {
        XCTAssertTrue(TimerStore.read(at: file).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAnUnreadableFileIsSetAsideAndTheAppStartsEmpty() throws {
        try Data("not json".utf8).write(to: file)

        XCTAssertTrue(TimerStore.read(at: file).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.appendingPathExtension("bak").path))
    }

    /// The reason this moved to the shared quarantine: a second bad file must
    /// not destroy the first recovery copy.
    func testASecondUnreadableFileKeepsTheEarlierBackup() throws {
        try Data("first".utf8).write(to: file)
        _ = TimerStore.read(at: file)
        try Data("second".utf8).write(to: file)
        _ = TimerStore.read(at: file)

        let first = file.appendingPathExtension("bak")
        let second = directory.appendingPathComponent("timers.json.bak-1")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second")
    }

    func testAReadableFileComesBackWhole() throws {
        let timers = [AppTimer(id: UUID(), label: "tea", origin: .countdown,
                               deadline: Date(timeIntervalSince1970: 1000),
                               pausedRemaining: nil)]
        try StoredJSONFile.write(StoredJSONFile.encoder().encode(timers), to: file)

        let read = TimerStore.read(at: file)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.label, "tea")
    }
}
