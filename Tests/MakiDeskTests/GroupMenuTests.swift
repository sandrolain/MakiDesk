import XCTest
@testable import MakiDesk

/// G4/T23: the group API the menu bar and Settings read — renaming (a blank name
/// going back to "Group N"), the labels and empty checks, and what the factory
/// reset does with the groups: kept by default, cleared when the confirmation
/// asks for it.
final class GroupMenuTests: XCTestCase {
    private var directory: URL!
    private var store: WorkspaceStore!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("makidesk-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = WorkspaceStore()
        store.groupStore = GroupStore(fileURL: directory.appendingPathComponent("groups.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        store = nil
    }

    private func makeRef(_ id: String, _ title: String) -> MakiDesk.WindowRef {
        MakiDesk.WindowRef(identity: MakiDesk.WindowIdentity(id: id, bundleId: "com.example.app",
                                                              appName: "Example", title: title, document: nil))
    }

    func testRenameTrimsAndPersists() {
        store.renameGroup(slot: 3, name: "  Writing  ")
        XCTAssertEqual(store.groupName(3), "Writing")
        XCTAssertEqual(store.groupStore.load().first { $0.slot == 3 }?.name, "Writing")
    }

    func testBlankNameGoesBackToTheDefaultNumber() {
        store.renameGroup(slot: 3, name: "Writing")
        store.renameGroup(slot: 3, name: "   ")
        XCTAssertEqual(store.groupName(3), "Group 3")
        XCTAssertNil(store.groupStore.load().first { $0.slot == 3 }?.name)
    }

    func testRenameIgnoresSlotsOutsideOneToNine() {
        store.renameGroup(slot: 0, name: "Nope")
        store.renameGroup(slot: 10, name: "Nope")
        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertTrue(store.groupStore.load().isEmpty)
    }

    func testMenuLabelSaysTheCountWhenThereAreMembers() {
        store.groups[2] = WindowGroup(slot: 2, members: [makeRef("2-cg1", "One"), makeRef("2-cg2", "Two")])
        store.renameGroup(slot: 2, name: "Reading")
        XCTAssertEqual(store.groupMenuLabel(2), "Reading · 2")
        XCTAssertFalse(store.groupIsEmpty(2))
    }

    func testMenuLabelOfAnEmptyGroupHasNoCount() {
        XCTAssertEqual(store.groupMenuLabel(4), "Group 4")
        XCTAssertTrue(store.groupIsEmpty(4))
        XCTAssertTrue(store.groupIsEmpty(99))
    }

    func testResetToDefaultsKeepsGroups() {
        store.groups[5] = WindowGroup(slot: 5, members: [makeRef("5-cg1", "Doc")])
        store.renameGroup(slot: 5, name: "Focus")
        // Keep the reset from asking for the Screen Recording permission dialog.
        store.screenRecordingTrusted = true
        store.resetToDefaults()
        XCTAssertEqual(store.groupName(5), "Focus")
        XCTAssertEqual(store.groups[5]?.members.count, 1)
        XCTAssertEqual(store.groupStore.load().count, 1)
    }

    /// T23: the groups go only when the confirmation asks for them, and they go
    /// with everything that belongs to them — members and arrangement, in memory
    /// and on disk.
    func testResetCanAlsoClearTheGroups() {
        var group = WindowGroup(slot: 5, members: [makeRef("5-cg1", "Doc")])
        group.frames["5-cg1"] = CGRect(x: 10, y: 20, width: 300, height: 200)
        store.groups[5] = group
        store.renameGroup(slot: 5, name: "Focus")       // writes the file
        XCTAssertEqual(store.groupStore.load().count, 1)

        store.resetToDefaults(scope: [.settings, .groups])
        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertEqual(store.groupName(5), "Group 5")
        XCTAssertTrue(store.groupStore.load().isEmpty)
    }

    /// A reset that clears nothing but the groups still resets the settings:
    /// the scope adds, it never replaces.
    func testResetOfGroupsAloneLeavesTheSettingsAlone() {
        store.updateGap(37)
        store.groups[5] = WindowGroup(slot: 5, members: [makeRef("5-cg1", "Doc")])
        store.resetToDefaults(scope: .groups)
        XCTAssertEqual(store.gap, 37)
        XCTAssertTrue(store.groups.isEmpty)
    }

    func testAGroupStoresWhereItsWindowsAreAndNoLayout() throws {
        var group = WindowGroup(slot: 4, members: [makeRef("4-cg1", "Doc")])
        group.frames["4-cg1"] = CGRect(x: 10, y: 20, width: 300, height: 200)
        store.groups[4] = group
        store.renameGroup(slot: 4, name: "Writing")      // commits to disk

        let written = try String(contentsOf: store.groupStore.fileURL, encoding: .utf8)
        XCTAssertFalse(written.contains("layout"), "a group has no layout of its own (T18)")
        let loaded = try XCTUnwrap(store.groupStore.load().first { $0.slot == 4 })
        XCTAssertEqual(loaded.frames["4-cg1"], CGRect(x: 10, y: 20, width: 300, height: 200))
        XCTAssertTrue(loaded.hasArrangement)
    }
}
