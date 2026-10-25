import XCTest
@testable import MakiDesk

/// T44: the editor's pure pieces. The views are exercised by the manual test;
/// these cover the parser, the draft model and the warnings that must not lie.
final class DropzoneEditorTests: XCTestCase {
    private var directory: URL!
    private var store: DropzoneStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDeskDropzoneEditor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = DropzoneStore(fileURL: directory.appendingPathComponent("dropzones.json"))
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func zone(_ name: String = "Echo", line: String = "/bin/echo {paths}") -> DropzoneConfig {
        DropzoneConfig(name: name, command: CommandSpec(line: line))
    }

    // MARK: - Shortcuts catalog

    func testShortcutListParsesNamesAndIdentifiers() {
        let id1 = "11111111-1111-1111-1111-111111111111"
        let id2 = "22222222-2222-2222-2222-222222222222"
        let output = """
        Bravo (\(id1))
        Make a (real) PDF (\(id2))
        Broken line without identifier
        Bad (\(id2))
        Duplicate (\(id1))
        """
        let entries = DropzoneShortcutCatalog.parse(output)
        XCTAssertEqual(entries.map(\.id), [id1, id2])
        XCTAssertEqual(entries.map(\.name), ["Bravo", "Make a (real) PDF"])
    }

    func testShortcutListSortsByNameAndSkipsEmptyInput() {
        let a = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let b = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let entries = DropzoneShortcutCatalog.parse("Zulu (\(b))\nAlpha (\(a))\n")
        XCTAssertEqual(entries.map(\.name), ["Alpha", "Zulu"])
        XCTAssertEqual(DropzoneShortcutCatalog.parse("").count, 0)
    }

    func testShortcutInputFlagFollowsWhatTheZoneAccepts() {
        XCTAssertEqual(DropzoneShortcutCatalog.inputFlag(for: DropzoneAccept(kinds: [.files])),
                       "--input-path {paths}")
        XCTAssertEqual(DropzoneShortcutCatalog.inputFlag(for: DropzoneAccept(kinds: [.images])),
                       "--input-path {paths}")
        XCTAssertEqual(DropzoneShortcutCatalog.inputFlag(for: DropzoneAccept(kinds: [.text])),
                       "--input-path {textfile}")
        XCTAssertEqual(DropzoneShortcutCatalog.inputFlag(for: DropzoneAccept(kinds: [.urls])),
                       "--input-path {urlsfile}")
        XCTAssertEqual(DropzoneShortcutCatalog.inputFlag(for: DropzoneAccept(kinds: [.files, .text])),
                       "--input-path {paths}")
        XCTAssertNil(DropzoneShortcutCatalog.inputFlag(for: DropzoneAccept(kinds: [])))
    }

    // MARK: - Checks

    func testPlaceholderTyposAreFoundButJSONKeysAndKnownNamesAreNot() {
        XCTAssertEqual(DropzoneEditorChecks.placeholderTypos(in: "echo {pathh}"), ["pathh"])
        XCTAssertEqual(DropzoneEditorChecks.suggestion(for: "pathh"), "paths")
        XCTAssertEqual(DropzoneEditorChecks.placeholderTypos(in: "echo {url}"), ["url"])
        XCTAssertEqual(DropzoneEditorChecks.placeholderTypos(in: "echo {counts}"), ["counts"])
        XCTAssertEqual(DropzoneEditorChecks.placeholderTypos(in: "jq '{title}'"), [])
        XCTAssertEqual(DropzoneEditorChecks.placeholderTypos(in: "awk '{print $1}'"), [])
        XCTAssertEqual(DropzoneEditorChecks.placeholderTypos(in: "echo {paths} {textfile}"), [])
        XCTAssertEqual(DropzoneEditorChecks.placeholderTypos(in: "echo {foo}"), [])
        XCTAssertEqual(DropzoneEditorChecks.placeholderTypos(in: "echo {pathh} {pathh}"), ["pathh"])
    }

    func testShortcutArgumentRecognizesOnlyAnArgvShortcutsRun() {
        let id = "11111111-1111-1111-1111-111111111111"
        XCTAssertEqual(DropzoneEditorChecks.shortcutArgument(in: CommandSpec(line: "shortcuts run \(id)")), id)
        XCTAssertEqual(DropzoneEditorChecks.shortcutArgument(in: CommandSpec(line: "/usr/bin/shortcuts run \(id)")), id)
        XCTAssertEqual(DropzoneEditorChecks.shortcutArgument(in: CommandSpec(line: #"shortcuts run "My Shortcut""#)),
                       "My Shortcut")
        XCTAssertNil(DropzoneEditorChecks.shortcutArgument(in: CommandSpec(line: "echo shortcuts run \(id)")))
        XCTAssertNil(DropzoneEditorChecks.shortcutArgument(in: CommandSpec(line: "shortcuts list")))
        XCTAssertNil(DropzoneEditorChecks.shortcutArgument(in: CommandSpec(line: "shortcuts run --input-path \(id)")))
        XCTAssertNil(DropzoneEditorChecks.shortcutArgument(
            in: CommandSpec(line: "shortcuts run \(id)", mode: .shell)))
    }

    func testExecutableWarningFindsExistingCommandsAndReportsMissingOnes() {
        XCTAssertNil(DropzoneEditorChecks.executableWarning(for: CommandSpec(line: "/bin/echo hi")))
        XCTAssertNil(DropzoneEditorChecks.executableWarning(for: CommandSpec(line: "sh -c 'echo hi'")))
        XCTAssertNil(DropzoneEditorChecks.executableWarning(for: CommandSpec(line: "echo hi", mode: .shell)))
        XCTAssertNil(DropzoneEditorChecks.executableWarning(for: CommandSpec(line: "{workdir}/tool")))

        let missing = DropzoneEditorChecks.executableWarning(
            for: CommandSpec(line: "definitely-not-a-command-xyz --flag"))
        XCTAssertNotNil(missing)
        XCTAssertTrue(missing?.contains("definitely-not-a-command-xyz") == true)

        let absent = DropzoneEditorChecks.executableWarning(
            for: CommandSpec(line: "\(directory.path)/nope"))
        XCTAssertTrue(absent?.contains("Command not found") == true)
    }

    func testExecutableWarningDistinguishesNotExecutable() throws {
        let file = directory.appendingPathComponent("plain")
        try "text".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let warning = DropzoneEditorChecks.executableWarning(for: CommandSpec(line: file.path))
        XCTAssertTrue(warning?.contains("Not executable") == true)
    }

    func testEnvironmentTextParsesAndReportsInvalidLines() {
        let parsed = DropzoneEnvironmentText.parse("""
        A=1
        B = two words
        # comment
        not a pair
        C=x=y
        D=
        """)
        XCTAssertEqual(parsed.values, ["A": "1", "B": "two words", "C": "x=y", "D": ""])
        XCTAssertEqual(parsed.invalid, ["not a pair"])
        XCTAssertEqual(DropzoneEnvironmentText.format(["B": "2", "A": "1"]), "A=1\nB=2")
        XCTAssertEqual(DropzoneEnvironmentText.parse("# only a comment\n").values, [:])
    }

    // MARK: - Model

    func testModelStartsFromTheStoreAndSavesAValidDraft() throws {
        let model = DropzoneEditorModel(store: store)
        XCTAssertEqual(model.zones, [])
        XCTAssertNil(model.selection)
        XCTAssertFalse(model.canSave)

        let added = try XCTUnwrap(model.add())
        XCTAssertEqual(model.selection, added.id)
        XCTAssertTrue(model.isDirty)
        XCTAssertFalse(model.save())
        XCTAssertNotNil(model.errorMessage)

        model.zones[0].command.line = "/bin/echo {paths}"
        XCTAssertTrue(model.save())
        XCTAssertFalse(model.isDirty)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Saved")

        let snapshot = store.load()
        XCTAssertEqual(snapshot.state, .loaded)
        XCTAssertEqual(snapshot.zones.count, 1)
        XCTAssertEqual(snapshot.zones[0].command.line, "/bin/echo {paths}")
    }

    func testInvalidZoneBlocksTheSaveAndSelectsIt() throws {
        try store.save([zone("First"), zone("Second")]).get()
        let model = DropzoneEditorModel(store: store)
        model.selection = model.zones[0].id
        model.zones[1].name = ""

        XCTAssertFalse(model.save())
        XCTAssertEqual(model.selection, model.zones[1].id)
        XCTAssertTrue(model.errorMessage?.contains("Dropzone 2") == true)
        XCTAssertEqual(store.load().zones.count, 2)
    }

    func testRevertDropsTheDraftAndRestoresTheSavedSelection() throws {
        let first = zone("First")
        let second = zone("Second")
        try store.save([first, second]).get()
        let model = DropzoneEditorModel(store: store)

        model.zones[0].name = "Edited"
        XCTAssertTrue(model.isDirty)
        model.revert()
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.zones.map(\.name), ["First", "Second"])
        XCTAssertEqual(model.selection, first.id)
    }

    func testDuplicateClearsConfirmationAndKeepsTheOriginal() throws {
        var original = zone("Original")
        original.markConfirmed()
        try store.save([original]).get()
        let model = DropzoneEditorModel(store: store)

        let copy = try XCTUnwrap(model.duplicate(original.id))
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.name, "Copy of Original")
        XCTAssertNil(copy.confirmedCommandHash)
        XCTAssertEqual(model.selection, copy.id)
        XCTAssertEqual(model.zones.count, 2)
        XCTAssertEqual(model.zones[0].confirmedCommandHash, original.confirmedCommandHash)
    }

    func testDeleteMovesTheSelectionToTheNeighbourThenToNil() throws {
        try store.save([zone("One"), zone("Two")]).get()
        let model = DropzoneEditorModel(store: store)
        let first = model.zones[0]
        let second = model.zones[1]

        model.selection = first.id
        model.delete(first.id)
        XCTAssertEqual(model.selection, second.id)
        model.delete(second.id)
        XCTAssertNil(model.selection)
        XCTAssertTrue(model.zones.isEmpty)
    }

    func testMoveReordersAndKeepsTheSelection() throws {
        try store.save([zone("One"), zone("Two"), zone("Three")]).get()
        let model = DropzoneEditorModel(store: store)
        let first = model.zones[0]

        XCTAssertTrue(model.canMove(first.id, by: 1))
        XCTAssertFalse(model.canMove(first.id, by: -1))
        model.move(first.id, by: 1)
        XCTAssertEqual(model.zones.map(\.name), ["Two", "One", "Three"])
        XCTAssertEqual(model.selection, first.id)
        XCTAssertTrue(model.canMove(first.id, by: 1))
        model.move(first.id, by: 1)
        XCTAssertEqual(model.zones.map(\.name), ["Two", "Three", "One"])
        XCTAssertFalse(model.canMove(first.id, by: 1))
    }

    func testFutureVersionIsReadOnly() throws {
        let contents = #"{"version":99,"zones":[]}"#
        try contents.write(to: store.fileURL, atomically: true, encoding: .utf8)
        let model = DropzoneEditorModel(store: store)

        XCTAssertFalse(model.canEdit)
        XCTAssertFalse(model.canSave)
        XCTAssertNil(model.add())
        XCTAssertFalse(model.save())
        XCTAssertTrue(model.errorMessage?.contains("newer MakiDesk") == true)
        XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), contents)
    }

    func testUntrustedFileCanBeFixedBySavingWithoutEditing() throws {
        try store.save([zone()]).get()
        try FileManager.default.setAttributes([.posixPermissions: 0o666],
                                              ofItemAtPath: store.fileURL.path)
        let model = DropzoneEditorModel(store: store)

        XCTAssertFalse(model.isDirty)
        XCTAssertTrue(model.canEdit)
        XCTAssertTrue(model.canSave)
        XCTAssertTrue(model.save())
        XCTAssertEqual(store.load().state, .loaded)
    }

    func testAddAndDuplicateRespectTheZoneLimit() throws {
        let zones = (0..<DropzoneStore.maximumZones).map { zone("Zone \($0)") }
        try store.save(zones).get()
        let model = DropzoneEditorModel(store: store)

        XCTAssertNil(model.add())
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.duplicate(zones[0].id))
    }

    // MARK: - Factory reset

    func testRemovingTheStoreIsWhatResetUses() throws {
        try store.save([zone()]).get()
        XCTAssertTrue(store.remove())
        XCTAssertEqual(store.load().state, .missing)
        XCTAssertTrue(store.remove())
    }
}

// MARK: - Command presets

extension DropzoneEditorTests {
    func testCommandPresetsAreValidStartingPoints() {
        XCTAssertFalse(DropzoneCommandPreset.all.isEmpty)
        XCTAssertEqual(Set(DropzoneCommandPreset.all.map(\.id)).count,
                       DropzoneCommandPreset.all.count)

        for preset in DropzoneCommandPreset.all {
            XCTAssertFalse(preset.name.isEmpty, preset.id)
            XCTAssertFalse(preset.line.isEmpty, preset.id)
            XCTAssertTrue(DropzoneEditorChecks.placeholderTypos(in: preset.line).isEmpty,
                          "unknown placeholder in \(preset.id)")
            if preset.mode == .argv {
                XCTAssertNil(DropzoneEditorChecks.executableWarning(
                    for: CommandSpec(line: preset.line, mode: .argv)), preset.id)
            }
            if let expected = preset.expectedOutput {
                XCTAssertTrue(DropzoneEditorChecks.placeholderTypos(in: expected).isEmpty,
                              "unknown placeholder in the checked output of \(preset.id)")
                XCTAssertFalse(expected.contains("{paths}") || expected.contains("{urls}"),
                               "checked output of \(preset.id) must be one path")
            }
        }
    }

    func testApplyingAPresetChangesOnlyTheCommandAndItsFeedback() throws {
        let accepts = DropzoneAccept(kinds: [.text], utis: ["public.plain-text"],
                                     match: .any, minItems: 2, maxItems: 3)
        var zone = DropzoneConfig(name: "Keep me", icon: .emoji("🔥"), accepts: accepts,
                                  command: CommandSpec(line: "old", mode: .argv,
                                                       timeoutSeconds: 42, keepWorkdir: true))
        zone.expectedOutput = "old-output.zip"
        zone.markConfirmed()

        let preset = try XCTUnwrap(DropzoneCommandPreset.all.first { $0.id == "png" })
        preset.apply(to: &zone)

        XCTAssertEqual(zone.name, "Keep me")
        XCTAssertEqual(zone.icon, .emoji("🔥"))
        XCTAssertEqual(zone.accepts, accepts)
        XCTAssertEqual(zone.command.line, preset.line)
        XCTAssertEqual(zone.command.mode, preset.mode)
        XCTAssertEqual(zone.command.stdin, .none)
        XCTAssertEqual(zone.command.timeoutSeconds, 42)
        XCTAssertTrue(zone.command.keepWorkdir)
        XCTAssertNil(zone.expectedOutput)
        XCTAssertEqual(zone.feedback.showOutput, .none)
        XCTAssertTrue(zone.feedback.revealOutput)
        XCTAssertNil(zone.confirmedCommandHash)
        XCTAssertTrue(zone.requiresConfirmation)

        let terminal = try XCTUnwrap(DropzoneCommandPreset.all.first { $0.id == "terminal" })
        var terminalZone = DropzoneConfig(name: "Terminal",
                                          command: CommandSpec(line: "old", keepWorkdir: false))
        terminal.apply(to: &terminalZone)
        XCTAssertTrue(terminalZone.command.keepWorkdir)

        let zip = try XCTUnwrap(DropzoneCommandPreset.all.first { $0.id == "zip" })
        var zipZone = DropzoneConfig(name: "ZIP")
        zip.apply(to: &zipZone)
        XCTAssertEqual(zipZone.expectedOutput, "{parent}/archive.zip")
    }
}
