import XCTest
@testable import MakiDesk

@MainActor
final class NotesStoreTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("makidesk-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testDraftSurvivesReloadWithoutSavingAnywhere() throws {
        let dir = try makeDirectory()
        let store = NotesStore(directory: dir)
        store.loadIfNeeded()
        let note = store.newNote()
        store.updateText("first line\nsecond line", for: note.id)
        store.updateCursor(9, for: note.id)
        store.flush(cleanClose: true)

        let reloaded = NotesStore(directory: dir)
        reloaded.loadIfNeeded()

        XCTAssertEqual(reloaded.noteCount, 1)
        let restored = try XCTUnwrap(reloaded.note(id: note.id))
        XCTAssertEqual(restored.text, "first line\nsecond line")
        XCTAssertEqual(restored.cursor, 9)
        XCTAssertEqual(restored.title, "first line")
        XCTAssertEqual(reloaded.openTabs, [note.id])
        XCTAssertEqual(reloaded.selectedTab, note.id)
        XCTAssertTrue(reloaded.previousRunWasClean)
    }

    func testAsyncFlushCannotMarkANewerEditAsSaved() async throws {
        let directory = try makeDirectory()
        let store = NotesStore(directory: directory)
        let note = store.newNote()
        store.updateText("first revision", for: note.id)
        let finished = expectation(description: "first snapshot written")
        store.flushAsync { finished.fulfill() }
        store.updateText("newer revision", for: note.id)
        await fulfillment(of: [finished], timeout: 3)
        store.flush()
        let reopened = NotesStore(directory: directory)
        reopened.loadIfNeeded()
        XCTAssertEqual(reopened.note(id: note.id)?.text, "newer revision")
    }

    func testAsyncRestoreDefersExternalReadsAndSavingHydratesOnlyItsTarget() async throws {
        let directory = try makeDirectory()
        let store = NotesStore(directory: directory)
        let first = store.newNote()
        store.updateText("original", for: first.id)
        let firstURL = directory.appendingPathComponent("external-a.txt")
        try store.saveAs(first.id, to: firstURL)
        let second = store.newNote()
        store.updateText("other document", for: second.id)
        try store.saveAs(second.id, to: directory.appendingPathComponent("external-b.txt"))
        store.flush()

        let reopened = NotesStore(directory: directory)
        let loaded = expectation(description: "drafts restored")
        reopened.loadIfNeededAsync { loaded.fulfill() }
        await fulfillment(of: [loaded], timeout: 3)
        XCTAssertTrue(reopened.notes.allSatisfy { !$0.textLoaded })
        XCTAssertTrue(reopened.notes.allSatisfy { $0.externalBaseline == nil })
        reopened.updateText("edited after restore", for: first.id)
        let saved = expectation(description: "save with deferred baseline")
        reopened.saveToExternalAsync(first.id) { result in
            if case let .failure(error) = result { XCTFail(error.localizedDescription) }
            saved.fulfill()
        }
        await fulfillment(of: [saved], timeout: 3)
        XCTAssertEqual(try String(contentsOf: firstURL, encoding: .utf8), "edited after restore")
        XCTAssertNil(reopened.note(id: second.id)?.externalBaseline)
        reopened.flush()
    }

    func testNoteCountDoesNotStartASynchronousRestore() async throws {
        let directory = try makeDirectory()
        let writer = NotesStore(directory: directory)
        let note = writer.newNote()
        writer.updateText("Restored later", for: note.id)
        writer.flush()

        let store = NotesStore(directory: directory)
        // Reading the count must not read the folder: that is what used to
        // block the main thread when the reset sheet appeared.
        XCTAssertEqual(store.noteCount, 0)

        let restored = expectation(description: "metadata restored")
        store.loadIfNeededAsync { restored.fulfill() }
        await fulfillment(of: [restored], timeout: 3)
        XCTAssertEqual(store.noteCount, 1)
    }

    func testAsyncRestoreLoadsBodiesOnDemandAndSearchesUnloadedText() async throws {
        let directory = try makeDirectory()
        let writer = NotesStore(directory: directory)
        let first = writer.newNote()
        writer.updateText("Lazy title\nneedle in body", for: first.id)
        let second = writer.newNote()
        writer.updateText("Another note\nother content", for: second.id)
        writer.flush()

        let store = NotesStore(directory: directory)
        let restored = expectation(description: "metadata restored")
        store.loadIfNeededAsync { restored.fulfill() }
        await fulfillment(of: [restored], timeout: 3)
        let unloaded = try XCTUnwrap(store.note(id: first.id))
        XCTAssertFalse(unloaded.textLoaded)
        XCTAssertEqual(unloaded.text, "")
        XCTAssertEqual(unloaded.title, "Lazy title")

        let searchDone = expectation(description: "unloaded body search")
        var matchIDs: [UUID] = []
        store.searchNoteIDsAsync("needle") { ids in
            matchIDs = ids
            searchDone.fulfill()
        }
        await fulfillment(of: [searchDone], timeout: 3)
        XCTAssertEqual(matchIDs, [first.id])
        XCTAssertFalse(try XCTUnwrap(store.note(id: first.id)).textLoaded)

        let bodyLoaded = expectation(description: "selected body loaded")
        store.loadTextAsync(for: first.id) { bodyLoaded.fulfill() }
        await fulfillment(of: [bodyLoaded], timeout: 3)
        let loadedNote = try XCTUnwrap(store.note(id: first.id))
        XCTAssertTrue(loadedNote.textLoaded)
        XCTAssertEqual(loadedNote.text, "Lazy title\nneedle in body")
    }

    func testOnlyTheLatestAsyncSaveAsUpdatesTheExternalAssociation() async throws {
        let directory = try makeDirectory()
        let store = NotesStore(directory: directory.appendingPathComponent("Notes"))
        let note = store.newNote()
        store.updateText("draft", for: note.id)
        let firstURL = directory.appendingPathComponent("first.txt")
        let secondURL = directory.appendingPathComponent("second.txt")

        let firstFinished = expectation(description: "first Save As finished")
        let secondFinished = expectation(description: "second Save As finished")
        store.saveAsAsync(note.id, to: firstURL) { result in
            if case let .failure(error) = result { XCTFail(error.localizedDescription) }
            firstFinished.fulfill()
        }
        store.saveAsAsync(note.id, to: secondURL) { result in
            if case let .failure(error) = result { XCTFail(error.localizedDescription) }
            secondFinished.fulfill()
        }
        await fulfillment(of: [firstFinished, secondFinished], timeout: 3)

        XCTAssertEqual(store.note(id: note.id)?.externalURL, secondURL.standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: secondURL, encoding: .utf8), "draft")
    }

    func testTabsOrderAndSelectionAreRestored() throws {
        let dir = try makeDirectory()
        let store = NotesStore(directory: dir)
        store.loadIfNeeded()
        let first = store.newNote()
        store.updateText("one", for: first.id)
        let second = store.newNote()
        store.updateText("two", for: second.id)
        store.selectTab(first.id)
        store.flush()

        let reloaded = NotesStore(directory: dir)
        reloaded.loadIfNeeded()
        XCTAssertEqual(reloaded.openTabs, [first.id, second.id])
        XCTAssertEqual(reloaded.selectedTab, first.id)
    }

    func testClosingATabKeepsTheNoteInTheList() throws {
        let dir = try makeDirectory()
        let store = NotesStore(directory: dir)
        store.loadIfNeeded()
        let note = store.newNote()
        store.updateText("kept", for: note.id)
        store.closeTab(note.id)

        XCTAssertTrue(store.openTabs.isEmpty)
        XCTAssertNil(store.selectedTab)
        XCTAssertEqual(store.noteCount, 1)

        store.openNote(id: note.id)
        XCTAssertEqual(store.openTabs, [note.id])
    }

    func testExternalFileIsADraftUntilSaved() throws {
        let dir = try makeDirectory()
        let file = dir.appendingPathComponent("outside.txt")
        try "original".write(to: file, atomically: true, encoding: .utf8)

        let store = NotesStore(directory: dir.appendingPathComponent("Notes"))
        let note = try store.openExternal(file)
        XCTAssertEqual(note.text, "original")
        XCTAssertFalse(note.isDirty)

        store.updateText("changed", for: note.id)
        XCTAssertTrue(try XCTUnwrap(store.note(id: note.id)).isDirty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")

        try store.saveToExternal(note.id)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed")
        XCTAssertFalse(try XCTUnwrap(store.note(id: note.id)).isDirty)
        store.flush()

        // The draft also survives a restart, together with the link to the file.
        let reloaded = NotesStore(directory: dir.appendingPathComponent("Notes"))
        reloaded.loadIfNeeded()
        let restored = try XCTUnwrap(reloaded.note(id: note.id))
        XCTAssertEqual(restored.text, "changed")
        XCTAssertEqual(restored.externalURL?.path, file.standardizedFileURL.path)
        XCTAssertFalse(restored.isDirty)
    }

    func testSavingExternalNotePreservesChangesMadeOutsideMakiDesk() throws {
        let dir = try makeDirectory()
        let file = dir.appendingPathComponent("shared.txt")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        let store = NotesStore(directory: dir.appendingPathComponent("notes"))
        store.loadIfNeeded()
        let note = try store.openExternal(file)
        store.updateText("my draft", for: note.id)
        try "outside edit".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try store.saveToExternal(note.id))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "outside edit")
        XCTAssertEqual(store.note(id: note.id)?.text, "my draft")
    }

    func testDraftIsNotLostWhenTheExternalFileDisappears() throws {
        let dir = try makeDirectory()
        let file = dir.appendingPathComponent("vanishing.txt")
        try "text".write(to: file, atomically: true, encoding: .utf8)
        let store = NotesStore(directory: dir.appendingPathComponent("Notes"))
        let note = try store.openExternal(file)
        store.updateText("edited", for: note.id)
        try FileManager.default.removeItem(at: file)

        store.refreshExternalState(note.id)
        let updated = try XCTUnwrap(store.note(id: note.id))
        XCTAssertEqual(updated.text, "edited")
        XCTAssertTrue(updated.isDirty)
    }

    func testSaveAsTurnsATabIntoAFile() throws {
        let dir = try makeDirectory()
        let store = NotesStore(directory: dir.appendingPathComponent("Notes"))
        let note = store.newNote()
        store.updateText("let x = 1", for: note.id)

        let target = dir.appendingPathComponent("snippet.swift")
        try store.saveAs(note.id, to: target)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "let x = 1")
        let saved = try XCTUnwrap(store.note(id: note.id))
        XCTAssertEqual(saved.externalURL?.path, target.standardizedFileURL.path)
        XCTAssertEqual(saved.language, .swift)
        XCTAssertFalse(saved.isDirty)
    }

    func testSearchMatchesTitleAndText() throws {
        let dir = try makeDirectory()
        let store = NotesStore(directory: dir)
        let first = store.newNote()
        store.updateText("alpha\nsome body", for: first.id)
        let second = store.newNote()
        store.updateText("beta\nnothing here", for: second.id)

        XCTAssertEqual(store.filtered("alpha").map(\.id), [first.id])
        XCTAssertEqual(store.filtered("body").map(\.id), [first.id])
        XCTAssertEqual(store.filtered("BETA").map(\.id), [second.id])
        XCTAssertEqual(store.filtered("  ").count, 2)
    }

    func testFactoryResetDeletesEveryNote() async throws {
        let dir = try makeDirectory()
        let store = NotesStore(directory: dir)
        let note = store.newNote()
        store.updateText("to be deleted", for: note.id)
        store.flush()

        let deleted = expectation(description: "reset purge finished")
        store.deleteAllNotes { deleted.fulfill() }
        await fulfillment(of: [deleted], timeout: 3)

        XCTAssertEqual(store.noteCount, 0)
        XCTAssertTrue(store.openTabs.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.isEmpty, "files left behind: \(files)")

        let reloaded = NotesStore(directory: dir)
        reloaded.loadIfNeeded()
        XCTAssertEqual(reloaded.noteCount, 0)
    }

    func testMarkdownHeadingLosesItsHashesInTheTitle() throws {
        let dir = try makeDirectory()
        let store = NotesStore(directory: dir)
        let note = store.newNote()
        store.updateText("# Release checklist\nbody", for: note.id)
        XCTAssertEqual(store.note(id: note.id)?.title, "Release checklist")

        let shebang = store.newNote()
        store.updateText("#!/bin/sh\necho hi", for: shebang.id)
        XCTAssertEqual(store.note(id: shebang.id)?.title, "#!/bin/sh")
    }

    func testFactoryResetAlsoSweepsNotesThatWereNeverLoaded() async throws {
        let dir = try makeDirectory()
        let writer = NotesStore(directory: dir)
        let note = writer.newNote()
        writer.updateText("on disk only", for: note.id)
        writer.flush()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 2)

        // A second store that never loaded must still clear the folder.
        let cleaner = NotesStore(directory: dir)
        let deleted = expectation(description: "unloaded reset purge finished")
        cleaner.deleteAllNotes { deleted.fulfill() }
        await fulfillment(of: [deleted], timeout: 3)

        XCTAssertEqual(cleaner.noteCount, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    func testFactoryResetInvalidatesAnInFlightAsyncRestore() async throws {
        let dir = try makeDirectory()
        let writer = NotesStore(directory: dir)
        let note = writer.newNote()
        writer.updateText("restore must not resurrect this", for: note.id)
        writer.flush()

        let store = NotesStore(directory: dir)
        let restoreReturned = expectation(description: "pending restore caller released by reset")
        store.loadIfNeededAsync { restoreReturned.fulfill() }
        let purgeFinished = expectation(description: "reset purge finished")
        store.deleteAllNotes { purgeFinished.fulfill() }

        await fulfillment(of: [restoreReturned, purgeFinished], timeout: 3)
        XCTAssertEqual(store.noteCount, 0)
        XCTAssertTrue(store.openTabs.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    func testAsyncFlushReportsAndRetainsFailedPersistence() async throws {
        let base = try makeDirectory()
        let invalidDirectory = base.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: invalidDirectory)
        let store = NotesStore(directory: invalidDirectory)
        let note = store.newNote()
        store.updateText("keep this draft", for: note.id)

        let flushed = expectation(description: "failed flush reported")
        store.flushAsync { flushed.fulfill() }
        await fulfillment(of: [flushed], timeout: 3)

        XCTAssertNotNil(store.persistenceError)
        XCTAssertEqual(store.note(id: note.id)?.text, "keep this draft")
    }

    func testFailedPersistenceRetriesAutomaticallyAfterDirectoryRecovers() async throws {
        let base = try makeDirectory()
        let invalidDirectory = base.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: invalidDirectory)
        let store = NotesStore(directory: invalidDirectory)
        let note = store.newNote()
        store.updateText("retry this draft", for: note.id)

        let failedFlush = expectation(description: "initial flush fails")
        let recovered = expectation(description: "automatic retry succeeds")
        store.onChange = {
            if store.persistenceError == nil,
               FileManager.default.fileExists(atPath: invalidDirectory.appendingPathComponent("note-\(note.id.uuidString.lowercased()).txt").path) {
                recovered.fulfill()
            }
        }
        store.flushAsync { failedFlush.fulfill() }
        await fulfillment(of: [failedFlush], timeout: 3)
        XCTAssertNotNil(store.persistenceError)

        try FileManager.default.removeItem(at: invalidDirectory)
        try FileManager.default.createDirectory(at: invalidDirectory, withIntermediateDirectories: true)
        await fulfillment(of: [recovered], timeout: 5)
        XCTAssertNil(store.persistenceError)
    }

    func testQuittingWithoutEverOpeningNotesLeavesNoFolder() throws {
        let base = try makeDirectory()
        let dir = base.appendingPathComponent("never-created")
        let store = NotesStore(directory: dir)
        store.flushIfNeeded(cleanClose: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testDeletingTheSelectedNoteSelectsItsNeighbour() throws {
        let dir = try makeDirectory()
        let store = NotesStore(directory: dir)
        let first = store.newNote()
        let second = store.newNote()
        store.openNote(id: first.id)

        store.deleteNote(first.id)

        XCTAssertEqual(store.selectedTab, second.id)
        XCTAssertNil(store.note(id: first.id))
        XCTAssertEqual(store.noteCount, 1)
    }

    func testAnchorSurvivesARestart() throws {
        let dir = try makeDirectory()
        let store = NotesStore(directory: dir)
        _ = store.newNote()
        store.updateAnchor(.right)
        store.flush()

        let reloaded = NotesStore(directory: dir)
        reloaded.loadIfNeeded()
        XCTAssertEqual(reloaded.anchor, .right)

        reloaded.updateAnchor(nil)
        reloaded.flush()
        let floating = NotesStore(directory: dir)
        floating.loadIfNeeded()
        XCTAssertNil(floating.anchor)
    }

    func testSessionWrittenBeforeTheAnchorExistedStillLoads() throws {
        let dir = try makeDirectory()
        let id = UUID()
        try "let x = 1\n".write(to: dir.appendingPathComponent("note-\(id.uuidString).txt"),
                                 atomically: true, encoding: .utf8)
        let json = """
        {"notes":[{"id":"\(id.uuidString)","language":"swift","cursor":3,"encoding":4}],
         "tabs":["\(id.uuidString)"],"selected":"\(id.uuidString)","cleanClose":true}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("session.json"))

        let store = NotesStore(directory: dir)
        store.loadIfNeeded()
        XCTAssertEqual(store.openTabs, [id])
        XCTAssertEqual(store.selectedTab, id)
        XCTAssertEqual(store.note(id: id)?.language, .swift)
        XCTAssertNil(store.anchor)
    }

    func testLanguageDetection() {
        XCTAssertEqual(NotesLanguage.forFile(URL(fileURLWithPath: "a.swift")), .swift)
        XCTAssertEqual(NotesLanguage.forFile(URL(fileURLWithPath: "a.md")), .markdown)
        XCTAssertEqual(NotesLanguage.forFile(URL(fileURLWithPath: "a.zsh")), .bash)
        XCTAssertEqual(NotesLanguage.forFile(URL(fileURLWithPath: "a.tsx")), .typescript)
        XCTAssertEqual(NotesLanguage.forFile(URL(fileURLWithPath: "a.unknown")), .plain)
        XCTAssertEqual(NotesLanguage.forFile(nil), .plain)
        XCTAssertEqual(NotesLanguage.named("nonsense"), .plain)
    }

    func testEveryHighlightedLanguageHasAWorkingGrammarAndQuery() {
        for language in NotesLanguage.allCases {
            if language == .plain {
                XCTAssertNil(NotesGrammar.configuration(for: language))
            } else {
                XCTAssertNotNil(NotesGrammar.configuration(for: language),
                                "\(language.label) has no compiled highlight query")
            }
        }
    }
}
