import AppKit

enum NotesStoreError: LocalizedError {
    case externalFileUnavailable(String)
    case externalFileChanged(String)

    var errorDescription: String? {
        switch self {
        case let .externalFileUnavailable(name): return "\(name) is no longer readable. The draft is preserved."
        case let .externalFileChanged(name): return "\(name) changed outside MakiDesk. Reload it or save a copy before overwriting."
        }
    }
}

/// Revision for a note's external-file association. Workers can check whether a
/// queued save is still current without reading MainActor-owned store state.
private final class ExternalAssociationRevision: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func advance() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }

    func snapshot() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func matches(_ revision: UInt64) -> Bool { snapshot() == revision }
}

/// One note: a buffer that lives on disk as a draft even when it has never
/// been saved anywhere (`Application Support/MakiDesk/Note/note-<id>.txt`).
///
/// An external file is edited as a **draft**: the text is always written to
/// our file, and only `⌘S` writes it back to the file it came from (T20).
struct Note: Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String
    var textLoaded = true
    var textLoadFailed = false
    var titlePreview: String?
    /// The file the note was opened from or saved to, when there is one.
    var externalURL: URL?
    /// Text of the external file as it was when we read or last saved it.
    /// `nil` means the file could not be read (it disappeared, or it is not
    /// text): the draft is then the only copy, and the note counts as changed.
    var externalBaseline: String?
    var externalEncoding: UInt
    var languageID: String
    var cursor: Int
    let createdAt: Date
    var updatedAt: Date

    var isExternal: Bool { externalURL != nil }

    /// Whether the draft differs from the external file.
    var isDirty: Bool {
        guard textLoaded, externalURL != nil else { return false }
        return text != externalBaseline
    }

    /// The name in the list and on the tab: the file name when there is one,
    /// otherwise the first non-empty line.
    var title: String {
        if let name = externalURL?.lastPathComponent, name.isEmpty == false {
            return name
        }
        if !textLoaded { return titlePreview ?? "Untitled" }
        var title = "Untitled"
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byLines) { line, _, _, stop in
            var trimmed = (line ?? "").trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            // A markdown heading reads better without its hashes in the list.
            if trimmed.hasPrefix("# ") { trimmed = String(trimmed.dropFirst(2)) }
            let preview = String(trimmed.prefix(49))
            title = preview.count > 48 ? String(preview.prefix(48)) + "…" : preview
            stop = true
        }
        return title
    }

    var language: NotesLanguage { NotesLanguage.named(languageID) }
}

/// The screen edge the notes panel can be docked to (T20).
enum NotesAnchor: String, Codable {
    case left, right
}

/// The languages the editor can highlight. `plain` is the fallback, and an
/// unknown identifier always ends up there (T20).
enum NotesLanguage: String, CaseIterable, Identifiable {
    case plain, swift, json, markdown, bash, python, javascript, typescript, html, css

    var id: String { rawValue }

    var label: String {
        switch self {
        case .plain: return "Plain Text"
        case .swift: return "Swift"
        case .json: return "JSON"
        case .markdown: return "Markdown"
        case .bash: return "Shell"
        case .python: return "Python"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .html: return "HTML"
        case .css: return "CSS"
        }
    }

    static func named(_ id: String) -> NotesLanguage {
        NotesLanguage(rawValue: id) ?? .plain
    }

    /// The language a file is likely written in, from its extension.
    static func forFile(_ url: URL?) -> NotesLanguage {
        guard let ext = url?.pathExtension.lowercased() else { return .plain }
        switch ext {
        case "swift": return .swift
        case "json": return .json
        case "md", "markdown", "mdown": return .markdown
        case "sh", "bash", "zsh", "command": return .bash
        case "py", "pyw": return .python
        case "js", "mjs", "cjs", "jsx": return .javascript
        case "ts", "tsx", "mts", "cts": return .typescript
        case "html", "htm", "xhtml": return .html
        case "css", "scss", "less": return .css
        default: return .plain
        }
    }
}

/// The notes and their session. Everything that survives is on disk: each note
/// as a plain text file written continuously (debounced), plus a `session.json`
/// with the open tabs, the cursors and the window frame. There is no clean
/// shutdown dependency: `kill -9` loses at most the last few hundred
/// milliseconds of typing (T20).
@MainActor
final class NotesStore {
    static let shared = NotesStore()

    private(set) var notes: [Note] = []
    private(set) var openTabs: [UUID] = []
    private(set) var selectedTab: UUID?
    private(set) var persistenceError: String?
    /// Notes whose last draft write failed. A failure of the shared session
    /// (tabs, cursor, window frame) has no note, so it stays in
    /// `persistenceError` and applies to the whole panel.
    private(set) var failedDraftIDs: Set<UUID> = []

    /// What to show for one note: its own failed draft, or the session-level
    /// error when no single note is to blame. A note that saved cleanly shows
    /// nothing even while another one is failing.
    func persistenceError(for id: UUID) -> String? {
        if failedDraftIDs.contains(id) {
            return "Not saved. Changes remain in memory and will retry automatically."
        }
        guard failedDraftIDs.isEmpty else { return nil }
        return persistenceError
    }

    /// Frame of the notes panel, remembered across launches. While the panel
    /// is anchored to a screen edge this keeps the floating frame to return to.
    var windowFrame: CGRect?

    /// The screen edge the panel is docked to, when it is docked.
    private(set) var anchor: NotesAnchor?

    /// Called when something the sidebar or the tabs show has changed.
    var onChange: (() -> Void)?

    let directory: URL
    /// Writes text to an external file. Injected so a test can hold a save in
    /// flight and observe what a stale completion is allowed to publish.
    private let writeExternal: @Sendable (String, URL, UInt) throws -> Void
    private var didLoad = false
    private var loadInFlight = false
    private var loadGeneration: UInt64 = 0
    private var loadCompletions: [@MainActor @Sendable () -> Void] = []
    private var textLoadCompletions: [UUID: [@MainActor @Sendable () -> Void]] = [:]
    private var pendingDrafts: Set<UUID> = []
    private var draftWork: [UUID: DispatchWorkItem] = [:]
    private var draftRevision: [UUID: UInt64] = [:]
    private var externalAssociationRevisions: [UUID: ExternalAssociationRevision] = [:]
    private let draftIOQueue = DispatchQueue(label: "com.makidesk.notes-draft-io", qos: .utility)
    private var sessionWork: DispatchWorkItem?
    private var persistenceRetryWork: DispatchWorkItem?
    private var persistenceRetryAttempt = 0
    private var lastCleanClose = true
    private var externalStateLoads: [UUID: [@MainActor @Sendable () -> Void]] = [:]

    init(directory: URL? = nil,
         writeExternal: (@Sendable (String, URL, UInt) throws -> Void)? = nil) {
        self.directory = directory ?? Self.defaultDirectory
        self.writeExternal = writeExternal ?? { text, url, encoding in
            try Self.write(text: text, to: url, encoding: encoding)
        }
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MakiDesk/Note", isDirectory: true)
    }

    // MARK: - Loading

    func loadIfNeeded() {
        guard !didLoad else { return }
        guard !loadInFlight else { return }
        load()
    }

    /// Starts restoration without blocking the panel's first presentation.
    /// Concurrent callers join the same load and are called back on MainActor.
    func loadIfNeededAsync(completion: @escaping @MainActor @Sendable () -> Void) {
        if didLoad {
            completion()
            return
        }
        loadCompletions.append(completion)
        guard !loadInFlight else { return }
        loadInFlight = true
        let generation = loadGeneration
        let directory = self.directory
        draftIOQueue.async { [weak self] in
            let snapshot = Self.readSnapshot(from: directory, readBodies: false, readExternalBaselines: false)
            Task { @MainActor [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.apply(snapshot)
                self.didLoad = true
                self.loadInFlight = false
                let completions = self.loadCompletions
                self.loadCompletions.removeAll()
                completions.forEach { $0() }
            }
        }
    }

    private func load() {
        apply(Self.readSnapshot(from: directory))
        didLoad = true
    }

    private struct LoadedSnapshot: @unchecked Sendable {
        let notes: [Note]
        let session: Session?
    }

    nonisolated private static func readSnapshot(from directory: URL, readBodies: Bool = true,
                                                 readExternalBaselines: Bool = true) -> LoadedSnapshot {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = readSession(at: directory)
        let metadata = Dictionary((session?.notes ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        let files = (try? fm.contentsOfDirectory(at: directory,
                                                 includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        var loaded: [Note] = []
        for file in files where file.lastPathComponent.hasPrefix("note-") && file.pathExtension == "txt" {
            let name = file.deletingPathExtension().lastPathComponent
            let raw = String(name.dropFirst("note-".count))
            guard let id = UUID(uuidString: raw) else { continue }
            let text: String
            if readBodies {
                guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
                text = contents
            } else {
                text = ""
            }
            let values = try? file.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let created = values?.creationDate ?? Date.distantPast
            let modified = values?.contentModificationDate ?? created
            let meta = metadata[id]
            var note = Note(id: id, text: text, textLoaded: readBodies,
                            titlePreview: readBodies ? nil : (meta?.title ?? readTitlePreview(at: file)),
                            externalURL: nil, externalBaseline: nil,
                            externalEncoding: String.Encoding.utf8.rawValue,
                            languageID: meta?.language ?? "plain", cursor: meta?.cursor ?? 0,
                            createdAt: created, updatedAt: modified)
            if let path = meta?.externalPath {
                note.externalURL = URL(fileURLWithPath: path)
                note.externalEncoding = meta?.encoding ?? String.Encoding.utf8.rawValue
                if readExternalBaselines {
                    note.externalBaseline = readText(at: note.externalURL!, encoding: &note.externalEncoding)
                }
            }
            loaded.append(note)
        }
        loaded.sort { $0.updatedAt > $1.updatedAt }
        return LoadedSnapshot(notes: loaded, session: session)
    }

    nonisolated private static func readTitlePreview(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return nil }
        let prefix = String(decoding: data, as: UTF8.self)
        let firstLine = prefix.split(whereSeparator: \.isNewline).first.map(String.init) ?? prefix
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let title = trimmed.hasPrefix("# ") ? String(trimmed.dropFirst(2)) : trimmed
        return title.count > 48 ? String(title.prefix(48)) + "…" : title
    }

    /// Loads one selected note body on the persistence worker. Concurrent
    /// requests for the same note join a single read and publish by generation.
    func loadTextAsync(for id: UUID, completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard let note = note(id: id) else { completion?(); return }
        if note.textLoaded { completion?(); return }
        if var callbacks = textLoadCompletions[id] {
            if let completion { callbacks.append(completion) }
            textLoadCompletions[id] = callbacks
            return
        }
        textLoadCompletions[id] = completion.map { [$0] } ?? []
        let generation = loadGeneration
        let draftURL = fileURL(for: id)
        let url = note.externalURL
        draftIOQueue.async { [weak self] in
            let text = try? String(contentsOf: draftURL, encoding: .utf8)
            var encoding = note.externalEncoding
            var baseline: String?
            if let url {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                baseline = Self.readText(at: url, encoding: &encoding)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.loadGeneration == generation, let index = self.noteIndex(id: id),
                   self.notes[index].textLoaded == false {
                    if let text {
                        self.notes[index].text = text
                        self.notes[index].textLoaded = true
                        self.notes[index].textLoadFailed = false
                        self.notes[index].titlePreview = nil
                        if self.notes[index].externalURL == url, url != nil {
                            self.notes[index].externalBaseline = baseline
                            self.notes[index].externalEncoding = encoding
                        }
                    } else {
                        self.notes[index].textLoadFailed = true
                    }
                    self.onChange?()
                }
                let callbacks = self.textLoadCompletions.removeValue(forKey: id) ?? []
                callbacks.forEach { $0() }
            }
        }
    }

    private func apply(_ snapshot: LoadedSnapshot) {
        let session = snapshot.session
        let previousSelection = selectedTab
        let snapshotIDs = Set(snapshot.notes.map(\.id))
        let createdDuringLoad = notes.filter { !snapshotIDs.contains($0.id) }
        let createdIDs = Set(createdDuringLoad.map(\.id))
        let createdTabs = openTabs.filter { createdIDs.contains($0) }
        windowFrame = session?.frame
        anchor = session?.anchor
        // Newest first; editing in this session does not move rows around, but
        // the next launch starts with the notes touched last at the top.
        notes = createdDuringLoad + snapshot.notes
        openTabs.removeAll()

        if let session {
            for id in session.tabs where notes.contains(where: { $0.id == id }) {
                openTabs.append(id)
            }
            for id in createdTabs where !openTabs.contains(id) { openTabs.append(id) }
            if let selected = previousSelection, openTabs.contains(selected) {
                selectedTab = selected
            } else if let selected = session.selected, openTabs.contains(selected) {
                selectedTab = selected
            } else {
                selectedTab = openTabs.first
            }
            lastCleanClose = session.cleanClose
        } else {
            openTabs = createdTabs
            selectedTab = previousSelection.flatMap { openTabs.contains($0) ? $0 : nil } ?? openTabs.first
        }
        onChange?()
    }

    /// `true` when the previous run ended through the normal termination path.
    var previousRunWasClean: Bool { lastCleanClose }

    func note(id: UUID) -> Note? {
        notes.first { $0.id == id }
    }

    func noteIndex(id: UUID) -> Int? {
        notes.firstIndex { $0.id == id }
    }

    // MARK: - Tabs

    @discardableResult
    func newNote(language: NotesLanguage = .plain) -> Note {
        loadIfNeeded()
        let now = Date()
        let note = Note(id: UUID(), text: "", externalURL: nil, externalBaseline: nil,
                        externalEncoding: String.Encoding.utf8.rawValue,
                        languageID: language.rawValue, cursor: 0,
                        createdAt: now, updatedAt: now)
        notes.insert(note, at: 0)
        openTabs.append(note.id)
        selectedTab = note.id
        pendingDrafts.insert(note.id)
        enqueueDraftSave(note.id)
        scheduleSession()
        onChange?()
        return note
    }

    func openNote(id: UUID) {
        loadIfNeeded()
        guard notes.contains(where: { $0.id == id }) else { return }
        if openTabs.contains(id) == false {
            openTabs.append(id)
        }
        selectedTab = id
        scheduleSession()
        onChange?()
    }

    func selectTab(_ id: UUID?) {
        guard let id, openTabs.contains(id) else { return }
        selectedTab = id
        scheduleSession()
        onChange?()
    }

    func closeTab(_ id: UUID) {
        guard let index = openTabs.firstIndex(of: id) else { return }
        draftWork[id]?.cancel()
        enqueueDraftSave(id)
        openTabs.remove(at: index)
        if selectedTab == id {
            let next = min(index, openTabs.count - 1)
            selectedTab = next >= 0 ? openTabs[next] : nil
        }
        scheduleSession()
        onChange?()
    }

    func selectNeighbourTab(offset: Int) {
        guard openTabs.count > 1, let current = selectedTab,
              let index = openTabs.firstIndex(of: current) else { return }
        let count = openTabs.count
        let next = ((index + offset) % count + count) % count
        selectTab(openTabs[next])
    }

    // MARK: - Editing

    /// Records the text of an open note and writes the draft shortly after the
    /// typing stops. The sidebar is refreshed only when the title changed,
    /// which is the only part of the row derived from the text.
    func updateText(_ text: String, for id: UUID) {
        guard let index = noteIndex(id: id), notes[index].text != text else { return }
        let oldTitle = notes[index].title
        notes[index].text = text
        notes[index].textLoaded = true
        notes[index].textLoadFailed = false
        notes[index].titlePreview = nil
        notes[index].updatedAt = Date()
        draftRevision[id, default: 0] &+= 1
        let newTitle = notes[index].title
        scheduleDraft(id)
        if oldTitle != newTitle { onChange?() }
    }

    func updateWindowFrame(_ frame: CGRect) {
        guard windowFrame != frame else { return }
        windowFrame = frame
        scheduleSession()
    }

    /// Docks the panel to a screen edge, or floats it again. The floating
    /// frame is left alone, so unanchoring returns to where it was.
    func updateAnchor(_ side: NotesAnchor?) {
        guard anchor != side else { return }
        anchor = side
        scheduleSession()
    }

    func updateCursor(_ location: Int, for id: UUID) {
        guard let index = noteIndex(id: id), notes[index].cursor != location else { return }
        notes[index].cursor = location
        scheduleSession()
    }

    func setLanguage(_ language: NotesLanguage, for id: UUID) {
        guard let index = noteIndex(id: id), notes[index].languageID != language.rawValue else { return }
        notes[index].languageID = language.rawValue
        scheduleSession()
        onChange?()
    }

    // MARK: - External files

    /// Opens a file as a draft. If the same file is already open, that tab is
    /// selected instead of opening it twice.
    @discardableResult
    func openExternal(_ url: URL) throws -> Note {
        loadIfNeeded()
        let path = url.standardizedFileURL.path
        if let existing = notes.first(where: { $0.externalURL?.standardizedFileURL.path == path }) {
            openNote(id: existing.id)
            return existing
        }
        var encoding = String.Encoding.utf8.rawValue
        guard let text = Self.readText(at: url, encoding: &encoding) else {
            throw NSError(domain: "MakiDeskNotes", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "“\(url.lastPathComponent)” is not a text file, or cannot be read."
            ])
        }
        let now = Date()
        let note = Note(id: UUID(), text: text, externalURL: url.standardizedFileURL,
                        externalBaseline: text, externalEncoding: encoding,
                        languageID: NotesLanguage.forFile(url).rawValue, cursor: 0,
                        createdAt: now, updatedAt: now)
        notes.insert(note, at: 0)
        openTabs.append(note.id)
        selectedTab = note.id
        try? write(note)
        scheduleSession()
        onChange?()
        return note
    }

    /// Reads a user-selected file away from the main actor, then inserts the
    /// resulting draft on the main actor. The synchronous overload remains
    /// useful to deterministic store tests and non-interactive callers.
    func openExternalAsync(_ url: URL, completion: @escaping @MainActor @Sendable (Result<Note, Error>) -> Void) {
        guard didLoad else {
            loadIfNeededAsync { [weak self] in self?.openExternalAsync(url, completion: completion) }
            return
        }
        let standardizedURL = url.standardizedFileURL
        if let existing = notes.first(where: {
            $0.externalURL?.standardizedFileURL.path == standardizedURL.path
        }) {
            openNote(id: existing.id)
            completion(.success(existing))
            return
        }

        draftIOQueue.async { [weak self] in
            let accessed = standardizedURL.startAccessingSecurityScopedResource()
            defer { if accessed { standardizedURL.stopAccessingSecurityScopedResource() } }
            var encoding = String.Encoding.utf8.rawValue
            let text = Self.readText(at: standardizedURL, encoding: &encoding)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let text else {
                    completion(.failure(NSError(domain: "MakiDeskNotes", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "“\(standardizedURL.lastPathComponent)” is not a text file, or cannot be read."
                    ])))
                    return
                }
                if let existing = self.notes.first(where: {
                    $0.externalURL?.standardizedFileURL.path == standardizedURL.path
                }) {
                    self.openNote(id: existing.id)
                    completion(.success(existing))
                    return
                }
                let now = Date()
                let note = Note(id: UUID(), text: text, externalURL: standardizedURL,
                                externalBaseline: text, externalEncoding: encoding,
                                languageID: NotesLanguage.forFile(standardizedURL).rawValue, cursor: 0,
                                createdAt: now, updatedAt: now)
                self.notes.insert(note, at: 0)
                self.openTabs.append(note.id)
                self.selectedTab = note.id
                self.scheduleDraft(note.id)
                self.scheduleSession()
                self.onChange?()
                completion(.success(note))
            }
        }
    }

    /// Writes the draft back to the external file (`⌘S`).
    func saveToExternal(_ id: UUID) throws {
        guard let index = noteIndex(id: id), let url = notes[index].externalURL else { return }
        _ = associationRevision(for: id).advance()
        let text = notes[index].text
        var currentEncoding = notes[index].externalEncoding
        guard let currentText = Self.readText(at: url, encoding: &currentEncoding) else {
            throw NotesStoreError.externalFileUnavailable(url.lastPathComponent)
        }
        guard currentText == notes[index].externalBaseline else {
            throw NotesStoreError.externalFileChanged(url.lastPathComponent)
        }
        // The draft must not lag behind the file it mirrors: a crash right
        // after this save would otherwise restore older text and make the
        // next save undo what was just written.
        try write(notes[index])
        let writeEncoding = Self.effectiveEncoding(for: text, preferred: notes[index].externalEncoding)
        try writeExternal(text, url, writeEncoding)
        notes[index].externalEncoding = writeEncoding
        notes[index].externalBaseline = text
        notes[index].updatedAt = Date()
        scheduleSession()
        onChange?()
    }

    /// Saves a snapshot off the main actor. If the note changes while the
    /// write is running, its newer buffer remains dirty against the snapshot
    /// that was actually written.
    func saveToExternalAsync(_ id: UUID, completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
        guard let index = noteIndex(id: id), let url = notes[index].externalURL else {
            completion(.success(()))
            return
        }
        guard notes[index].textLoaded else {
            loadTextAsync(for: id) { [weak self] in
                guard let self, self.note(id: id)?.textLoaded == true else {
                    completion(.failure(NotesStoreError.externalFileUnavailable(url.lastPathComponent)))
                    return
                }
                self.saveToExternalAsync(id, completion: completion)
            }
            return
        }
        if notes[index].externalBaseline == nil {
            refreshExternalState(id) { [weak self] in
                guard let self, let note = self.note(id: id), note.externalBaseline != nil else {
                    completion(.failure(NotesStoreError.externalFileUnavailable(url.lastPathComponent)))
                    return
                }
                self.saveToExternalAsync(id, completion: completion)
            }
            return
        }
        let snapshot = notes[index]
        let revision = draftRevision[id, default: 0]
        let association = associationRevision(for: id)
        let associationRevision = association.snapshot()
        let draftDirectory = directory
        let writer = self.writeExternal
        let writeEncoding = Self.effectiveEncoding(for: snapshot.text, preferred: snapshot.externalEncoding)
        draftIOQueue.async { [weak self] in
            let result = Result<Void, Error> {
                guard association.matches(associationRevision) else { throw CancellationError() }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                var encoding = snapshot.externalEncoding
                guard let currentText = Self.readText(at: url, encoding: &encoding) else {
                    throw NotesStoreError.externalFileUnavailable(url.lastPathComponent)
                }
                guard currentText == snapshot.externalBaseline else {
                    throw NotesStoreError.externalFileChanged(url.lastPathComponent)
                }
                guard association.matches(associationRevision) else { throw CancellationError() }
                try Self.writeDraft(snapshot, to: draftDirectory)
                guard association.matches(associationRevision) else { throw CancellationError() }
                try writer(snapshot.text, url, writeEncoding)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard association.matches(associationRevision),
                      self.note(id: id)?.externalURL?.standardizedFileURL == url.standardizedFileURL else {
                    completion(.success(()))
                    return
                }
                if case .success = result, let currentIndex = self.noteIndex(id: id) {
                    self.notes[currentIndex].externalBaseline = snapshot.text
                    self.notes[currentIndex].externalEncoding = writeEncoding
                    if self.draftRevision[id, default: 0] == revision {
                        self.notes[currentIndex].updatedAt = Date()
                        self.pendingDrafts.remove(id)
                    }
                    self.scheduleSession()
                    self.onChange?()
                }
                completion(result)
            }
        }
    }

    /// `⌘S` on a note without a file: it becomes a real file (T20).
    func saveAs(_ id: UUID, to url: URL) throws {
        guard let index = noteIndex(id: id) else { return }
        _ = associationRevision(for: id).advance()
        let text = notes[index].text
        try writeExternal(text, url, String.Encoding.utf8.rawValue)
        try write(notes[index])
        notes[index].externalURL = url.standardizedFileURL
        notes[index].externalBaseline = text
        notes[index].externalEncoding = String.Encoding.utf8.rawValue
        if notes[index].languageID == NotesLanguage.plain.rawValue {
            notes[index].languageID = NotesLanguage.forFile(url).rawValue
        }
        notes[index].updatedAt = Date()
        scheduleSession()
        onChange?()
    }

    func saveAsAsync(_ id: UUID, to url: URL,
                     completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
        guard let index = noteIndex(id: id) else {
            completion(.success(()))
            return
        }
        guard notes[index].textLoaded else {
            loadTextAsync(for: id) { [weak self] in
                guard let self, self.note(id: id)?.textLoaded == true else {
                    completion(.failure(CocoaError(.fileReadUnknown)))
                    return
                }
                self.saveAsAsync(id, to: url, completion: completion)
            }
            return
        }
        let snapshot = notes[index]
        let standardizedURL = url.standardizedFileURL
        let revision = draftRevision[id, default: 0]
        let association = associationRevision(for: id)
        let associationRevision = association.advance()
        let draftDirectory = directory
        let writer = self.writeExternal
        draftIOQueue.async { [weak self] in
            let result = Result<Void, Error> {
                guard association.matches(associationRevision) else { throw CancellationError() }
                let accessed = standardizedURL.startAccessingSecurityScopedResource()
                defer { if accessed { standardizedURL.stopAccessingSecurityScopedResource() } }
                try writer(snapshot.text, standardizedURL,
                           String.Encoding.utf8.rawValue)
                guard association.matches(associationRevision) else { throw CancellationError() }
                try Self.writeDraft(snapshot, to: draftDirectory)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard association.matches(associationRevision) else {
                    completion(.success(()))
                    return
                }
                if case .success = result, let currentIndex = self.noteIndex(id: id) {
                    self.notes[currentIndex].externalURL = standardizedURL
                    self.notes[currentIndex].externalBaseline = snapshot.text
                    self.notes[currentIndex].externalEncoding = String.Encoding.utf8.rawValue
                    if self.notes[currentIndex].languageID == NotesLanguage.plain.rawValue {
                        self.notes[currentIndex].languageID = NotesLanguage.forFile(standardizedURL).rawValue
                    }
                    if self.draftRevision[id, default: 0] == revision {
                        self.notes[currentIndex].updatedAt = Date()
                        self.pendingDrafts.remove(id)
                    }
                    self.scheduleSession()
                    self.onChange?()
                }
                completion(result)
            }
        }
    }

    /// Re-reads the external file when the baseline was never read (it may
    /// have appeared since the note was restored) or when it disappeared.
    func refreshExternalState(_ id: UUID, completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard let note = note(id: id), let url = note.externalURL else { completion?(); return }
        if externalStateLoads[id] != nil {
            if let completion { externalStateLoads[id]?.append(completion) }
            return
        }
        externalStateLoads[id] = completion.map { [$0] } ?? []
        draftIOQueue.async { [weak self] in
            var encoding = note.externalEncoding
            let exists = FileManager.default.fileExists(atPath: url.path)
            let baseline = exists && note.externalBaseline == nil ? Self.readText(at: url, encoding: &encoding) : note.externalBaseline
            let readEncoding = encoding
            Task { @MainActor [weak self] in
                guard let self else { return }
                let callbacks = self.externalStateLoads.removeValue(forKey: id) ?? []
                if let index = self.noteIndex(id: id), self.notes[index].externalURL == url,
                   self.notes[index].externalBaseline == note.externalBaseline {
                    let updated = exists ? baseline : nil
                    if updated != self.notes[index].externalBaseline {
                        self.notes[index].externalBaseline = updated
                        self.notes[index].externalEncoding = readEncoding
                        self.scheduleSession()
                        self.onChange?()
                    }
                }
                callbacks.forEach { $0() }
            }
        }
    }

    // MARK: - Deleting

    func deleteNote(_ id: UUID) {
        guard let index = noteIndex(id: id) else { return }
        _ = associationRevision(for: id).advance()
        externalAssociationRevisions[id] = nil
        draftWork[id]?.cancel()
        draftWork[id] = nil
        draftRevision[id, default: 0] &+= 1
        pendingDrafts.remove(id)
        failedDraftIDs.remove(id)
        if let tabIndex = openTabs.firstIndex(of: id) {
            openTabs.remove(at: tabIndex)
        }
        notes.remove(at: index)
        if selectedTab == id {
            // With the sidebar as the only list, the note that took its place
            // (or the one before it) becomes current.
            let next = min(index, notes.count - 1)
            selectedTab = next >= 0 ? notes[next].id : nil
            if let selectedTab, openTabs.contains(selectedTab) == false {
                openTabs.append(selectedTab)
            }
        }
        // The draft goes to the Trash, not into thin air: a mistaken click
        // stays recoverable from the Finder.
        let draft = fileURL(for: id)
        draftIOQueue.async {
            if FileManager.default.fileExists(atPath: draft.path) {
                try? FileManager.default.trashItem(at: draft, resultingItemURL: nil)
            }
        }
        scheduleSession()
        onChange?()
    }

    /// What the factory reset deletes when the notes tick is on (T20/T23).
    func deleteAllNotes(completion: (@MainActor @Sendable () -> Void)? = nil) {
        // A read may already be queued on the serial I/O worker. Invalidate its
        // publication before scheduling the purge so an old snapshot cannot
        // repopulate this model after reset.
        loadGeneration &+= 1
        loadInFlight = false
        didLoad = true
        let invalidatedLoadCompletions = loadCompletions
        loadCompletions.removeAll()
        draftWork.values.forEach { $0.cancel() }
        draftWork.removeAll()
        pendingDrafts.removeAll()
        for id in Array(draftRevision.keys) { draftRevision[id, default: 0] &+= 1 }
        for revision in externalAssociationRevisions.values { _ = revision.advance() }
        externalAssociationRevisions.removeAll()
        sessionWork?.cancel()
        sessionWork = nil
        let directory = self.directory
        draftIOQueue.async {
            // Sweep drafts not present in the in-memory model too; a reset must
            // not leave an unloaded body to reappear on the next launch.
            if let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                        includingPropertiesForKeys: nil,
                                                                        options: [.skipsHiddenFiles]) {
                for file in files where file.pathExtension == "txt" && file.lastPathComponent.hasPrefix("note-") {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("session.json"))
            if let completion {
                Task { @MainActor in completion() }
            }
        }
        notes.removeAll()
        openTabs.removeAll()
        selectedTab = nil
        windowFrame = nil
        anchor = nil
        lastCleanClose = true
        persistenceError = nil
        failedDraftIDs.removeAll()
        onChange?()
        invalidatedLoadCompletions.forEach { $0() }
    }

    // MARK: - Titles, search

    /// Notes whose title or text contains `query`; `notes` order is kept.
    func filtered(_ query: String) -> [Note] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return notes }
        return notes.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || $0.text.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Searches unloaded note bodies on the I/O worker without retaining them
    /// in memory. The returned IDs preserve sidebar order.
    func searchNoteIDsAsync(_ query: String, completion: @escaping @MainActor @Sendable ([UUID]) -> Void) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = notes
        guard !trimmed.isEmpty else { completion(snapshot.map(\.id)); return }
        let directory = self.directory
        draftIOQueue.async { [weak self] in
            let matches = snapshot.compactMap { note -> UUID? in
                if note.title.localizedCaseInsensitiveContains(trimmed) { return note.id }
                let body: String?
                if note.textLoaded {
                    body = note.text
                } else {
                    let url = directory.appendingPathComponent("note-\(note.id.uuidString.lowercased()).txt")
                    body = try? String(contentsOf: url, encoding: .utf8)
                }
                return body?.localizedCaseInsensitiveContains(trimmed) == true ? note.id : nil
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                completion(matches.filter { self.note(id: $0) != nil })
            }
        }
    }

    /// The number of restored notes. Reading it never touches the disk: the
    /// metadata restore is started explicitly by the panel and by the reset
    /// sheet, so a count read during rendering cannot block the main thread.
    var noteCount: Int {
        notes.count
    }

    // MARK: - Persistence

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("note-\(id.uuidString.lowercased()).txt")
    }

    private func associationRevision(for id: UUID) -> ExternalAssociationRevision {
        if let revision = externalAssociationRevisions[id] { return revision }
        let revision = ExternalAssociationRevision()
        externalAssociationRevisions[id] = revision
        return revision
    }

    private func scheduleDraft(_ id: UUID) {
        pendingDrafts.insert(id)
        draftWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.enqueueDraftSave(id) }
        }
        draftWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Captures an immutable note snapshot on the main actor, then writes it on
    /// the serial persistence queue. A completion only clears dirty state when
    /// it still belongs to the latest text revision.
    private func enqueueDraftSave(_ id: UUID) {
        draftWork[id] = nil
        guard pendingDrafts.contains(id), let note = note(id: id) else { return }
        let revision = draftRevision[id, default: 0]
        let directory = self.directory
        draftIOQueue.async { [weak self] in
            let result = Result { try Self.writeDraft(note, to: directory) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.draftRevision[id, default: 0] == revision,
                      self.note(id: id) != nil else { return }
                switch result {
                case .success:
                    self.pendingDrafts.remove(id)
                    self.failedDraftIDs.remove(id)
                    if self.pendingDrafts.isEmpty { self.clearPersistenceError() }
                case .failure:
                    self.pendingDrafts.insert(id)
                    self.failedDraftIDs.insert(id)
                    self.reportPersistenceFailure()
                }
            }
        }
    }

    func saveDraft(_ id: UUID) {
        draftWork[id]?.cancel()
        draftWork[id] = nil
        guard pendingDrafts.contains(id) || notes.contains(where: { $0.id == id }) else { return }
        guard let note = note(id: id) else { return }
        do {
            try draftIOQueue.sync { try Self.writeDraft(note, to: directory) }
            pendingDrafts.remove(id)
            failedDraftIDs.remove(id)
            if pendingDrafts.isEmpty { clearPersistenceError() }
        } catch {
            // Keep the draft pending so the next edit/flush can retry it.
            pendingDrafts.insert(id)
            failedDraftIDs.insert(id)
            reportPersistenceFailure()
        }
    }

    private func write(_ note: Note) throws {
        try Self.writeDraft(note, to: directory)
    }

    nonisolated private static func writeDraft(_ note: Note, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("note-\(note.id.uuidString.lowercased()).txt")
        try note.text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Flushes only when the notes were actually used in this run, so quitting
    /// the app without ever opening them does not create the folder.
    func flushIfNeeded(cleanClose: Bool) {
        guard didLoad else { return }
        flush(cleanClose: cleanClose)
    }

    /// Interactive panel dismissal must not wait for all pending file I/O.
    /// Termination still uses the synchronous flush below as a durability fence.
    func flushAsync(completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard didLoad else { completion?(); return }
        draftWork.values.forEach { $0.cancel() }
        draftWork.removeAll()
        let drafts = notes.filter { pendingDrafts.contains($0.id) }
        let revisions = draftRevision
        let session = makeSession(cleanClose: false)
        let directory = self.directory
        sessionWork?.cancel()
        sessionWork = nil
        draftIOQueue.async { [weak self] in
            let results = drafts.map { note -> (UUID, Bool) in
                do {
                    try Self.writeDraft(note, to: directory)
                    return (note.id, true)
                } catch {
                    return (note.id, false)
                }
            }
            let sessionSaved: Bool
            do {
                try Self.writeSessionSnapshot(session, to: directory)
                sessionSaved = true
            } catch {
                sessionSaved = false
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for (id, succeeded) in results {
                    if succeeded,
                       self.draftRevision[id, default: 0] == revisions[id, default: 0] {
                        self.pendingDrafts.remove(id)
                    }
                    if succeeded { self.failedDraftIDs.remove(id) }
                    else { self.failedDraftIDs.insert(id) }
                }
                if results.contains(where: { !$0.1 }) || !sessionSaved {
                    self.reportPersistenceFailure()
                } else {
                    self.clearPersistenceError()
                }
                completion?()
            }
        }
    }

    /// Writes every pending draft and the session. Called when the panel
    /// closes and when the app terminates.
    func flush(cleanClose: Bool = false) {
        // An async restore owns the session until its snapshot has been applied.
        // Flushing an empty pre-load model here could erase the prior session.
        guard didLoad else { return }
        for id in Array(pendingDrafts) { saveDraft(id) }
        sessionWork?.cancel()
        sessionWork = nil
        writeSession(cleanClose: cleanClose)
    }

    private func scheduleSession() {
        guard didLoad else { return }
        sessionWork?.cancel()
        let snapshot = makeSession(cleanClose: false)
        let directory = self.directory
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sessionWork = nil
            self.draftIOQueue.async {
                let succeeded = (try? Self.writeSessionSnapshot(snapshot, to: directory)) != nil
                Task { @MainActor [weak self] in
                    if succeeded, self?.pendingDrafts.isEmpty == true { self?.clearPersistenceError() }
                    else { self?.reportPersistenceFailure() }
                }
            }
        }
        sessionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private struct Session: Codable, @unchecked Sendable {
        struct Meta: Codable {
            var id: UUID
            var language: String
            var cursor: Int
            var externalPath: String?
            var encoding: UInt?
            var title: String?
        }
        var notes: [Meta]
        var tabs: [UUID]
        var selected: UUID?
        var frame: CGRect?
        var anchor: NotesAnchor?
        var cleanClose: Bool
    }

    nonisolated private static func readSession(at directory: URL) -> Session? {
        let url = directory.appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    private func writeSession(cleanClose: Bool) {
        let snapshot = makeSession(cleanClose: cleanClose)
        do {
            try draftIOQueue.sync { try Self.writeSessionSnapshot(snapshot, to: directory) }
        } catch {
            // A later state change or clean shutdown retries the session write.
            sessionWork = nil
            reportPersistenceFailure()
        }
    }

    private func makeSession(cleanClose: Bool) -> Session {
        let metas = notes.map { note in
            Session.Meta(id: note.id, language: note.languageID, cursor: note.cursor,
                         externalPath: note.externalURL?.path, encoding: note.externalEncoding,
                         title: note.title)
        }
        return Session(notes: metas, tabs: openTabs, selected: selectedTab,
                       frame: windowFrame, anchor: anchor, cleanClose: cleanClose)
    }

    nonisolated private static func writeSessionSnapshot(_ session: Session, to directory: URL) throws {
        let data = try JSONEncoder().encode(session)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("session.json"), options: .atomic)
    }

    private func reportPersistenceFailure() {
        let message = "Could not save notes. Changes remain in memory and will retry automatically."
        if persistenceError != message {
            persistenceError = message
            onChange?()
        }
        schedulePersistenceRetry()
    }

    private func clearPersistenceError() {
        persistenceRetryWork?.cancel()
        persistenceRetryWork = nil
        persistenceRetryAttempt = 0
        guard persistenceError != nil || failedDraftIDs.isEmpty == false else { return }
        persistenceError = nil
        failedDraftIDs.removeAll()
        onChange?()
    }

    /// Retries failed draft/session writes with bounded exponential backoff.
    /// A successful flush cancels the pending retry and resets the delay.
    private func schedulePersistenceRetry() {
        guard persistenceRetryWork == nil else { return }
        let delay = min(pow(2.0, Double(persistenceRetryAttempt)), 60.0)
        persistenceRetryAttempt = min(persistenceRetryAttempt + 1, 6)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.persistenceRetryWork = nil
            self.flushAsync()
        }
        persistenceRetryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    nonisolated private static func readText(at url: URL, encoding: inout UInt) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            encoding = String.Encoding.utf8.rawValue
            return text
        }
        var used: String.Encoding = .utf8
        guard let text = try? String(contentsOf: url, usedEncoding: &used) else { return nil }
        encoding = used.rawValue
        return text
    }

    nonisolated private static func write(text: String, to url: URL, encoding: UInt) throws {
        try text.write(to: url, atomically: true, encoding: String.Encoding(rawValue: encoding))
    }

    /// The file keeps its encoding unless the edited text cannot be represented
    /// in it; then UTF-8 is used and the note records the change.
    nonisolated static func effectiveEncoding(for text: String, preferred: UInt) -> UInt {
        let encoding = String.Encoding(rawValue: preferred)
        return text.canBeConverted(to: encoding) ? preferred : String.Encoding.utf8.rawValue
    }
}
