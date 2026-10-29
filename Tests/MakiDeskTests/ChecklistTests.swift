import CoreGraphics
import XCTest
@testable import MakiDesk

/// T59: the checklist's rules and its file are values, so the list, the
/// tolerant loading and the placement are checked without a panel or a screen.
final class ChecklistTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDeskChecklist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file() -> ChecklistFile {
        ChecklistFile(fileURL: directory.appendingPathComponent("checklist.json"))
    }

    private func item(_ text: String, done: Bool = false) -> ChecklistItem {
        ChecklistItem(text: text, done: done)
    }

    // MARK: - Adding

    func testAddingTrimsTheTextAndKeepsTheLineBreaks() {
        var list = Checklist()
        list.add("  Buy milk  ")
        list.add("  Call Ana\n  about the car  ")
        XCTAssertEqual(list.items.map(\.text), ["Buy milk", "Call Ana\nabout the car"])
        XCTAssertEqual(list.remaining, 2)
    }

    func testBlankTextAddsNothing() {
        var list = Checklist()
        XCTAssertNil(list.add(""))
        XCTAssertNil(list.add("   \n\t "))
        XCTAssertTrue(list.items.isEmpty)
    }

    func testALongItemIsCappedInsteadOfRefused() {
        var list = Checklist()
        let long = String(repeating: "a", count: Checklist.maxTextLength + 40)
        let added = list.add(long)
        XCTAssertNotNil(added)
        XCTAssertEqual(added?.text.count, Checklist.maxTextLength)
    }

    func testTheListStopsAtItsLimit() {
        var list = Checklist()
        for index in 0..<Checklist.maxItems {
            XCTAssertNotNil(list.add("item \(index)"))
        }
        XCTAssertTrue(list.isFull)
        XCTAssertNil(list.add("one too many"))
        XCTAssertEqual(list.items.count, Checklist.maxItems)
    }

    func testLoadingAManagedListNeverExceedsTheLimit() {
        let many = (0..<(Checklist.maxItems + 10)).map { item("item \($0)") }
        XCTAssertEqual(Checklist(items: many).items.count, Checklist.maxItems)
    }

    // MARK: - Changing

    func testTickingAndUntickingKeepsTheOrder() {
        var list = Checklist()
        list.add("one")
        list.add("two")
        guard let first = list.items.first?.id else { return XCTFail("no item") }
        list.toggle(first)
        XCTAssertTrue(list.items[0].done)
        XCTAssertEqual(list.remaining, 1)
        XCTAssertEqual(list.completed, 1)
        list.toggle(first)
        XCTAssertFalse(list.items[0].done)
        XCTAssertEqual(list.items.map(\.text), ["one", "two"])
    }

    func testMovingStopsAtBothEnds() {
        var list = Checklist()
        list.add("one")
        list.add("two")
        let first = list.items[0].id
        let last = list.items[1].id
        XCTAssertFalse(list.move(first, by: -1))
        XCTAssertFalse(list.move(last, by: 1))
        XCTAssertFalse(list.move(first, by: 0))
        XCTAssertTrue(list.move(last, by: -1))
        XCTAssertEqual(list.items.map(\.text), ["two", "one"])
        XCTAssertTrue(list.move(first, by: -1))
        XCTAssertEqual(list.items.map(\.text), ["one", "two"])
    }

    func testRemovingOneItemLeavesTheRest() {
        var list = Checklist()
        list.add("one")
        list.add("two")
        list.remove(list.items[0].id)
        XCTAssertEqual(list.items.map(\.text), ["two"])
        list.remove(UUID())
        XCTAssertEqual(list.items.count, 1)
    }

    func testClearingCompletedReportsHowManyWent() {
        var list = Checklist()
        list.add("one")
        list.add("two")
        list.add("three")
        list.toggle(list.items[0].id)
        list.toggle(list.items[2].id)
        XCTAssertEqual(list.clearCompleted(), 2)
        XCTAssertEqual(list.items.map(\.text), ["two"])
        XCTAssertEqual(list.clearCompleted(), 0)
    }

    // MARK: - File

    func testTheListSurvivesARoundTrip() throws {
        var list = Checklist()
        list.add("Buy milk")
        list.add("Call Ana")
        list.toggle(list.items[1].id)
        let file = file()
        XCTAssertTrue(file.save(list.items))
        XCTAssertEqual(Checklist(items: file.load()), list)
    }

    func testAFullFileRoundTripsTheLimit() {
        let many = (0..<Checklist.maxItems).map { item("item \($0)") }
        let file = file()
        XCTAssertTrue(file.save(many))
        XCTAssertEqual(file.load().count, Checklist.maxItems)
    }

    func testAMissingFileIsAnEmptyList() {
        XCTAssertTrue(file().load().isEmpty)
    }

    func testAnUnreadableFileIsSetAsideAndTheListStartsEmpty() throws {
        let file = file()
        try Data("not json at all".utf8).write(to: file.fileURL)
        XCTAssertTrue(file.load().isEmpty)
        let aside = file.fileURL.appendingPathExtension("bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.fileURL.path))
    }

    func testAnOlderFileWithoutSomeFieldsStillLoads() throws {
        let file = file()
        let json = """
        { "version": 1, "items": [ { "text": "just the text" }, { "extra": 1 } ] }
        """
        try Data(json.utf8).write(to: file.fileURL)
        let items = file.load()
        // The second entry has no text and is dropped: a filler is not a task.
        XCTAssertEqual(items.map(\.text), ["just the text"])
        XCTAssertEqual(items.first?.done, false)
    }

    func testASaveReplacesTheFileAtomically() throws {
        let file = file()
        XCTAssertTrue(file.save([item("one")]))
        XCTAssertTrue(file.save([item("two")]))
        XCTAssertEqual(file.load().map(\.text), ["two"])
        // No temporary file is left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(leftovers, ["checklist.json"])
    }

    // MARK: - Placement and limits

    func testOpacityAndWidthAreClamped() {
        XCTAssertEqual(ChecklistSettings.clampedOpacity(0), ChecklistSettings.opacityRange.lowerBound)
        XCTAssertEqual(ChecklistSettings.clampedOpacity(2), 1)
        XCTAssertEqual(ChecklistSettings.clampedWidth(10), ChecklistSettings.widthRange.lowerBound)
        XCTAssertEqual(ChecklistSettings.clampedWidth(9000), ChecklistSettings.widthRange.upperBound)
    }

    func testTheOpacityIsTheSettingUntilTheCardIsUsed() {
        // Waiting: the chosen opacity.
        XCTAssertEqual(ChecklistSettings.alpha(opacity: 0.5, revealed: false,
                                               reduceTransparency: false), 0.5)
        // Pointed at, or typing in it: solid.
        XCTAssertEqual(ChecklistSettings.alpha(opacity: 0.5, revealed: true,
                                               reduceTransparency: false), 1)
        // Reduce Transparency: solid whatever the setting says.
        XCTAssertEqual(ChecklistSettings.alpha(opacity: 0.3, revealed: false,
                                               reduceTransparency: true), 1)
        // The range still applies at rest.
        XCTAssertEqual(ChecklistSettings.alpha(opacity: 0.1, revealed: false,
                                               reduceTransparency: false),
                       CGFloat(ChecklistSettings.opacityRange.lowerBound))
    }

    func testTheEdgeMarginIsHalfTheWindowGap() {
        XCTAssertEqual(ChecklistSettings.edgeMargin(forGap: 12), 6)
        XCTAssertEqual(ChecklistSettings.edgeMargin(forGap: 48), 24)
        XCTAssertEqual(ChecklistSettings.edgeMargin(forGap: 0), 0)
        // A negative or absurd gap cannot push the card or the window away.
        XCTAssertEqual(ChecklistSettings.edgeMargin(forGap: -10), 0)
        XCTAssertEqual(ChecklistSettings.edgeMargin(forGap: 500), 40)
    }

    func testThePanelStaysInItsCornerOnANegativeOriginDisplay() {
        let screen = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let size = CGSize(width: 320, height: 200)
        for position in HUDPosition.allCases {
            let frame = ChecklistSettings.frame(for: size, position: position,
                                                screen: screen, margin: 12)
            XCTAssertTrue(screen.contains(frame), position.label)
            XCTAssertEqual(frame.size, size)
        }
        let topRight = ChecklistSettings.frame(for: size, position: .topRight,
                                               screen: screen, margin: 12)
        XCTAssertEqual(topRight.maxX, screen.maxX - 12)
        XCTAssertEqual(topRight.maxY, screen.maxY - 12)
    }

    func testThePanelKeepsTheWindowGapFromTheEdges() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 320, height: 200)
        for gap in [0.0, 12.0, 32.0] {
            // A tiled window keeps half the gap from the edge.
            let edge = ChecklistSettings.edgeMargin(forGap: gap)
            for position in HUDPosition.allCases {
                let frame = ChecklistSettings.frame(for: size, position: position,
                                                    screen: screen, margin: edge)
                switch position {
                case .topRight:
                    XCTAssertEqual(frame.maxX, screen.maxX - edge, accuracy: 0.5)
                    XCTAssertEqual(frame.maxY, screen.maxY - edge, accuracy: 0.5)
                case .bottomRight:
                    XCTAssertEqual(frame.maxX, screen.maxX - edge, accuracy: 0.5)
                    XCTAssertEqual(frame.minY, screen.minY + edge, accuracy: 0.5)
                case .topCenter:
                    XCTAssertEqual(frame.maxY, screen.maxY - edge, accuracy: 0.5)
                case .bottomCenter:
                    XCTAssertEqual(frame.minY, screen.minY + edge, accuracy: 0.5)
                }
            }
        }
        // A negative margin is not a reason to put the card off the display.
        let clamped = ChecklistSettings.frame(for: size, position: .topRight,
                                              screen: screen, margin: -20)
        XCTAssertTrue(screen.contains(clamped))
    }
}
