import XCTest
@testable import MakiDesk

/// R07: the mechanics four stores each carried a copy of. The stores' own tests
/// are their specification and did not change; these pin the shared part,
/// especially the quarantine walk, which no test covered before.
final class StoredJSONFileTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDeskStored-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    func testTheDefaultURLIsUnderTheAppFolder() {
        let url = StoredJSONFile.defaultURL(named: "groups.json")
        XCTAssertEqual(url.lastPathComponent, "groups.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "MakiDesk")
        XCTAssertTrue(url.path.contains("Application Support"))
    }

    func testAWriteCreatesTheFolderAndReplacesTheFile() throws {
        let file = directory.appendingPathComponent("nested/deep/items.json")
        try StoredJSONFile.write(Data("one".utf8), to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "one")

        try StoredJSONFile.write(Data("two".utf8), to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "two")
    }

    func testTheEncodedFileIsReadableAndSorted() throws {
        struct Payload: Codable, Equatable { var b: Int; var a: Int }
        let data = try StoredJSONFile.encoder().encode(Payload(b: 2, a: 1))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\n"))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "\"a\"")?.lowerBound),
                          try XCTUnwrap(text.range(of: "\"b\"")?.lowerBound))
        XCTAssertEqual(try StoredJSONFile.decoder().decode(Payload.self, from: data),
                       Payload(b: 2, a: 1))
    }

    /// The point of the quarantine: a file that cannot be read is moved, never
    /// overwritten, so the user can still recover it by hand.
    func testAnUnreadableFileIsMovedAside() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("groups.json")
        try Data("not json".utf8).write(to: file)

        let moved = StoredJSONFile.quarantine(file, label: "test")

        XCTAssertEqual(moved, directory.appendingPathComponent("groups.json.bak"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved!.path))
    }

    /// A second corruption must not overwrite the first recovery copy.
    func testASecondQuarantineKeepsTheEarlierBackup() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("groups.json")

        try Data("first".utf8).write(to: file)
        let first = StoredJSONFile.quarantine(file, label: "test")
        try Data("second".utf8).write(to: file)
        let second = StoredJSONFile.quarantine(file, label: "test")

        XCTAssertEqual(first, directory.appendingPathComponent("groups.json.bak"))
        XCTAssertEqual(second, directory.appendingPathComponent("groups.json.bak-1"))
        XCTAssertEqual(try String(contentsOf: first!, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: second!, encoding: .utf8), "second")
    }

    /// Nothing to move is not a failure, and a failed move leaves the source
    /// alone: the caller must be able to tell the two apart from `nil`.
    func testQuarantiningSomethingThatIsNotThereReturnsNil() {
        XCTAssertNil(StoredJSONFile.quarantine(directory.appendingPathComponent("absent.json"),
                                               label: "test"))
    }
}
