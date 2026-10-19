import XCTest
@testable import MakiDesk

/// The groups file (G2): round-trip, atomic write, and a corrupt file that is
/// set aside instead of taking the app down.
final class GroupStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDeskGroups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("groups.json") }

    private func makeGroup(slot: Int, name: String? = nil, titles: [String]) -> WindowGroup {
        var group = WindowGroup(slot: slot, name: name)
        group.members = titles.map {
            WindowRef(identity: WindowIdentity(id: "1-cg1", bundleId: "com.example.app",
                                               appName: "Example", title: $0, document: nil))
        }
        return group
    }

    func testGroupsRoundTripThroughTheFile() {
        let groups = [makeGroup(slot: 1, name: "Dev", titles: ["a", "b"]),
                      makeGroup(slot: 4, titles: ["c"])]
        GroupStore(fileURL: fileURL).save(groups)

        XCTAssertEqual(GroupStore(fileURL: fileURL).load(), groups)
    }

    func testMissingFileLoadsEmptyWithoutABackup() {
        let store = GroupStore(fileURL: fileURL)
        XCTAssertEqual(store.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("bak").path))
    }

    func testCorruptFileIsSetAsideAndLoadsEmpty() throws {
        let garbage = Data("{ not json at all".utf8)
        try garbage.write(to: fileURL)

        XCTAssertEqual(GroupStore(fileURL: fileURL).load(), [])
        // The bad bytes are kept for the user, and the live file is gone so the
        // next save starts clean.
        let backup = fileURL.appendingPathExtension("bak")
        XCTAssertEqual(try Data(contentsOf: backup), garbage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSaveCreatesTheContainingDirectory() {
        // A path whose folder does not exist yet (as on a first run).
        let nested = directory.appendingPathComponent("MakiDesk", isDirectory: true)
            .appendingPathComponent("groups.json")
        let groups = [makeGroup(slot: 2, titles: ["x"])]
        GroupStore(fileURL: nested).save(groups)
        XCTAssertEqual(GroupStore(fileURL: nested).load(), groups)
    }

    func testFileCarriesAVersionField() throws {
        GroupStore(fileURL: fileURL).save([makeGroup(slot: 3, titles: ["y"])])
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        XCTAssertEqual(object?["version"] as? Int, GroupStore.currentVersion)
    }

    func testAFileWithoutAVersionIsStillRead() throws {
        // Files written before the field existed (or by hand) are read as v1.
        let legacy = #"{"groups":[{"id":"11111111-1111-1111-1111-111111111111","slot":5,"members":[],"layout":"grid"}]}"#
        try Data(legacy.utf8).write(to: fileURL)

        let loaded = GroupStore(fileURL: fileURL).load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.slot, 5)
    }

    func testSaveLeavesNoTemporaryFileBehind() throws {
        GroupStore(fileURL: fileURL).save([makeGroup(slot: 1, titles: ["z"])])
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, ["groups.json"])
    }

    // MARK: - The refs these files hold must survive a restart

    func testStoredReferenceSurvivesARestartWithANewSystemIdentity() {
        // The id saved yesterday ("100-cg7") is stale today; the app/title is not.
        let ref = WindowRef(identity: WindowIdentity(id: "100-cg7", bundleId: "com.apple.Safari",
                                                     appName: "Safari", title: "Docs", document: nil))
        let live = [WindowIdentity(id: "900-cg1", bundleId: "com.apple.Safari",
                                   appName: "Safari", title: "Docs", document: nil)]
        XCTAssertEqual(GroupMatcher.match([ref], to: live), [0])
    }

    func testAClosedAppLeavesItsMemberUnmatched() {
        let ref = WindowRef(identity: WindowIdentity(id: "100-cg7", bundleId: "com.apple.Safari",
                                                     appName: "Safari", title: "Docs", document: nil))
        XCTAssertEqual(GroupMatcher.match([ref], to: []), [nil])
    }

    // MARK: - The remembered arrangement (T15)

    func testTheArrangementRoundTripsThroughTheFile() {
        var group = makeGroup(slot: 2, name: "Reading", titles: ["a", "b"])
        let key = group.members[0].id
        let frame = CGRect(x: 10, y: 20, width: 300, height: 400)
        group.frames[key] = frame
        GroupStore(fileURL: fileURL).save([group])

        let loaded = GroupStore(fileURL: fileURL).load()
        XCTAssertEqual(loaded.first?.frames[key], frame)
        XCTAssertEqual(loaded.first?.hasArrangement, true)
    }

    func testTheFileCarriesNoLayoutForAGroup() throws {
        GroupStore(fileURL: fileURL).save([makeGroup(slot: 3, titles: ["y"])])
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(text.contains("layout"), "a group remembers where its windows are, not a layout (T18)")
    }

    func testAGroupSavedBeforeT15LoadsWithNoArrangement() throws {
        // A file written before the field existed: no `frames` key at all. It
        // must still load — the first recall then records one. An older `layout`
        // is ignored: a group no longer has one (T18).
        let legacy = #"{"version":1,"groups":[{"id":"11111111-1111-1111-1111-111111111111","slot":5,"members":[{"appName":"Safari","title":"Docs"}],"layout":"grid"}]}"#
        try Data(legacy.utf8).write(to: fileURL)

        let group = try XCTUnwrap(GroupStore(fileURL: fileURL).load().first)
        XCTAssertTrue(group.frames.isEmpty)
        XCTAssertFalse(group.hasArrangement)
        XCTAssertEqual(group.members.count, 1)
        XCTAssertEqual(group.members.first?.appName, "Safari")
    }

    func testAnArrangementWithNoFramesIsNotAnArrangement() {
        XCTAssertFalse(WindowGroup(slot: 1).hasArrangement)
    }
}
