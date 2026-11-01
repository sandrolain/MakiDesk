import Carbon.HIToolbox
import XCTest
@testable import MakiDesk

/// T53: the single shortcut table, the rule between families, and the catalog
/// generated from it.
final class ShortcutDefinitionsTests: XCTestCase {
    private var globalDefinitions: [ShortcutDefinition] {
        ShortcutDefinitions.all.filter(\.isGlobal)
    }

    func testEveryGlobalRowHasAKeyAndAnAction() {
        for definition in ShortcutDefinitions.all {
            if definition.isGlobal {
                XCTAssertNotNil(definition.keyCode, definition.id)
                XCTAssertNotNil(definition.action, definition.id)
                XCTAssertFalse(definition.display.isEmpty, definition.id)
            } else {
                XCTAssertNil(definition.keyCode, definition.id)
                XCTAssertNil(definition.action, definition.id)
                XCTAssertFalse(definition.display.isEmpty, definition.id)
            }
        }
    }

    func testIdentifiersAreUnique() {
        let ids = ShortcutDefinitions.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testBaseCombinationsAreRegisteredOnce() {
        var seen = Set<String>()
        for definition in globalDefinitions {
            let combination = "\(definition.keyCode ?? -1)|\(definition.modifiers)"
            XCTAssertTrue(seen.insert(combination).inserted,
                          "duplicate hot key in \(definition.id)")
        }
    }

    func testGroupsStayOnDigitsAndTheModifierRuleHolds() {
        let recall = (1...9).compactMap { slot in
            ShortcutDefinitions.all.first { $0.action == .recallGroup(slot) }
        }
        XCTAssertEqual(recall.count, 9)
        XCTAssertEqual(recall.first?.modifiers, ShortcutDefinitions.ctrlOpt)
        XCTAssertEqual(recall.first?.display, "⌃⌥1")

        let assign = ShortcutDefinitions.all.first { $0.action == .assignToGroup(1) }
        XCTAssertEqual(assign?.display, "⌃⌥⌘1")

        // Panels use ⌥; actions use ⌃⌥. A letter may repeat between families,
        // because the prefix says where: ⌃⌥⌘V sends the front window away.
        let panelKeys = ShortcutDefinitions.all
            .filter { $0.section == "Panels" }
            .map { $0.display }
        XCTAssertTrue(panelKeys.contains("⌥N"))
        XCTAssertTrue(panelKeys.contains("⌥V"))
        let putAway = ShortcutDefinitions.all.first { $0.action == .putAwayFront }
        XCTAssertEqual(putAway?.display, "⌃⌥⌘V")
    }

    func testDisplayStrings() {
        XCTAssertEqual(ShortcutDisplay.string(keyCode: kVK_LeftArrow,
                                              modifiers: ShortcutDefinitions.ctrlOpt), "⌃⌥←")
        XCTAssertEqual(ShortcutDisplay.string(keyCode: kVK_Tab, modifiers: optionKey), "⌥⇥")
        XCTAssertEqual(ShortcutDisplay.string(keyCode: kVK_Space, modifiers: optionKey), "⌥Space")
        XCTAssertEqual(ShortcutDisplay.string(keyCode: 999, modifiers: 0), "Key 999")
    }

    func testSettingsAndShortcutsHaveTheirOwnKeys() {
        XCTAssertEqual(ShortcutManager.display(for: .openSettings), "⌃⌥,")
        XCTAssertEqual(ShortcutManager.display(for: .openKeyboardShortcuts), "⌃⌥/")
        XCTAssertEqual(ShortcutManager.display(for: .measureArea), "⌃⌥⇧M")
    }

    // MARK: - Families (S01)

    func testEveryGlobalRowBelongsToAFamily() {
        for definition in globalDefinitions {
            guard let family = definition.family else {
                return XCTFail("\(definition.id) is outside the four families")
            }
            XCTAssertTrue(definition.display.hasPrefix(family.display), definition.id)
        }
    }

    /// `⌥` is the five panels opened all day and nothing else: the price of a
    /// new `⌥`+letter is a character taken from the keyboard (S01).
    func testOptionIsOnlyTheEverydayPanels() {
        let ids = ShortcutDefinitions.all
            .filter { $0.family == .panel }
            .map(\.id)
            .sorted()
        XCTAssertEqual(ids, ["panel.clipboard", "panel.notes", "panel.search",
                             "panel.switcher", "panel.switcherBack"])
    }

    func testShiftMeansTheScreenAndCommandTheDesktop() {
        func display(_ action: WindowController.ShortcutAction) -> String? {
            ShortcutDefinitions.all.first { $0.action == action }?.display
        }
        XCTAssertEqual(display(.captureScreenshot), "⌃⌥⇧S")
        XCTAssertEqual(display(.recognizeText), "⌃⌥⇧O")
        XCTAssertEqual(display(.sampleColor), "⌃⌥⇧E")
        XCTAssertEqual(display(.measureArea), "⌃⌥⇧M")

        XCTAssertEqual(display(.putAwayFront), "⌃⌥⌘V")
        XCTAssertEqual(display(.showEverything), "⌃⌥⌘A")
        XCTAssertEqual(display(.undoStep), "⌃⌥⌘Z")
        XCTAssertEqual(display(.focusSelection), "⌃⌥⌘F")
        XCTAssertEqual(display(.applySuggestedLayout), "⌃⌥⌘↩")
    }

    /// The command box moved off ⌃Space, which macOS gives to the input source:
    /// no row may use ⌃ alone any more.
    func testNoRowUsesControlWithoutOption() {
        for definition in globalDefinitions {
            XCTAssertNotEqual(definition.modifiers, controlKey, definition.id)
        }
        XCTAssertEqual(ShortcutManager.display(for: .runCommand), "⌃⌥R")
        XCTAssertEqual(ShortcutManager.display(for: .newTimer), "⌃⌥T")
    }

    func testCatalogIsGeneratedFromTheTable() {
        let sections = ShortcutCatalog.sections()
        let rows = sections.flatMap(\.items)
        for definition in globalDefinitions {
            guard let row = rows.first(where: { $0.identifier == definition.id }) else {
                return XCTFail("missing catalog row for \(definition.id)")
            }
            XCTAssertEqual(row.title, definition.title)
            XCTAssertEqual(row.keys, definition.display)
        }
        // The local, in-panel rows survive because they are not hot keys.
        XCTAssertTrue(rows.contains { $0.title == "Paste the selected text" })
        XCTAssertTrue(rows.contains { $0.title == "Run the highlighted dropzone" })
    }

    func testBlockedRowsSayWhy() {
        let definition = ShortcutDefinitions.all.first { $0.action == .openSettings }!
        let sections = ShortcutCatalog.sections(blocked: [definition.id])
        let row = sections.flatMap(\.items).first { $0.identifier == definition.id }
        XCTAssertNotNil(row)
        XCTAssertTrue(row?.note?.contains("In use by another app") == true)
    }

    func testInformationalRowsExplainGestures() {
        let gestures = ShortcutDefinitions.all.filter { $0.isGlobal == false }
        XCTAssertTrue(gestures.contains { $0.display == "⌥ + drag" })
        XCTAssertTrue(gestures.contains { $0.display == "hold ⌃⌥H" })
        XCTAssertTrue(gestures.contains { $0.display == "⇧ + drag" })
    }
}
