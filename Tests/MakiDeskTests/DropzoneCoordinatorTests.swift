import XCTest
@testable import MakiDesk

/// T44: validation, preparation and execution of one drop. The runner is a
/// fake, so no real command runs and the payload can be inspected.
@MainActor
final class DropzoneCoordinatorTests: XCTestCase {
    private var directory: URL!
    private var store: DropzoneStore!
    private var runRoot: URL!
    private var runner: RecordingRunner!
    private var coordinator: DropzoneCoordinator!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDeskCoordinator-\(UUID().uuidString)", isDirectory: true)
        runRoot = directory.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = DropzoneStore(fileURL: directory.appendingPathComponent("dropzones.json"))
        runner = RecordingRunner()
        coordinator = DropzoneCoordinator(store: store, runner: runner, runRoot: runRoot)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func save(_ zone: DropzoneConfig) throws {
        XCTAssertNoThrow(try store.save([zone]).get())
        coordinator.reloadIfNeeded()
    }

    private func confirmedImageZone(command: CommandSpec = CommandSpec(line: "echo {paths}")) -> DropzoneConfig {
        var zone = DropzoneConfig(name: "Images",
                                  accepts: DropzoneAccept(kinds: [.files], utis: ["public.image"]),
                                  command: command)
        zone.markConfirmed()
        return zone
    }

    private func textFile(_ name: String = "notes.txt") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func imageFile(_ name: String = "photo.png") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        return url
    }

    // MARK: - Validation

    func testRejectedDropNeverStartsACommand() async throws {
        try save(confirmedImageZone())
        let drop = DropzoneDrop(files: [try textFile()])

        let outcome = await coordinator.run(zoneID: coordinator.zones[0].id, drop: drop)
        XCTAssertEqual(outcome, .rejected(.wrongType("notes.txt")))
        XCTAssertTrue(runner.records.isEmpty)
        XCTAssertTrue(coordinator.runningZones.isEmpty)
    }

    func testUntrustedStoreDoesNotRun() async throws {
        try save(confirmedImageZone())
        try FileManager.default.setAttributes([.posixPermissions: 0o666],
                                              ofItemAtPath: store.fileURL.path)
        coordinator = DropzoneCoordinator(store: store, runner: runner, runRoot: runRoot)

        let outcome = await coordinator.run(zoneID: coordinator.zones[0].id,
                                            drop: DropzoneDrop(files: [try imageFile()]))
        guard case .failed = outcome else { return XCTFail("expected a failure, got \(outcome)") }
        XCTAssertTrue(runner.records.isEmpty)
    }

    func testFirstRunAsksForConfirmationAndTheConfirmationSticks() async throws {
        var zone = DropzoneConfig(name: "Images",
                                  accepts: DropzoneAccept(kinds: [.files], utis: ["public.image"]),
                                  command: CommandSpec(line: "echo {paths}"))
        zone.confirmedCommandHash = nil
        try save(zone)
        let id = coordinator.zones[0].id

        let first = await coordinator.run(zoneID: id, drop: DropzoneDrop(files: [try imageFile()]))
        guard case .needsConfirmation = first else { return XCTFail("expected a confirmation") }
        XCTAssertTrue(runner.records.isEmpty)

        coordinator.confirm(zoneID: id)
        XCTAssertFalse(coordinator.zones[0].requiresConfirmation)

        let second = await coordinator.run(zoneID: id, drop: DropzoneDrop(files: [try imageFile()]))
        guard case .finished = second else { return XCTFail("expected a run, got \(second)") }
        XCTAssertEqual(runner.records.count, 1)
    }

    func testCommandChangeAsksForConfirmationAgain() async throws {
        var zone = confirmedImageZone()
        zone.command.line = "echo first"
        zone.markConfirmed()
        try save(zone)

        var changed = zone
        changed.command.line = "echo second"
        XCTAssertNoThrow(try store.save([changed]).get())
        coordinator.reloadIfNeeded()

        let outcome = await coordinator.run(zoneID: changed.id,
                                            drop: DropzoneDrop(files: [try imageFile()]))
        guard case .needsConfirmation = outcome else { return XCTFail("expected a new confirmation") }
    }

    // MARK: - Preparation

    func testPreparedPayloadWritesTextLinksImagesAndManifest() async throws {
        var command = CommandSpec(line: "echo {paths} {text} {textfile} {urlsfile} {manifest}")
        command.keepWorkdir = true
        var zone = DropzoneConfig(name: "Everything",
                                  accepts: DropzoneAccept(kinds: [.files, .text, .urls, .images]),
                                  command: command)
        zone.markConfirmed()
        try save(zone)

        let drop = DropzoneDrop(files: [try imageFile()],
                               text: "some text",
                               urls: [URL(string: "https://example.com/page")!],
                               images: [.init(data: Data([1, 2, 3]), name: "clipboard")])
        let outcome = await coordinator.run(zoneID: zone.id, drop: drop)
        guard case let .finished(result) = outcome else { return XCTFail("expected a run, got \(outcome)") }
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.workDirectory.path))

        let record = try XCTUnwrap(runner.records.first)
        let arguments = record.command.arguments
        XCTAssertTrue(arguments.contains(drop.files[0].path))
        XCTAssertTrue(arguments.contains("some text"))
        XCTAssertTrue(arguments.contains(contents(of: record.command.workDirectory, "text.txt")))
        XCTAssertTrue(arguments.contains(record.command.workDirectory.appendingPathComponent("urls.txt").path))
        XCTAssertTrue(arguments.contains(record.command.workDirectory.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: record.command.workDirectory.appendingPathComponent("image-1.png").path))

        let manifestData = try Data(contentsOf: record.command.workDirectory
            .appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual((manifest["items"] as? [[String: Any]])?.count, 4)
    }

    func testAnyMatchPassesOnlyTheAcceptedSources() async throws {
        var command = CommandSpec(line: "echo {paths}")
        command.keepWorkdir = true
        var zone = DropzoneConfig(name: "Images",
                                  accepts: DropzoneAccept(kinds: [.files], utis: ["public.image"],
                                                          match: .any),
                                  command: command)
        zone.markConfirmed()
        try save(zone)

        let accepted = try imageFile()
        let rejected = try textFile()
        let outcome = await coordinator.run(zoneID: zone.id,
                                            drop: DropzoneDrop(files: [accepted, rejected]))
        guard case .finished = outcome else { return XCTFail("expected a run, got \(outcome)") }

        let record = try XCTUnwrap(runner.records.first)
        XCTAssertEqual(record.command.arguments, [accepted.path])
    }

    func testArtifactsAreRemovedWhenTheCommandEnds() async throws {
        try save(confirmedImageZone(command: CommandSpec(line: "echo {paths}")))
        let outcome = await coordinator.run(zoneID: coordinator.zones[0].id,
                                            drop: DropzoneDrop(files: [try imageFile()]))
        guard case let .finished(result) = outcome else { return XCTFail("expected a run") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.workDirectory.path))
    }

    func testRevealKeepsTheRunDirectoryOnlyWhenTheCommandWroteSomething() async throws {
        var command = CommandSpec(line: "echo {paths}")
        var zone = confirmedImageZone(command: command)
        zone.feedback.revealOutput = true
        try save(zone)

        // Nothing in output/: the directory is removed.
        let empty = await coordinator.run(zoneID: zone.id, drop: DropzoneDrop(files: [try imageFile()]))
        guard case let .finished(first) = empty else { return XCTFail("expected a run") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.workDirectory.path))

        // A command that writes into {outdir}: the directory stays for Finder.
        command.line = "echo {outdir}"
        zone.command = command
        zone.markConfirmed()
        try save(zone)
        runner.writeOutput = true
        let kept = await coordinator.run(zoneID: zone.id, drop: DropzoneDrop(files: [try imageFile()]))
        guard case let .finished(second) = kept else { return XCTFail("expected a run") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.workDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: second.workDirectory.appendingPathComponent("output/result.txt").path))
    }

    func testRunnerFailureIsReportedAndCleansUp() async throws {
        try save(confirmedImageZone())
        runner.error = CommandRunError.spawn(code: 2, reason: "not found")
        let outcome = await coordinator.run(zoneID: coordinator.zones[0].id,
                                            drop: DropzoneDrop(files: [try imageFile()]))
        guard case let .failed(message) = outcome else { return XCTFail("expected a failure") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: runRoot.path).count, 0)
    }

    func testReloadPicksUpExternalEdits() async throws {
        try save(confirmedImageZone())
        XCTAssertEqual(coordinator.zones.map(\.name), ["Images"])

        var renamed = coordinator.zones[0]
        renamed.name = "Pictures"
        XCTAssertNoThrow(try store.save([renamed]).get())
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: store.fileURL.path)
        coordinator.reloadIfNeeded()
        XCTAssertEqual(coordinator.zones.map(\.name), ["Pictures"])
    }

    private func contents(of directory: URL, _ name: String) -> String {
        directory.appendingPathComponent(name).path
    }
}

// MARK: - Test doubles

/// Records what the coordinator resolved and lets a test decide whether the
/// command succeeded, failed or wrote output. A class with a lock, so the test
/// can read it without hops and the coordinator can call it as `Sendable`.
final class RecordingRunner: CommandRunning, @unchecked Sendable {
    struct Record: Equatable {
        var command: ResolvedCommand
        var id: UUID
        var includeStdout: Bool
    }

    private let lock = NSLock()
    private var storedRecords: [Record] = []
    private var storedCancelled: [UUID] = []
    var error: Error?
    var writeOutput = false

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var records: [Record] { withLock { storedRecords } }

    var cancelled: [UUID] { withLock { storedCancelled } }

    func run(_ command: ResolvedCommand, id: UUID, includeStdout: Bool) async throws -> CommandResult {
        let settings = withLock { () -> (Error?, Bool) in
            storedRecords.append(Record(command: command, id: id, includeStdout: includeStdout))
            return (error, writeOutput)
        }
        let (error, writeOutput) = settings

        if writeOutput {
            try "result".write(to: command.outputDirectory.appendingPathComponent("result.txt"),
                               atomically: true, encoding: .utf8)
        }
        if let error { throw error }
        return CommandResult(exitCode: 0, termSignal: nil, timedOut: false, cancelled: false,
                             duration: 0.01, workDirectory: command.workDirectory,
                             stdoutFile: command.workDirectory.appendingPathComponent("stdout.log"),
                             stderrFile: command.workDirectory.appendingPathComponent("stderr.log"),
                             stdoutExcerpt: nil, stderrExcerpt: "")
    }

    func cancel(_ id: UUID) async {
        withLock { storedCancelled.append(id) }
    }
}
