import XCTest
import AppKit
@testable import MakiDesk

/// The group numbers the palette prints on the thumbnails: `groupSlots` turns
/// the saved references back into "this live window is in groups 1 and 3", with
/// each group matched on its own, so a window can appear in several at once.
final class GroupBadgeTests: XCTestCase {
    private var directory: URL!
    private var store: WorkspaceStore!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("makidesk-badges-\(UUID().uuidString)", isDirectory: true)
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

    /// A live window the store can build an identity from. `pid: 0` has no
    /// running application, so the identity carries no bundle id and the
    /// matcher falls to the app-name plus title rung — enough to be exact here.
    private func makeWindow(_ id: String, _ title: String) -> ActionableWindow {
        ActionableWindow(id: id, title: title, appName: "Example", frame: .zero, pid: 0,
                         minimized: false, element: AXUIElementCreateSystemWide(), color: .black,
                         windowID: nil, icon: nil, state: .normal)
    }

    func testAWindowInTwoGroupsCarriesBothNumbers() {
        store.groups[3] = WindowGroup(slot: 3, members: [makeRef("b", "Beta"), makeRef("a", "Alpha")])
        store.groups[1] = WindowGroup(slot: 1, members: [makeRef("a", "Alpha")])
        let badges = store.groupSlots(among: [makeWindow("w1", "Alpha"), makeWindow("w2", "Beta")])
        XCTAssertEqual(badges["w1"], [1, 3], "the window is in two groups and both numbers are listed")
        XCTAssertEqual(badges["w2"], [3])
    }

    func testTheNumbersAreSortedNotInDictionaryOrder() {
        store.groups[7] = WindowGroup(slot: 7, members: [makeRef("a", "Alpha")])
        store.groups[2] = WindowGroup(slot: 2, members: [makeRef("a", "Alpha")])
        XCTAssertEqual(store.groupSlots(among: [makeWindow("w", "Alpha")])["w"], [2, 7])
    }

    func testEmptyGroupsAndUnknownWindowsProduceNoBadges() {
        store.groups[1] = WindowGroup(slot: 1, members: [])
        store.groups[2] = WindowGroup(slot: 2, members: [makeRef("gone", "Elsewhere")])
        XCTAssertTrue(store.groupSlots(among: [makeWindow("w1", "Here")]).isEmpty)
    }

    func testNoGroupsOrNoWindowsMeansNoWork() {
        XCTAssertTrue(store.groupSlots(among: [makeWindow("w1", "Any")]).isEmpty)
        XCTAssertTrue(store.groupSlots(among: []).isEmpty)
    }
}
