import XCTest
@testable import MakiDesk

/// T44: the on-disk configuration. The store is given a temporary file so the
/// tests never touch the real Application Support.
final class DropzoneStoreTests: XCTestCase {
    private var directory: URL!
    private var store: DropzoneStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDeskDropzoneStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = DropzoneStore(fileURL: directory.appendingPathComponent("dropzones.json"))
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func failure(_ result: Result<Void, DropzoneStore.StoreError>) -> DropzoneStore.StoreError? {
        if case let .failure(error) = result { return error }
        return nil
    }

    private func zone(name: String = "Resize",
                      command: String = "shortcuts run ABC --input-path {paths}") -> DropzoneConfig {
        // Whole seconds: ISO-8601 has no sub-second precision.
        DropzoneConfig(name: name, command: CommandSpec(line: command),
                       createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testMissingFileIsAnEmptyRunnableConfiguration() {
        let snapshot = store.load()
        XCTAssertEqual(snapshot.zones, [])
        XCTAssertEqual(snapshot.state, .missing)
        XCTAssertTrue(snapshot.isRunnable)
        XCTAssertTrue(snapshot.isTrusted)
        XCTAssertTrue(snapshot.canSave)
    }

    func testSaveAndLoadRoundTrip() throws {
        let zones = [zone(), zone(name: "Other", command: "echo {text}")]
        XCTAssertNoThrow(try store.save(zones).get())

        let snapshot = store.load()
        XCTAssertEqual(snapshot.state, .loaded)
        XCTAssertEqual(snapshot.version, DropzoneStore.currentVersion)
        XCTAssertEqual(snapshot.zones, zones)
        XCTAssertTrue(snapshot.isRunnable)
    }

    func testSavedFileIsPrivate() throws {
        try store.save([zone()]).get()
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue, 0o600)
    }

    func testCorruptFileIsSetAsideAndDoesNotThrow() throws {
        try "this is not json".write(to: store.fileURL, atomically: true, encoding: .utf8)

        let snapshot = store.load()
        XCTAssertEqual(snapshot.state, .corrupt)
        XCTAssertEqual(snapshot.zones, [])
        XCTAssertTrue(snapshot.isRunnable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path) == false)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.fileURL.appendingPathExtension("bak").path))
    }

    func testSecondCorruptFileKeepsBothBackups() throws {
        try "bad".write(to: store.fileURL, atomically: true, encoding: .utf8)
        _ = store.load()
        try "bad again".write(to: store.fileURL, atomically: true, encoding: .utf8)
        _ = store.load()

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.fileURL.appendingPathExtension("bak").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.fileURL.appendingPathExtension("bak-1").path))
    }

    func testFutureVersionIsReadOnlyAndLeftUntouched() throws {
        let contents = #"{"version":99,"zones":[]}"#
        try contents.write(to: store.fileURL, atomically: true, encoding: .utf8)

        let snapshot = store.load()
        XCTAssertEqual(snapshot.state, .futureVersion(99))
        XCTAssertFalse(snapshot.isRunnable)
        XCTAssertFalse(snapshot.canSave)

        XCTAssertEqual(failure(store.save([zone()])), .futureVersion(99))
        XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), contents)
    }

    func testGroupWritableFileIsUntrustedButCanBeFixedBySaving() throws {
        try store.save([zone()]).get()
        try FileManager.default.setAttributes([.posixPermissions: 0o666],
                                              ofItemAtPath: store.fileURL.path)

        let untrusted = store.load()
        XCTAssertEqual(untrusted.state, .untrustedPermissions)
        XCTAssertFalse(untrusted.isRunnable)
        XCTAssertFalse(untrusted.isTrusted)
        XCTAssertTrue(untrusted.canSave)
        XCTAssertEqual(untrusted.zones.count, 1)

        try store.save(untrusted.zones).get()
        XCTAssertEqual(store.load().state, .loaded)
    }

    func testSymlinkIsRefused() throws {
        let target = directory.appendingPathComponent("elsewhere.json")
        try store.save([zone()]).get()
        try FileManager.default.moveItem(at: store.fileURL, to: target)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: target)

        let snapshot = store.load()
        XCTAssertEqual(snapshot.state, .untrustedPermissions)
        XCTAssertEqual(snapshot.zones, [])
        XCTAssertFalse(snapshot.isRunnable)
    }

    func testDuplicateIdentifiersAreRejected() throws {
        let zone = zone()
        XCTAssertEqual(failure(store.save([zone, zone])), .duplicateID(zone.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testTooManyZonesAreRejected() throws {
        let zones = (0...(DropzoneStore.maximumZones)).map { zone(name: "Zone \($0)") }
        XCTAssertEqual(failure(store.save(zones)), .tooManyZones(zones.count))
    }

    func testInvalidZoneIsRejectedWithItsIndex() throws {
        var invalid = zone()
        invalid.command.line = ""
        let result = store.save([zone(), invalid])
        guard case let .failure(.invalidZone(index, message)) = result else {
            return XCTFail("expected an invalid zone, got \(result)")
        }
        XCTAssertEqual(index, 1)
        XCTAssertTrue(message.contains("command"))
    }

    func testModificationDateIsAvailable() throws {
        XCTAssertNil(store.modificationDate())
        try store.save([zone()]).get()
        XCTAssertNotNil(store.modificationDate())
    }

    func testUnknownJSONKeysAreIgnored() throws {
        let json = #"{"version":1,"zones":[{"name":"A","command":{"line":"echo hi"},"future":true}]}"#
        try json.write(to: store.fileURL, atomically: true, encoding: .utf8)
        let snapshot = store.load()
        XCTAssertEqual(snapshot.state, .loaded)
        XCTAssertEqual(snapshot.zones.first?.name, "A")
    }
}
