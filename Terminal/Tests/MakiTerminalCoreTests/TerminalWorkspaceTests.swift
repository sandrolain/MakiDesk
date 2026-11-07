import XCTest
@testable import MakiTerminalCore

final class TerminalWorkspaceTests: XCTestCase {
    func testANewWorkspaceHasOneFocusedPane() {
        let workspace = TerminalWorkspace(title: "Workspace 1")
        XCTAssertEqual(workspace.paneCount, 1)
        XCTAssertEqual(workspace.paneIDs, [workspace.focusedPane])
        XCTAssertTrue(workspace.contains(workspace.focusedPane))
    }

    func testSplittingAddsAPaneAndFocusesIt() throws {
        var workspace = TerminalWorkspace(title: "Workspace 1")
        let original = workspace.focusedPane
        let newPane = try XCTUnwrap(workspace.split(original, orientation: .sideBySide))

        XCTAssertEqual(workspace.paneCount, 2)
        XCTAssertEqual(workspace.focusedPane, newPane)
        guard case let .split(orientation, ratio, first, second) = workspace.root else {
            return XCTFail("root should be a split")
        }
        XCTAssertEqual(orientation, .sideBySide)
        XCTAssertEqual(ratio, 0.5, accuracy: 0.001)
        XCTAssertEqual(first, .pane(original))
        XCTAssertEqual(second, .pane(newPane))
    }

    func testSplittingANestedPaneKeepsTheOuterOrientation() throws {
        var workspace = TerminalWorkspace(title: "Workspace 1")
        let first = workspace.focusedPane
        let second = try XCTUnwrap(workspace.split(first, orientation: .sideBySide))
        let third = try XCTUnwrap(workspace.split(second, orientation: .stacked))

        XCTAssertEqual(workspace.paneCount, 3)
        guard case let .split(outerOrientation, _, outerFirst, outerSecond) = workspace.root else {
            return XCTFail("root should be a split")
        }
        XCTAssertEqual(outerOrientation, .sideBySide)
        XCTAssertEqual(outerFirst, .pane(first))
        guard case let .split(innerOrientation, _, innerFirst, innerSecond) = outerSecond else {
            return XCTFail("second child should be a split")
        }
        XCTAssertEqual(innerOrientation, .stacked)
        XCTAssertEqual(innerFirst, .pane(second))
        XCTAssertEqual(innerSecond, .pane(third))
    }

    func testRemovingTheFirstChildPromotesTheSecond() throws {
        var workspace = TerminalWorkspace(title: "Workspace 1")
        let first = workspace.focusedPane
        let second = try XCTUnwrap(workspace.split(first, orientation: .sideBySide))

        XCTAssertTrue(workspace.remove(first))
        XCTAssertEqual(workspace.root, .pane(second))
        XCTAssertEqual(workspace.focusedPane, second)
        XCTAssertEqual(workspace.paneCount, 1)
    }

    func testRemovingTheSecondChildPromotesTheFirst() throws {
        var workspace = TerminalWorkspace(title: "Workspace 1")
        let first = workspace.focusedPane
        let second = try XCTUnwrap(workspace.split(first, orientation: .sideBySide))

        XCTAssertTrue(workspace.remove(second))
        XCTAssertEqual(workspace.root, .pane(first))
        XCTAssertEqual(workspace.focusedPane, first)
    }

    func testTheLastPaneCannotBeRemoved() {
        var workspace = TerminalWorkspace(title: "Workspace 1")
        XCTAssertFalse(workspace.remove(workspace.focusedPane))
        XCTAssertEqual(workspace.paneCount, 1)
    }

    func testRemovingAnUnknownPaneDoesNothing() {
        var workspace = TerminalWorkspace(title: "Workspace 1")
        let before = workspace.root
        XCTAssertFalse(workspace.remove(PaneID()))
        XCTAssertEqual(workspace.root, before)
    }

    func testNestedRemovalKeepsTheSibling() throws {
        var workspace = TerminalWorkspace(title: "Workspace 1")
        let first = workspace.focusedPane
        let second = try XCTUnwrap(workspace.split(first, orientation: .sideBySide))
        let third = try XCTUnwrap(workspace.split(second, orientation: .stacked))

        XCTAssertTrue(workspace.remove(second))
        XCTAssertEqual(workspace.paneIDs, [first, third])
        XCTAssertFalse(workspace.contains(second))
    }

    func testFocusOnlyAcceptsPanesInTheWorkspace() {
        var workspace = TerminalWorkspace(title: "Workspace 1")
        let first = workspace.focusedPane
        let second = try! XCTUnwrap(workspace.split(first, orientation: .stacked))
        XCTAssertTrue(workspace.focus(first))
        XCTAssertEqual(workspace.focusedPane, first)
        XCTAssertFalse(workspace.focus(PaneID()))
        XCTAssertEqual(workspace.focusedPane, first)
        XCTAssertTrue(workspace.focus(second))
    }

    func testRatiosAreClampedAndTargetedByPath() throws {
        var workspace = TerminalWorkspace(title: "Workspace 1")
        let first = workspace.focusedPane
        let second = try XCTUnwrap(workspace.split(first, orientation: .sideBySide))
        _ = workspace.split(second, orientation: .stacked)

        XCTAssertTrue(workspace.setRatio(0.3, at: []))
        guard case let .split(_, ratio, _, _) = workspace.root else {
            return XCTFail("root should be a split")
        }
        XCTAssertEqual(ratio, 0.3, accuracy: 0.001)

        XCTAssertTrue(workspace.setRatio(0.9, at: [1]))
        guard case let .split(_, _, _, .split(_, innerRatio, _, _)) = workspace.root else {
            return XCTFail("second child should be a split")
        }
        XCTAssertEqual(innerRatio, 0.85, accuracy: 0.001)
        XCTAssertFalse(workspace.setRatio(0.5, at: [0]))
    }

    func testDirectoriesFollowThePane() throws {
        var workspace = TerminalWorkspace(title: "Workspace 1")
        let pane = workspace.focusedPane
        workspace.setDirectory("/tmp", for: pane)
        XCTAssertEqual(workspace.directory(for: pane), "/tmp")
        XCTAssertNil(workspace.directory(for: PaneID()))

        XCTAssertTrue(workspace.remove(pane) == false)
        workspace.setDirectory("", for: pane)
        XCTAssertEqual(workspace.directory(for: pane), "/tmp")
    }

    func testACommandFollowsThePaneAndItsRemoval() throws {
        var workspace = TerminalWorkspace(title: "Workspace 1")
        let pane = workspace.focusedPane
        workspace.setCommand("ssh deploy@example.com", for: pane)
        XCTAssertEqual(workspace.command(for: pane), "ssh deploy@example.com")

        let other = try XCTUnwrap(workspace.split(pane, orientation: .stacked))
        workspace.setCommand("   ", for: other)
        XCTAssertNil(workspace.command(for: other))

        _ = workspace.remove(pane)
        XCTAssertNil(workspace.command(for: pane))
    }

    func testTheLayoutRoundTripsThroughJSON() throws {
        var workspace = TerminalWorkspace(title: "Workspace 1")
        let first = workspace.focusedPane
        let second = try XCTUnwrap(workspace.split(first, orientation: .sideBySide))
        workspace.setDirectory("/Users/example", for: second)
        workspace.setCommand("ssh deploy@example.com", for: second)
        workspace.title = "Project"

        let data = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(TerminalWorkspace.self, from: data)
        XCTAssertEqual(decoded, workspace)
    }
}
