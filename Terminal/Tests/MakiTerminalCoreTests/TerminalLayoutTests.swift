import XCTest
@testable import MakiTerminalCore

final class TerminalLayoutTests: XCTestCase {
    private var directory: URL!
    private var store: TerminalLayoutStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiTerminalLayout-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = TerminalLayoutStore(fileURL: directory.appendingPathComponent("workspaces.json"))
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testAMissingFileIsAnEmptyLayout() {
        let snapshot = store.load()
        XCTAssertEqual(snapshot.state, .missing)
        XCTAssertTrue(snapshot.layout.workspaces.isEmpty)
        XCTAssertTrue(snapshot.canSave)
    }

    func testTheLayoutRoundTrips() {
        var first = TerminalWorkspace(title: "One")
        let secondPane = first.split(first.focusedPane, orientation: .sideBySide)!
        first.setDirectory("/tmp", for: secondPane)
        let layout = TerminalLayout(workspaces: [first, TerminalWorkspace(title: "Two")],
                                    selectedIndex: 1)

        XCTAssertTrue(store.save(layout))
        let snapshot = store.load()
        XCTAssertEqual(snapshot.state, .loaded)
        XCTAssertEqual(snapshot.layout, layout)
        XCTAssertEqual(snapshot.layout.selectedIndex, 1)
    }

    func testTheSelectedIndexIsClamped() {
        let layout = TerminalLayout(workspaces: [TerminalWorkspace(title: "One")],
                                    selectedIndex: 9)
        XCTAssertEqual(layout.normalizedSelectedIndex, 0)
        XCTAssertEqual(TerminalLayout(workspaces: [], selectedIndex: 3).normalizedSelectedIndex, 0)
    }

    func testMovingAWorkspaceKeepsTheSameShellSelected() {
        let first = TerminalWorkspace(title: "One")
        let second = TerminalWorkspace(title: "Two")
        let third = TerminalWorkspace(title: "Three")
        let layout = TerminalLayout(workspaces: [first, second, third], selectedIndex: 1)

        let moved = layout.movingWorkspace(from: 0, to: 2)
        XCTAssertEqual(moved.workspaces.map(\.title), ["Two", "Three", "One"])
        XCTAssertEqual(moved.workspaces[moved.selectedIndex].id, second.id)

        let backwards = layout.movingWorkspace(from: 2, to: 0)
        XCTAssertEqual(backwards.workspaces.map(\.title), ["Three", "One", "Two"])
        XCTAssertEqual(backwards.workspaces[backwards.selectedIndex].id, second.id)
    }

    func testMovingTheSelectedWorkspaceFollowsIt() {
        let first = TerminalWorkspace(title: "One")
        let second = TerminalWorkspace(title: "Two")
        let layout = TerminalLayout(workspaces: [first, second], selectedIndex: 1)
        let moved = layout.movingWorkspace(from: 1, to: 0)
        XCTAssertEqual(moved.selectedIndex, 0)
        XCTAssertEqual(moved.workspaces[0].id, second.id)
    }

    func testMovingAWorkspaceNowhereOrOutOfBoundsIsANoOp() {
        let layout = TerminalLayout(workspaces: [TerminalWorkspace(title: "One"),
                                                 TerminalWorkspace(title: "Two")],
                                    selectedIndex: 0)
        XCTAssertEqual(layout.movingWorkspace(from: 1, to: 1), layout)
        XCTAssertEqual(layout.movingWorkspace(from: -1, to: 0), layout)
        XCTAssertEqual(layout.movingWorkspace(from: 0, to: 4), layout)
    }

    func testACorruptFileIsSetAside() throws {
        try Data("not json".utf8).write(to: store.fileURL)
        let snapshot = store.load()
        XCTAssertEqual(snapshot.state, .corrupt)
        XCTAssertTrue(snapshot.layout.workspaces.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.fileURL.appendingPathExtension("bak").path))
    }

    func testANewerFileIsReadOnly() throws {
        let json = #"{"version":99,"workspaces":[],"selectedIndex":0}"#
        try Data(json.utf8).write(to: store.fileURL)

        let snapshot = store.load()
        XCTAssertEqual(snapshot.state, .futureVersion(99))
        XCTAssertFalse(snapshot.canSave)
        XCTAssertFalse(store.save(.init(workspaces: [])))
        XCTAssertFalse(store.remove())
        XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), json)
    }

    func testRemoveDeletesTheFile() {
        XCTAssertTrue(store.save(.init(workspaces: [])))
        XCTAssertTrue(store.remove())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertTrue(store.remove())
    }
}
