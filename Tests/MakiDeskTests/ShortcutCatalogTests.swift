import XCTest
@testable import MakiDesk

final class ShortcutCatalogTests: XCTestCase {
    func testEverySectionAndCommandIsComplete() {
        XCTAssertFalse(ShortcutCatalog.sections.isEmpty)

        var sectionIDs = Set<String>()
        var total = 0
        for section in ShortcutCatalog.sections {
            XCTAssertTrue(sectionIDs.insert(section.id).inserted,
                          "duplicate section \(section.title)")
            XCTAssertFalse(section.items.isEmpty, "\(section.title) has no commands")

            var itemIDs = Set<String>()
            for item in section.items {
                XCTAssertFalse(item.title.isEmpty, "empty title in \(section.title)")
                XCTAssertFalse(item.keys.isEmpty, "\(item.title) has no keys")
                XCTAssertTrue(itemIDs.insert(item.id).inserted,
                              "duplicate \(item.title) in \(section.title)")
                total += 1
            }
        }

        XCTAssertGreaterThan(total, 40)
    }
}
