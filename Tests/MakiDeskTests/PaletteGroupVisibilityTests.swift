import XCTest
@testable import MakiDesk

/// T55: hiding the groups column and muting the informative group notices.
/// The rules are pure, so they are checked without opening a palette or a HUD.
final class PaletteGroupVisibilityTests: XCTestCase {
    // MARK: - Column width

    func testColumnWidthFollowsTheSetting() {
        XCTAssertEqual(PaletteGroupVisibility.columnWidth(showsGroups: true),
                       PaletteLayoutEngine.groupColumnWidth)
        XCTAssertEqual(PaletteGroupVisibility.columnWidth(showsGroups: false), 0)
    }

    func testHidingTheColumnNarrowsThePanelByExactlyItsWidth() {
        let withColumn = PaletteLayoutEngine.metrics(
            itemCount: 5, layout: .compact, columns: 0, maxCardWidth: 250,
            available: CGSize(width: 1440, height: 900),
            groupColumnWidth: PaletteGroupVisibility.columnWidth(showsGroups: true)
        )
        let withoutColumn = PaletteLayoutEngine.metrics(
            itemCount: 5, layout: .compact, columns: 0, maxCardWidth: 250,
            available: CGSize(width: 1440, height: 900),
            groupColumnWidth: PaletteGroupVisibility.columnWidth(showsGroups: false)
        )
        XCTAssertEqual(withoutColumn.groupColumnWidth, 0)
        XCTAssertEqual(withColumn.columns, withoutColumn.columns,
                       "the column never changes the grid's column count")
        XCTAssertEqual(withColumn.layout, withoutColumn.layout)
        XCTAssertEqual(withColumn.panelSize.width - withoutColumn.panelSize.width,
                       PaletteLayoutEngine.groupColumnWidth, accuracy: 0.001)
        XCTAssertEqual(withColumn.panelSize.height, withoutColumn.panelSize.height,
                       accuracy: 0.001)
    }

    // MARK: - Empty groups

    func testOnlyGroupsWithMembersAreListed() {
        let rows = [
            PaletteGroupRow(slot: 1, name: "Writing", memberCount: 3),
            PaletteGroupRow(slot: 2, name: nil, memberCount: 0),
            PaletteGroupRow(slot: 3, name: "Mail", memberCount: 1),
        ]
        XCTAssertEqual(PaletteGroupVisibility.rows(rows, showsEmpty: true).map(\.slot), [1, 2, 3])
        XCTAssertEqual(PaletteGroupVisibility.rows(rows, showsEmpty: false).map(\.slot), [1, 3])
    }

    func testTheFilteredListStillKnowsEveryGroup() {
        // The filter is for the view only: the nine rows stay in the model, so
        // the footer can still name a group that is empty right now.
        let rows = (1...9).map { PaletteGroupRow(slot: $0, name: nil, memberCount: 0) }
        XCTAssertTrue(PaletteGroupVisibility.rows(rows, showsEmpty: false).isEmpty)
        XCTAssertEqual(rows.count, 9)
        XCTAssertEqual(rows.last?.displayName, "Group 9")
    }

    // MARK: - Badges

    func testBadgesBelongToTheColumn() {
        XCTAssertEqual(PaletteGroupVisibility.badges([1, 4], showsGroups: true), [1, 4])
        XCTAssertEqual(PaletteGroupVisibility.badges([1, 4], showsGroups: false), [])
    }

    // MARK: - Notices

    func testInformativeNoticesCanBeMutedButOutcomesCannot() {
        let on = GroupNoticePolicy(announcesChanges: true)
        let off = GroupNoticePolicy(announcesChanges: false)

        XCTAssertTrue(on.shows(.change))
        XCTAssertTrue(on.shows(.outcome))

        XCTAssertFalse(off.shows(.change), "adding or removing a member stays quiet")
        XCTAssertTrue(off.shows(.outcome), "asking for an empty group is still answered")
    }
}
