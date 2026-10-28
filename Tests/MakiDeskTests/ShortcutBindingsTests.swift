import Carbon.HIToolbox
import XCTest
@testable import MakiDesk

/// T53 phase 2: the persisted table, its validation and the catalog that reads
/// it. Everything here is pure: no Carbon hot key is registered.
final class ShortcutBindingsTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDeskShortcuts-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private var globalDefinitions: [ShortcutDefinition] { ShortcutDefinitions.global }

    private func binding(_ key: Int, _ modifiers: Int = ShortcutDefinitions.ctrlOpt) -> ShortcutBinding {
        ShortcutBinding(keyCode: key, modifiers: modifiers)
    }

    // MARK: - Defaults

    func testDefaultsAreTheTable() {
        let bindings = ShortcutBindings.defaults
        for definition in globalDefinitions {
            XCTAssertEqual(bindings.binding(for: definition.id),
                           ShortcutBindings.defaultTable[definition.id],
                           definition.id)
            XCTAssertFalse(bindings.isModified(definition.id), definition.id)
            XCTAssertFalse(bindings.isDisabled(definition.id), definition.id)
        }
        XCTAssertEqual(bindings.modifiedCount, 0)
    }

    func testInformationalRowsHaveNoBindingAndCannotBeEdited() {
        let info = ShortcutDefinitions.all.first { !$0.isGlobal }
        guard let info else { return XCTFail("the table has no informational row") }
        var bindings = ShortcutBindings.defaults
        XCTAssertNil(bindings.binding(for: info.id))
        bindings.set(binding(kVK_ANSI_X), for: info.id)
        XCTAssertFalse(bindings.isModified(info.id), "an informational row cannot be remapped")
    }

    // MARK: - Editing

    func testRecordingACombinationChangesTheRowOnly() {
        var bindings = ShortcutBindings.defaults
        let recorded = binding(kVK_ANSI_X)
        bindings.set(recorded, for: "window.left")

        XCTAssertEqual(bindings.binding(for: "window.left"), recorded)
        XCTAssertEqual(bindings.display(for: "window.left"), "⌃⌥X")
        XCTAssertTrue(bindings.isModified("window.left"))
        XCTAssertEqual(bindings.modifiedCount, 1)
        XCTAssertEqual(bindings.binding(for: "window.right"),
                       ShortcutBindings.defaultTable["window.right"])
    }

    func testRecordingTheDefaultLeavesNoOverride() {
        var bindings = ShortcutBindings.defaults
        guard let original = bindings.binding(for: "window.left") else {
            return XCTFail("missing default")
        }
        bindings.set(binding(kVK_ANSI_X), for: "window.left")
        bindings.set(original, for: "window.left")
        XCTAssertFalse(bindings.isModified("window.left"))
        XCTAssertEqual(bindings.modifiedCount, 0)
    }

    func testTurnOffAndRestore() {
        var bindings = ShortcutBindings.defaults
        bindings.disable("window.left")
        XCTAssertTrue(bindings.isDisabled("window.left"))
        XCTAssertNil(bindings.binding(for: "window.left"))
        XCTAssertNil(bindings.display(for: "window.left"))

        bindings.restore("window.left")
        XCTAssertFalse(bindings.isDisabled("window.left"))
        XCTAssertEqual(bindings.binding(for: "window.left"),
                       ShortcutBindings.defaultTable["window.left"])
    }

    func testRestoreAllDropsEveryOverride() {
        var bindings = ShortcutBindings.defaults
        bindings.set(binding(kVK_ANSI_X), for: "window.left")
        bindings.disable("window.right")
        XCTAssertEqual(bindings.modifiedCount, 2)
        bindings.restoreAll()
        XCTAssertEqual(bindings, .defaults)
    }

    // MARK: - Validation

    func testACombinationNeedsControlOrOption() {
        var bindings = ShortcutBindings.defaults
        XCTAssertEqual(bindings.validationError(for: binding(kVK_ANSI_X, 0), for: "window.left"),
                       .needsGlobalModifier)
        XCTAssertEqual(bindings.validationError(for: binding(kVK_ANSI_X, cmdKey), for: "window.left"),
                       .needsGlobalModifier)
        XCTAssertEqual(bindings.validationError(for: binding(kVK_ANSI_X, shiftKey), for: "window.left"),
                       .needsGlobalModifier)
        XCTAssertNil(bindings.validationError(for: binding(kVK_ANSI_X, cmdKey | shiftKey | optionKey),
                                              for: "window.left"))
        bindings.disable("window.left")
    }

    func testANonPositiveKeyCodeIsRejected() {
        let bindings = ShortcutBindings.defaults
        XCTAssertEqual(bindings.validationError(for: binding(0), for: "window.left"), .noKey)
    }

    func testThePeekHoldCombinationIsReserved() {
        let bindings = ShortcutBindings.defaults
        let reserved = ShortcutBinding(keyCode: kVK_ANSI_H, modifiers: ShortcutDefinitions.ctrlOpt)
        XCTAssertEqual(bindings.validationError(for: reserved, for: "window.left"),
                       .reserved(ShortcutBindings.reservedReason))
    }

    func testADuplicateNamesTheRowThatOwnsIt() {
        let bindings = ShortcutBindings.defaults
        guard let taken = bindings.binding(for: "window.left") else {
            return XCTFail("missing default")
        }
        XCTAssertEqual(bindings.validationError(for: taken, for: "window.right"),
                       .conflict("Left column"))
    }

    func testTheSameCombinationIsFineForItsOwnRow() {
        let bindings = ShortcutBindings.defaults
        guard let own = bindings.binding(for: "window.left") else {
            return XCTFail("missing default")
        }
        XCTAssertNil(bindings.validationError(for: own, for: "window.left"))
    }

    // MARK: - Tolerant file

    func testSanitizedDropsWhatCannotWork() {
        let overrides: [String: ShortcutOverride] = [
            "nope": ShortcutOverride(binding: binding(kVK_ANSI_X)),
            "window.left": ShortcutOverride(binding: binding(0)),
            "window.right": ShortcutOverride(binding: binding(kVK_ANSI_X, cmdKey)),
            "window.top": ShortcutOverride(binding: binding(kVK_ANSI_X)),
            "window.bottom": ShortcutOverride(binding: ShortcutBindings.defaultTable["window.bottom"]!),
            "layout.grid": ShortcutOverride(disabled: true),
        ]
        let clean = ShortcutBindings.sanitized(overrides)
        XCTAssertNil(clean["nope"])
        XCTAssertNil(clean["window.left"], "a zero key code is dropped")
        XCTAssertNil(clean["window.right"], "⌘ alone is dropped")
        XCTAssertEqual(clean["window.top"]?.binding, binding(kVK_ANSI_X))
        XCTAssertNil(clean["window.bottom"], "a row that repeats its default stores nothing")
        XCTAssertEqual(clean["layout.grid"]?.isDisabled, true)
    }

    // MARK: - Store

    func testRoundTripKeepsTheTable() throws {
        let store = ShortcutStore(fileURL: directory.appendingPathComponent("shortcuts.json"))
        var bindings = ShortcutBindings.defaults
        bindings.set(binding(kVK_ANSI_X), for: "window.left")
        bindings.disable("window.right")

        if case let .failure(error) = store.save(bindings) {
            return XCTFail("save failed: \(error)")
        }
        let snapshot = store.load()
        XCTAssertEqual(snapshot.state, .loaded)
        XCTAssertEqual(snapshot.bindings, bindings)
        XCTAssertEqual(snapshot.version, ShortcutStore.currentVersion)

        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("window.left"))
        XCTAssertTrue(text.contains("disabled"))
    }

    func testAMissingFileMeansTheDefaults() {
        let store = ShortcutStore(fileURL: directory.appendingPathComponent("shortcuts.json"))
        let snapshot = store.load()
        XCTAssertEqual(snapshot.state, .missing)
        XCTAssertEqual(snapshot.bindings, .defaults)
    }

    func testACorruptFileIsSetAsideAndTheDefaultsAreUsed() throws {
        let url = directory.appendingPathComponent("shortcuts.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)

        let snapshot = ShortcutStore(fileURL: url).load()
        XCTAssertEqual(snapshot.state, .corrupt)
        XCTAssertEqual(snapshot.bindings, .defaults)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "the unreadable file is moved aside, not overwritten")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
    }

    func testAFileFromANewerVersionIsReadOnly() throws {
        let url = directory.appendingPathComponent("shortcuts.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"version":99,"bindings":{"window.left":{"key":1,"modifiers":1179648}}}"#.utf8)
            .write(to: url)

        let store = ShortcutStore(fileURL: url)
        let snapshot = store.load()
        XCTAssertEqual(snapshot.state, .futureVersion(99))
        XCTAssertEqual(snapshot.bindings, .defaults)
        XCTAssertFalse(snapshot.canSave)
        if case .failure = store.save(.defaults) {
            // expected: the newer file is never touched
        } else {
            XCTFail("a newer file must not be overwritten")
        }
    }

    func testUnknownRowsAndInvalidValuesAreDroppedOnLoad() throws {
        let url = directory.appendingPathComponent("shortcuts.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
        {"version":1,"bindings":{
          "nope":{"key":1,"modifiers":6144},
          "window.left":{"key":0,"modifiers":6144},
          "window.top":{"key":7,"modifiers":6144}
        }}
        """
        try Data(json.utf8).write(to: url)

        let snapshot = ShortcutStore(fileURL: url).load()
        XCTAssertEqual(snapshot.state, .loaded)
        XCTAssertNil(snapshot.bindings.overrides["nope"])
        XCTAssertNil(snapshot.bindings.overrides["window.left"])
        XCTAssertEqual(snapshot.bindings.overrides["window.top"]?.binding,
                       ShortcutBinding(keyCode: 7, modifiers: ShortcutDefinitions.ctrlOpt))
    }

    // MARK: - Catalog and menu

    func testTheCatalogShowsTheRecordedCombination() {
        var bindings = ShortcutBindings.defaults
        bindings.set(binding(kVK_ANSI_X), for: "window.left")
        bindings.disable("window.right")

        let rows = ShortcutCatalog.sections(bindings: bindings).flatMap(\.items)
        let left = rows.first { $0.identifier == "window.left" }
        XCTAssertEqual(left?.keys, "⌃⌥X")
        XCTAssertEqual(left?.isModified, true)
        XCTAssertEqual(left?.isRemappable, true)

        let right = rows.first { $0.identifier == "window.right" }
        XCTAssertEqual(right?.keys, "Off")
        XCTAssertEqual(right?.isDisabled, true)
        XCTAssertEqual(right?.note?.contains("Turned off"), true)
    }

    func testTheCatalogMarksABlockedRow() {
        let rows = ShortcutCatalog.sections(blocked: ["window.left"]).flatMap(\.items)
        let left = rows.first { $0.identifier == "window.left" }
        XCTAssertEqual(left?.isBlocked, true)
        XCTAssertEqual(left?.note?.contains("In use by another app"), true)
    }

    func testTheMenuLabelFollowsTheTable() {
        var bindings = ShortcutBindings.defaults
        XCTAssertEqual(ShortcutManager.display(for: .openSettings, bindings: bindings), "⌃⌥,")
        bindings.set(binding(kVK_ANSI_X), for: "app.settings")
        XCTAssertEqual(ShortcutManager.display(for: .openSettings, bindings: bindings), "⌃⌥X")
        bindings.disable("app.settings")
        XCTAssertNil(ShortcutManager.display(for: .openSettings, bindings: bindings))
    }
}
