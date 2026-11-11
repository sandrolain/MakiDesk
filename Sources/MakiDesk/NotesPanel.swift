import AppKit

// MARK: - Controller

/// Owns the notes panel: one panel, shown and hidden with `⌥N` (T20).
@MainActor
final class NotesController: NSObject, NSWindowDelegate {
    static let shared = NotesController()

    private var window: NotesPanel?
    private var content: NotesViewController?
    private let store = NotesStore.shared
    private var isApplyingFrame = false
    private var themeObserver: NSObjectProtocol?
    private var pendingInsertions: [String] = []
    /// Texts that must become new notes when the store has finished loading.
    private var pendingNewNotes: [String] = []
    private let focusReturn = PanelFocusReturn()

    private override init() {
        super.init()
        themeObserver = NotificationCenter.default.addObserver(
            forName: .makiDeskThemeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.content?.applyTheme() }
        }
    }

    var isVisible: Bool { window?.isVisible == true }
    var isKey: Bool { window?.isKeyWindow == true }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        if !isKey { focusReturn.capture() }
        let wasVisible = window?.isVisible == true
        if window == nil { build() }
        guard let window, let content else { return }
        content.applyTheme()
        if !wasVisible { place(window) }
        applyMovability(to: window)
        content.updateToolbar()

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        store.loadIfNeededAsync { [weak self] in
            guard let self, let window = self.window, let content = self.content else { return }
            let newTexts = self.pendingNewNotes
            self.pendingNewNotes.removeAll()
            if newTexts.isEmpty == false {
                // Shelf and OCR send text as a new note: the open draft is left
                // exactly as it was.
                for text in newTexts { _ = self.store.addNote(text: text) }
            } else {
                if self.store.notes.isEmpty { self.store.newNote() }
                if self.store.selectedTab == nil || self.store.note(id: self.store.selectedTab!) == nil,
                   let first = self.store.notes.first {
                    self.store.openNote(id: first.id)
                }
            }
            content.reloadEverything()
            self.applyMovability(to: window)
            content.updateToolbar()
            let insertions = self.pendingInsertions
            self.pendingInsertions.removeAll()
            for insertion in insertions { content.insertTextAtCursor(insertion) }
            if window.isVisible { content.focusEditor() }
        }
    }

    /// Closes the panel the way the app means it: the drafts are written first,
    /// and the shelf of open tabs survives for the next time.
    func hide() {
        guard let window, window.isVisible else { return }
        let restoreFocus = focusReturn.takeRestoreAction(ownsKeyboard: window.isKeyWindow)
        if store.anchor == nil { store.updateWindowFrame(window.frame) }
        store.flushAsync()
        // A rewrite belongs to the open note: closing the panel ends it (T66).
        NotesRewriteController.shared.reset()
        NotesRewritePanelController.shared.hide()
        window.orderOut(nil)
        restoreFocus?()
    }

    /// Inserts text at the cursor of the open note: the clipboard panel's
    /// fallback when a paste could not reach the editor (T21). Shelf and OCR
    /// send text with `addNote(text:)` instead.
    func insertText(_ text: String) {
        pendingInsertions.append(text)
        show()
    }

    /// Sends text to Notes as a **new note**: the note being edited is never
    /// touched. Used by the shelf and by the OCR notice (T31, T41).
    func addNote(text: String) {
        pendingNewNotes.append(text)
        show()
    }

    private func build() {
        let content = NotesViewController(store: store)
        let panel = NotesPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.title = "Notes"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 620, height: 400)
        panel.tabbingMode = .disallowed
        content.view.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        panel.contentViewController = content
        panel.setFrame(NSRect(x: 0, y: 0, width: 900, height: 620), display: false)
        panel.delegate = self
        panel.onKeyEquivalent = { [weak content] event in
            content?.handleKeyEquivalent(event) ?? false
        }
        panel.onCancel = { [weak self] in self?.hide() }

        self.window = panel
        self.content = content
    }

    private func place(_ window: NSWindow) {
        let target = UtilityWindowPlacement.focusedScreen() ?? NSScreen.main
        if let side = store.anchor {
            applyAnchor(side, to: window, on: target)
            return
        }
        if let frame = store.windowFrame,
           let target,
           let savedScreen = UtilityWindowPlacement.screen(containing: frame),
           UtilityWindowPlacement.sameDisplay(savedScreen, target) == false {
            // The focus moved to another display: open centered there instead
            // of restoring a position the user cannot see.
            window.setFrame(
                UtilityWindowPlacement.centeredFrame(size: frame.size,
                                                     in: target.visibleFrame),
                display: false
            )
            return
        }
        if let frame = store.windowFrame,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            window.setFrame(frame, display: false)
            return
        }
        guard let screen = target else { return }
        let size = NSSize(width: 900, height: 620)
        window.setFrame(UtilityWindowPlacement.centeredFrame(size: size,
                                                             in: screen.visibleFrame),
                        display: false)
    }

    /// Docks the panel to a screen edge (full height), or floats it again
    /// where it was before docking.
    func setAnchor(_ side: NotesAnchor?) {
        guard let window else { return }
        if side != nil, store.anchor == nil {
            store.updateWindowFrame(window.frame)
        }
        store.updateAnchor(side)
        if let side {
            applyAnchor(side, to: window)
        } else {
            placeFloating(window)
        }
        applyMovability(to: window)
        content?.updateToolbar()
    }

    /// A docked panel must stay on its edge: the titlebar and the background
    /// stop moving it until it is floated again.
    private func applyMovability(to window: NSWindow) {
        let floating = store.anchor == nil
        window.isMovable = floating
        window.isMovableByWindowBackground = floating
    }

    private func applyAnchor(_ side: NotesAnchor, to window: NSWindow,
                             on target: NSScreen? = nil) {
        guard let screen = target ?? window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = min(max(window.frame.width, window.minSize.width),
                        max(window.minSize.width, visible.width - 20))
        let frame = NSRect(x: side == .left ? visible.minX : visible.maxX - width,
                           y: visible.minY, width: width, height: visible.height)
        isApplyingFrame = true
        window.setFrame(frame, display: true)
        isApplyingFrame = false
    }

    private func placeFloating(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = store.windowFrame ?? NSRect(x: visible.midX - 450, y: visible.midY - 310,
                                                width: 900, height: 620)
        let width = min(frame.width, visible.width - 20)
        let height = min(frame.height, visible.height - 20)
        frame = NSRect(x: min(max(frame.minX, visible.minX), visible.maxX - width),
                       y: min(max(frame.minY, visible.minY), visible.maxY - height),
                       width: width, height: height)
        isApplyingFrame = true
        window.setFrame(frame, display: true)
        isApplyingFrame = false
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard let window, isApplyingFrame == false else { return }
        if let side = store.anchor {
            // Belt and braces: even a system move puts it straight back.
            applyAnchor(side, to: window)
        } else {
            store.updateWindowFrame(window.frame)
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard let window, isApplyingFrame == false, store.anchor == nil else { return }
        store.updateWindowFrame(window.frame)
    }

    /// Autosave has no dialog and no "save" step: the moment the panel stops
    /// being the key window — another app, closing the lid, hiding the panel —
    /// the pending drafts and the session go to disk. The write is asynchronous
    /// so focus is returned at once.
    func windowDidResignKey(_ notification: Notification) {
        guard window?.isVisible == true else { return }
        store.flushAsync()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window else { return }
        if let side = store.anchor {
            applyAnchor(side, to: window)
        } else {
            store.updateWindowFrame(window.frame)
        }
    }

    private func anchoredFrame(for window: NSWindow, side: NotesAnchor) -> NSRect {
        guard let screen = window.screen ?? NSScreen.main else { return window.frame }
        let visible = screen.visibleFrame
        let width = min(max(window.frame.width, window.minSize.width),
                        max(window.minSize.width, visible.width - 20))
        return NSRect(x: side == .left ? visible.minX : visible.maxX - width,
                      y: visible.minY, width: width, height: visible.height)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}

/// The panel must be able to take the keyboard while the app stays `.accessory`,
/// and the key equivalents are handled here because the app has no main menu
/// (the Settings window works the same way, T20).
@MainActor
final class NotesPanel: NSPanel {
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// The Markdown commands offered by the editor's Format menu (T65).
enum MarkdownCommand: Int {
    case bold, italic, code, link
    case bullet, numbered, checkbox, quote
    case indent, outdent
    case fence, table
}

// MARK: - Panel content

/// Pending "send to note" texts (U-bug).
///
/// A note restored at launch has metadata but no body until it is opened. Text
/// sent to it must wait for the body: writing into the placeholder editor would
/// publish an empty note over the draft. The target is kept with each entry, so
/// a note switch while the body loads cannot redirect the text.
struct NotesInsertionQueue {
    private(set) var pending: [(noteID: UUID, text: String)] = []

    mutating func enqueue(_ text: String, for noteID: UUID) {
        pending.append((noteID: noteID, text: text))
    }

    mutating func take(for noteID: UUID) -> [String] {
        let texts = pending.filter { $0.noteID == noteID }.map(\.text)
        pending.removeAll { $0.noteID == noteID }
        return texts
    }

    mutating func discard(for noteID: UUID) {
        pending.removeAll { $0.noteID == noteID }
    }

    func hasPending(for noteID: UUID) -> Bool {
        pending.contains { $0.noteID == noteID }
    }
}

/// The one condition that says whether the editor may receive text right now.
/// Pure, so the case that caused the overwrite — a note whose body has not been
/// loaded yet — is a test rather than a comment.
enum NotesInsertionPolicy {
    static func canInsert(noteLoaded: Bool, loadFailed: Bool, isCurrent: Bool,
                          editorVisible: Bool, writingToolsActive: Bool) -> Bool {
        noteLoaded && !loadFailed && isCurrent && editorVisible && !writingToolsActive
    }
}

@MainActor
final class NotesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let store: NotesStore
    private var theme: NotesSyntaxTheme

    private let root = NotesDropView()
    private let split = NotesSplitView()
    private let sidebar = NSView()
    private let main = NSView()
    private let table = NSTableView()
    private let search = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let toolbarBar = NSView()
    private let toolbarHairline = NSView()
    private let toolbarSeparator1 = NSView()
    private let toolbarSeparator2 = NSView()
    private let newButton = IconButton()
    private let openButton = IconButton()
    private let saveButton = IconButton()
    private let saveAsButton = IconButton()
    private let formatButton = IconButton()
    private let revealButton = IconButton()
    private let closeButton = IconButton()
    private let floatButton = IconButton()
    private let anchorLeftButton = IconButton()
    private let anchorRightButton = IconButton()
    private let editor: NotesEditorView
    private let emptyLabel = NSTextField(labelWithString: "")
    private let statusBar = NSView()
    private let statusSeparator = NSView()
    private let statusDot = NSView()
    private let languagePopup = NSPopUpButton()
    private let detailLabel = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "")

    private var highlighter: NotesHighlighter?
    private var currentID: UUID?
    /// While a system Writing Tools session owns the text (T64): its preview is
    /// not a note yet, so it is neither saved nor coloured.
    private var writingToolsActive = false
    private var writingToolsNoteID: UUID?
    private var filtered: [Note] = []
    private var searchWork: DispatchWorkItem?
    private var searchRevision: UInt64 = 0
    private let searchQueue = DispatchQueue(label: "com.makidesk.notes-search", qos: .userInitiated)
    private var isRefreshing = false
    /// Texts sent to this note while its body was still loading: they wait for
    /// the body instead of being written into the placeholder editor.
    private var pendingInsertions = NotesInsertionQueue()

    init(store: NotesStore) {
        self.store = store
        let themeID = Settings.string(.themeID) ?? ""
        self.theme = NotesSyntaxTheme(theme: PaletteTheme.named(themeID))
        self.editor = NotesEditorView(theme: self.theme)
        super.init(nibName: nil, bundle: nil)
        let savedSize = Settings.double(.notesFontSize)
        if savedSize >= 10, savedSize <= 24 { editor.fontSize = CGFloat(savedSize) }
        store.onChange = { [weak self] in self?.refreshChrome() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = root
        buildSidebar()
        buildMain()
        buildLayout()
        applyTheme()
        filtered = store.notes

        editor.onTextChange = { [weak self] text in
            guard let self, let id = self.currentID,
                  let note = self.store.note(id: id), note.textLoaded else { return }
            // Writing Tools shows a preview of the rewrite: it reaches the
            // store once, when the session ends (T64).
            guard self.writingToolsActive == false else { return }
            self.store.updateText(text, for: id)
            self.highlighter?.schedule()
            self.updatePosition()
        }
        editor.onWritingToolsSession = { [weak self] active in
            guard let self else { return }
            self.writingToolsActive = active
            self.highlighter?.setSuspended(active)
            if active {
                self.writingToolsNoteID = self.currentID
                return
            }
            // The session ended: one write for the whole rewrite, then the text
            // is coloured again. A note switched meanwhile owns a different text.
            let id = self.writingToolsNoteID ?? self.currentID
            self.writingToolsNoteID = nil
            guard let id, id == self.currentID else { return }
            self.store.updateText(self.editor.text, for: id)
            // Writing Tools inserts its result with the system's attributes: the
            // note's own font and colour come back before the syntax pass.
            self.editor.applyBaseStyles()
            self.highlighter?.apply()
            self.updatePosition()
            self.flushPendingInsertions(for: id)
        }
        editor.onSelectionChange = { [weak self] range in
            guard let self, let id = self.currentID else { return }
            self.store.updateCursor(range.location, for: id)
            self.updatePosition()
        }
        root.onFiles = { [weak self] urls in
            self?.open(urls: urls)
        }
        updateEmptyState()
    }

    // MARK: - Building views

    private func buildSidebar() {
        let header = NSTextField(labelWithString: "Notes")
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = theme.text

        search.placeholderString = "Search notes"
        search.sendsSearchStringImmediately = true
        search.delegate = self
        search.target = self
        search.action = #selector(searchChanged)
        search.font = .systemFont(ofSize: 11.5)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 50
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(tableClicked)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let tableScroll = NSScrollView()
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.drawsBackground = false
        tableScroll.borderType = .noBorder

        countLabel.font = .systemFont(ofSize: 10.5)
        countLabel.textColor = theme.subtext

        for subview in [header, search, tableScroll, countLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            header.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 48),

            search.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            search.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),

            tableScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            tableScroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            tableScroll.bottomAnchor.constraint(equalTo: countLabel.topAnchor, constant: -6),

            countLabel.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            countLabel.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -8),
        ])
    }

    private func buildMain() {
        toolbarBar.wantsLayer = true
        toolbarHairline.wantsLayer = true
        toolbarSeparator1.wantsLayer = true
        toolbarSeparator2.wantsLayer = true

        configureToolbar(newButton, symbol: "square.and.pencil", label: "New",
                         tip: "New note (⌘T)", action: #selector(newNote))
        configureToolbar(openButton, symbol: "folder", label: "Open",
                         tip: "Open a file as a note (⌘O)", action: #selector(openDocument))
        configureToolbar(saveButton, symbol: "square.and.arrow.down", label: "Save",
                         tip: "Save (⌘S)", action: #selector(save))
        configureToolbar(saveAsButton, symbol: "square.and.arrow.down.on.square", label: "Save As",
                         tip: "Save As… (⇧⌘S)", action: #selector(saveAsFromMenu))
        configureToolbar(formatButton, symbol: "textformat", label: "Format",
                         tip: "Markdown formatting (⌘B bold, ⌘I italic, ⌘K link)",
                         action: #selector(showFormatMenu))
        configureToolbar(revealButton, symbol: "doc.text.magnifyingglass", label: "Reveal",
                         tip: "Reveal in Finder", action: #selector(revealCurrent))
        configureToolbar(closeButton, symbol: "xmark.circle", label: "Close",
                         tip: "Close the note", action: #selector(closeSelectedNote))
        configureToolbar(floatButton, symbol: "pin.slash", label: "Float",
                         tip: "Float the panel", action: #selector(floatPanel))
        configureToolbar(anchorLeftButton, symbol: "sidebar.left", label: "Left",
                         tip: "Anchor to the left edge", action: #selector(anchorLeftPanel))
        configureToolbar(anchorRightButton, symbol: "sidebar.right", label: "Right",
                         tip: "Anchor to the right edge", action: #selector(anchorRightPanel))

        statusBar.wantsLayer = true
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3
        statusDot.setAccessibilityRole(.staticText)

        languagePopup.addItems(withTitles: NotesLanguage.allCases.map(\.label))
        languagePopup.controlSize = .small
        languagePopup.font = .systemFont(ofSize: 11)
        languagePopup.bezelStyle = .rounded
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)

        detailLabel.font = .systemFont(ofSize: 10.5)
        detailLabel.textColor = theme.subtext
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        positionLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        positionLabel.textColor = theme.subtext
        positionLabel.alignment = .right

        emptyLabel.stringValue = "No note open — ⌘T for a new note"
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = theme.subtext
        emptyLabel.alignment = .center

        for subview in [toolbarBar, editor, emptyLabel, statusBar] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            main.addSubview(subview)
        }
        for subview in [newButton, openButton, saveButton, saveAsButton, formatButton,
                        revealButton, closeButton, floatButton, anchorLeftButton,
                        anchorRightButton, toolbarSeparator1, toolbarSeparator2,
                        toolbarHairline] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            toolbarBar.addSubview(subview)
        }
        for subview in [statusSeparator, languagePopup, statusDot, detailLabel, positionLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            statusBar.addSubview(subview)
        }
    }

    private func configureToolbar(_ button: IconButton, symbol: String, label: String,
                                  tip: String, action: Selector) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        button.icon = image
        button.label = label
        button.setTint(theme.subtext)
        button.setAccessibilityLabel(label)
        button.setAccessibilityHelp(tip)
        button.target = self
        button.action = action
        button.toolTip = tip
    }

    private func buildLayout() {
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addSides(sidebar: sidebar, detail: main)
        root.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        NSLayoutConstraint.activate([
            toolbarBar.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            toolbarBar.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            toolbarBar.topAnchor.constraint(equalTo: main.topAnchor),
            toolbarBar.heightAnchor.constraint(equalToConstant: 48),

            toolbarHairline.leadingAnchor.constraint(equalTo: toolbarBar.leadingAnchor),
            toolbarHairline.trailingAnchor.constraint(equalTo: toolbarBar.trailingAnchor),
            toolbarHairline.bottomAnchor.constraint(equalTo: toolbarBar.bottomAnchor),
            toolbarHairline.heightAnchor.constraint(equalToConstant: 1),

            newButton.leadingAnchor.constraint(equalTo: toolbarBar.leadingAnchor, constant: 12),
            newButton.centerYAnchor.constraint(equalTo: toolbarBar.centerYAnchor),
            newButton.heightAnchor.constraint(equalToConstant: 40),
            openButton.leadingAnchor.constraint(equalTo: newButton.trailingAnchor, constant: 4),
            openButton.centerYAnchor.constraint(equalTo: toolbarBar.centerYAnchor),
            openButton.heightAnchor.constraint(equalToConstant: 40),
            saveButton.leadingAnchor.constraint(equalTo: openButton.trailingAnchor, constant: 4),
            saveButton.centerYAnchor.constraint(equalTo: toolbarBar.centerYAnchor),
            saveButton.heightAnchor.constraint(equalToConstant: 40),
            saveAsButton.leadingAnchor.constraint(equalTo: saveButton.trailingAnchor, constant: 4),
            saveAsButton.centerYAnchor.constraint(equalTo: toolbarBar.centerYAnchor),
            saveAsButton.heightAnchor.constraint(equalToConstant: 40),

            formatButton.leadingAnchor.constraint(equalTo: saveAsButton.trailingAnchor, constant: 4),
            formatButton.centerYAnchor.constraint(equalTo: toolbarBar.centerYAnchor),
            formatButton.heightAnchor.constraint(equalToConstant: 40),

            toolbarSeparator1.leadingAnchor.constraint(equalTo: formatButton.trailingAnchor, constant: 8),
            toolbarSeparator1.centerYAnchor.constraint(equalTo: toolbarBar.centerYAnchor),
            toolbarSeparator1.widthAnchor.constraint(equalToConstant: 1),
            toolbarSeparator1.heightAnchor.constraint(equalToConstant: 20),
            revealButton.leadingAnchor.constraint(equalTo: toolbarSeparator1.trailingAnchor, constant: 8),
            revealButton.centerYAnchor.constraint(equalTo: toolbarBar.centerYAnchor),
            revealButton.heightAnchor.constraint(equalToConstant: 40),
            closeButton.leadingAnchor.constraint(equalTo: revealButton.trailingAnchor, constant: 4),
            closeButton.centerYAnchor.constraint(equalTo: toolbarBar.centerYAnchor),
            closeButton.heightAnchor.constraint(equalToConstant: 40),

            toolbarSeparator2.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 8),
            toolbarSeparator2.centerYAnchor.constraint(equalTo: toolbarBar.centerYAnchor),
            toolbarSeparator2.widthAnchor.constraint(equalToConstant: 1),
            toolbarSeparator2.heightAnchor.constraint(equalToConstant: 20),
            floatButton.leadingAnchor.constraint(equalTo: toolbarSeparator2.trailingAnchor, constant: 8),
            floatButton.centerYAnchor.constraint(equalTo: toolbarBar.centerYAnchor),
            floatButton.heightAnchor.constraint(equalToConstant: 40),
            anchorLeftButton.leadingAnchor.constraint(equalTo: floatButton.trailingAnchor, constant: 4),
            anchorLeftButton.centerYAnchor.constraint(equalTo: toolbarBar.centerYAnchor),
            anchorLeftButton.heightAnchor.constraint(equalToConstant: 40),
            anchorRightButton.leadingAnchor.constraint(equalTo: anchorLeftButton.trailingAnchor, constant: 4),
            anchorRightButton.centerYAnchor.constraint(equalTo: toolbarBar.centerYAnchor),
            anchorRightButton.heightAnchor.constraint(equalToConstant: 40),

            editor.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            editor.topAnchor.constraint(equalTo: toolbarBar.bottomAnchor),
            editor.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: main.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 28),

            statusSeparator.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            statusSeparator.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),
            statusSeparator.topAnchor.constraint(equalTo: statusBar.topAnchor),
            statusSeparator.heightAnchor.constraint(equalToConstant: 1),

            languagePopup.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            languagePopup.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            languagePopup.widthAnchor.constraint(equalToConstant: 106),
            statusDot.leadingAnchor.constraint(equalTo: languagePopup.trailingAnchor, constant: 10),
            statusDot.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 6),
            statusDot.heightAnchor.constraint(equalToConstant: 6),
            detailLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 6),
            detailLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            positionLabel.leadingAnchor.constraint(equalTo: detailLabel.trailingAnchor, constant: 10),
            positionLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -12),
            positionLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: editor.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: editor.centerYAnchor),
        ])
    }

    // MARK: - Theme

    func applyTheme() {
        let themeID = Settings.string(.themeID) ?? ""
        let palette = PaletteTheme.named(themeID)
        theme = NotesSyntaxTheme(theme: palette)
        let background = theme.background
        // The same raised tone the panels use, instead of a local blend: the
        // Notes sidebar and toolbar then match Settings and the switcher.
        let sidebarColor = NSColor(palette.raisedSurface)

        root.wantsLayer = true
        root.layer?.backgroundColor = background.cgColor
        main.wantsLayer = true
        main.layer?.backgroundColor = background.cgColor
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = sidebarColor.cgColor
        toolbarBar.layer?.backgroundColor = sidebarColor.cgColor
        toolbarHairline.layer?.backgroundColor = theme.text.withAlphaComponent(0.09).cgColor
        toolbarSeparator1.layer?.backgroundColor = theme.text.withAlphaComponent(0.12).cgColor
        toolbarSeparator2.layer?.backgroundColor = theme.text.withAlphaComponent(0.12).cgColor
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = sidebarColor.cgColor
        statusSeparator.wantsLayer = true
        statusSeparator.layer?.backgroundColor = theme.text.withAlphaComponent(0.09).cgColor
        split.dividerColor = theme.text.withAlphaComponent(0.12)

        editor.applyTheme(theme)
        highlighter?.update(theme: theme, baseAttributes: editor.baseAttributes)
        refreshChrome()
    }

    /// Called by the controller right before the panel is shown.
    func reloadEverything() {
        updateFilteredNotes()
        loadEditor()
        refreshChrome()
    }

    func focusEditor() {
        DispatchQueue.main.async { [weak self] in
            self?.editor.focus()
        }
    }

    func insertTextAtCursor(_ text: String) {
        guard let id = store.selectedTab, let note = store.note(id: id) else { return }
        // A note restored without its body is shown as an empty editor while the
        // draft loads. Inserting here would publish that empty editor over the
        // draft and overwrite the file (U-bug): wait for the body instead.
        guard NotesInsertionPolicy.canInsert(noteLoaded: note.textLoaded,
                                             loadFailed: note.textLoadFailed,
                                             isCurrent: currentID == id,
                                             editorVisible: editor.isHidden == false,
                                             writingToolsActive: writingToolsActive) else {
            pendingInsertions.enqueue(text, for: id)
            return
        }
        editor.textView.insertText(text, replacementRange: editor.textView.selectedRange())
        editor.focus()
    }

    /// Applies the texts that arrived while their note was still loading. The
    /// target id is part of every entry, so a note switch cannot redirect them.
    private func flushPendingInsertions(for id: UUID) {
        guard let note = store.note(id: id),
              NotesInsertionPolicy.canInsert(noteLoaded: note.textLoaded,
                                             loadFailed: note.textLoadFailed,
                                             isCurrent: currentID == id,
                                             editorVisible: editor.isHidden == false,
                                             writingToolsActive: writingToolsActive) else { return }
        let texts = pendingInsertions.take(for: id)
        guard texts.isEmpty == false else { return }
        for text in texts {
            editor.textView.insertText(text, replacementRange: editor.textView.selectedRange())
        }
        editor.focus()
    }

    // MARK: - Editor

    private func loadEditor() {
        guard let id = store.selectedTab, let note = store.note(id: id) else {
            currentID = nil
            highlighter = nil
            editor.isHidden = true
            emptyLabel.isHidden = false
            emptyLabel.stringValue = "No note open — ⌘T for a new note"
            updateStatus()
            return
        }
        guard note.textLoaded else {
            currentID = id
            highlighter = nil
            editor.setText("", cursor: 0)
            editor.isHidden = true
            emptyLabel.stringValue = note.textLoadFailed ? "Could not load note" : "Loading note…"
            emptyLabel.isHidden = false
            if note.textLoadFailed {
                // The text sent here has nowhere to go: say so once instead of
                // keeping it queued forever.
                if pendingInsertions.hasPending(for: id) {
                    pendingInsertions.discard(for: id)
                    HUDController.shared.show(HUDMessage.noteInsertionFailed)
                }
            } else {
                store.loadTextAsync(for: id) { [weak self] in
                    guard let self, self.store.selectedTab == id else { return }
                    self.reloadEverything()
                }
            }
            updateStatus()
            return
        }
        store.refreshExternalState(id)
        let current = store.note(id: id) ?? note
        if currentID != id {
            // A rewrite belongs to the note it was started from (T66).
            NotesRewriteController.shared.reset()
            NotesRewritePanelController.shared.hide()
        }
        currentID = id
        editor.isHidden = false
        emptyLabel.isHidden = true
        editor.setText(current.text, cursor: current.cursor)
        installHighlighter(for: current)
        updateStatus()
        flushPendingInsertions(for: id)
    }

    private func installHighlighter(for note: Note) {
        highlighter = nil
        guard note.language != .plain else {
            // Back to plain text: the previous grammar's colours go with it.
            editor.applyBaseStyles()
            return
        }
        highlighter = NotesHighlighter(textView: editor.textView, language: note.language,
                                       theme: theme, baseAttributes: editor.baseAttributes)
        if highlighter == nil {
            // A grammar that is not configured: plain text, not stale colours.
            editor.applyBaseStyles()
        } else {
            highlighter?.apply()
        }
    }

    private func updatePosition() {
        guard currentID != nil else { positionLabel.stringValue = ""; return }
        let selection = editor.textView.selectedRange()
        let text = editor.textView.string as NSString
        let location = min(selection.location, text.length)
        let position = editor.caretPosition(at: location)
        positionLabel.stringValue = "Ln \(position.line), Col \(position.column)"
    }

    private func updateStatus() {
        guard let id = currentID, let note = store.note(id: id) else {
            languagePopup.isEnabled = false
            detailLabel.stringValue = ""
            detailLabel.toolTip = nil
            positionLabel.stringValue = ""
            statusDot.layer?.backgroundColor = NSColor.clear.cgColor
            updateToolbar()
            return
        }
        languagePopup.isEnabled = true
        if let index = NotesLanguage.allCases.firstIndex(of: note.language) {
            languagePopup.selectItem(at: index)
        }

        let state: (text: String, color: NSColor, tooltip: String?)
        if let error = store.persistenceError(for: note.id) {
            state = ("Not saved", .systemRed, error)
        } else if !note.textLoaded {
            state = (note.textLoadFailed ? "Could not load note" : "Loading note…",
                     note.textLoadFailed ? .systemRed : theme.subtext, nil)
        } else if let url = note.externalURL {
            if note.externalBaseline == nil {
                state = ("File missing · draft only", .systemRed, url.path)
            } else if note.isDirty {
                state = ("Not saved to file", .systemOrange, url.path)
            } else {
                state = ("Saved · \(url.lastPathComponent)", .systemGreen, url.path)
            }
        } else {
            state = ("Draft · saved automatically", theme.subtext,
                     "Kept in Application Support/MakiDesk/Note")
        }
        detailLabel.stringValue = state.text
        detailLabel.toolTip = state.tooltip
        statusDot.layer?.backgroundColor = state.color.withAlphaComponent(0.9).cgColor
        updatePosition()
        updateToolbar()
    }

    // MARK: - Chrome

    private func refreshChrome(refreshSearch: Bool = true) {
        guard isRefreshing == false else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if store.selectedTab != currentID { loadEditor() }
        if refreshSearch { updateFilteredNotes() }
        table.reloadData()
        if let id = store.selectedTab, let row = filtered.firstIndex(where: { $0.id == id }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else {
            table.deselectAll(nil)
        }
        countLabel.stringValue = store.noteCount == 1 ? "1 note" : "\(store.noteCount) notes"
        updateStatus()
        updateEmptyState()
    }

    private func updateEmptyState() {
        let hasNote = currentID != nil && store.note(id: currentID!) != nil
        emptyLabel.isHidden = hasNote
        editor.isHidden = hasNote == false
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filtered.count else { return nil }
        let note = filtered[row]
        let identifier = NSUserInterfaceItemIdentifier("NoteCell")
        let cell: NoteCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NoteCellView {
            cell = reused
        } else {
            cell = NoteCellView(identifier: identifier)
        }
        cell.configure(title: note.title, detail: detail(for: note), theme: theme,
                       isDirty: note.isDirty, isCurrent: note.id == store.selectedTab,
                       onClose: { [weak self] in self?.closeNote(note.id) })
        return cell
    }

    private func detail(for note: Note) -> String {
        guard note.textLoaded else { return "Loading…" }
        let count = note.text.count
        let size = count == 1 ? "1 character" : "\(count) characters"
        if note.externalURL != nil {
            return note.isDirty ? "\(size) · changed" : "\(size) · file"
        }
        return size
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard isRefreshing == false else { return }
        let row = table.selectedRow
        guard row >= 0, row < filtered.count else { return }
        let id = filtered[row].id
        store.openNote(id: id)
    }

    @objc private func tableClicked() {
        guard table.selectedRow >= 0, table.selectedRow < filtered.count else { return }
        let id = filtered[table.selectedRow].id
        if store.selectedTab != id {
            store.openNote(id: id)
        }
    }

    private func updateFilteredNotes() {
        searchWork?.cancel()
        searchRevision &+= 1
        let revision = searchRevision
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = store.notes
        guard !query.isEmpty else { filtered = snapshot; return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.store.searchNoteIDsAsync(query) { [weak self] ids in
                guard let self, self.searchRevision == revision else { return }
                self.filtered = ids.compactMap { self.store.note(id: $0) }
                self.refreshChrome(refreshSearch: false)
            }
        }
        searchWork = work
        searchQueue.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    @objc private func searchChanged() {
        updateFilteredNotes()
        refreshChrome()
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSSearchField === search { searchChanged() }
    }

    // MARK: - Actions

    @objc private func newNote() {
        store.newNote()
        updateFilteredNotes()
        refreshChrome()
        focusEditor()
    }

    @objc private func tabClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        if store.selectedTab != id {
            store.selectTab(id)
        }
    }

    @objc private func languageChanged() {
        guard let id = currentID else { return }
        let index = languagePopup.indexOfSelectedItem
        guard index >= 0, index < NotesLanguage.allCases.count else { return }
        store.setLanguage(NotesLanguage.allCases[index], for: id)
        if let note = store.note(id: id) { installHighlighter(for: note) }
        updateStatus()
        focusEditor()
    }

    @objc private func save() {
        guard let id = currentID, let note = store.note(id: id) else { return }
        if note.textLoadFailed {
            present(error: CocoaError(.fileReadUnknown), title: "Could not load the note")
            return
        }
        if note.externalURL == nil {
            saveAs()
            return
        }
        store.saveToExternalAsync(id) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success: self.updateStatus()
            case let .failure(error): self.present(error: error, title: "Could not save the note")
            }
        }
    }

    private func saveAs() {
        guard let id = currentID, let note = store.note(id: id), let window = view.window else { return }
        if note.textLoadFailed {
            present(error: CocoaError(.fileReadUnknown), title: "Could not load the note")
            return
        }
        guard note.textLoaded else {
            store.loadTextAsync(for: id) { [weak self] in self?.saveAs() }
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Note"
        panel.nameFieldStringValue = suggestedFileName(for: note)
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.store.saveAsAsync(id, to: url) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.loadEditor()
                    self.refreshChrome()
                case let .failure(error):
                    self.present(error: error, title: "Could not save the note")
                }
            }
        }
    }

    private func suggestedFileName(for note: Note) -> String {
        let first = note.text.split(separator: "\n").first.map(String.init) ?? ""
        var name = first.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if name.count > 40 { name = String(name.prefix(40)) }
        return name.isEmpty ? "Note.txt" : "\(name).txt"
    }

    @objc private func floatPanel() {
        NotesController.shared.setAnchor(nil)
        updateToolbar()
        focusEditor()
    }

    @objc private func anchorLeftPanel() {
        NotesController.shared.setAnchor(store.anchor == .left ? nil : .left)
        updateToolbar()
        focusEditor()
    }

    @objc private func anchorRightPanel() {
        NotesController.shared.setAnchor(store.anchor == .right ? nil : .right)
        updateToolbar()
        focusEditor()
    }

    /// Everything the toolbar shows depends on the note and on the docking
    /// state, so it lives in one place and is refreshed with the status bar.
    func updateToolbar() {
        let note = currentID.flatMap { store.note(id: $0) }
        let hasNote = note != nil

        saveButton.isEnabled = hasNote
        saveAsButton.isEnabled = hasNote
        closeButton.isEnabled = hasNote
        revealButton.isEnabled = note?.externalURL != nil
        floatButton.isEnabled = store.anchor != nil

        let dim = theme.subtext.withAlphaComponent(0.35)
        newButton.setTint(theme.text)
        openButton.setTint(theme.text)
        saveButton.setTint(hasNote
            ? (note?.isDirty == true ? .systemOrange : theme.text)
            : dim)
        saveAsButton.setTint(hasNote ? theme.text : dim)
        closeButton.setTint(hasNote ? theme.text : dim)
        revealButton.setTint(note?.externalURL != nil ? theme.text : dim)
        floatButton.setTint(store.anchor != nil ? theme.text : dim)
        anchorLeftButton.setTint(store.anchor == .left ? theme.accent : theme.text)
        anchorRightButton.setTint(store.anchor == .right ? theme.accent : theme.text)

        if let url = note?.externalURL {
            saveButton.toolTip = note?.isDirty == true
                ? "Save to \(url.lastPathComponent) (⌘S)"
                : "Save (⌘S)"
        } else {
            saveButton.toolTip = "Save As… (⌘S)"
        }
        revealButton.toolTip = note?.externalURL == nil
            ? "Reveal in Finder — only for files"
            : "Reveal in Finder"
        closeButton.toolTip = "Close the note (the draft goes to the Trash)"
        floatButton.toolTip = store.anchor == nil ? "Float the panel (not docked)" : "Float the panel"
        anchorLeftButton.toolTip = store.anchor == .left
            ? "Docked left — click to float"
            : "Anchor to the left edge"
        anchorRightButton.toolTip = store.anchor == .right
            ? "Docked right — click to float"
            : "Anchor to the right edge"
    }

    @objc private func saveAsFromMenu() { saveAs() }

    @objc private func openDocument() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.title = "Open a File as a Note"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            self.open(urls: panel.urls)
        }
    }

    private func open(urls: [URL]) {
        open(urls: urls, at: 0, firstError: nil)
    }

    private func open(urls: [URL], at index: Int, firstError: Error?) {
        guard index < urls.count else {
            updateFilteredNotes()
            refreshChrome()
            if let firstError { present(error: firstError, title: "Could not open the file") }
            return
        }
        store.openExternalAsync(urls[index]) { [weak self] result in
            guard let self else { return }
            var nextError = firstError
            if case let .failure(error) = result, nextError == nil { nextError = error }
            self.open(urls: urls, at: index + 1, firstError: nextError)
        }
    }

    @objc private func revealCurrent() {
        guard let id = currentID, let url = store.note(id: id)?.externalURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func closeSelectedNote() {
        guard let id = currentID else { return }
        closeNote(id)
    }

    /// Closing a note removes it from the app: the draft goes to the Trash
    /// (and can be recovered from the Finder), an external file is untouched.
    private func closeNote(_ id: UUID) {
        guard let note = store.note(id: id) else { return }
        if note.textLoadFailed {
            present(error: CocoaError(.fileReadUnknown), title: "Could not load the note")
            return
        }
        if note.externalURL != nil, !note.textLoaded {
            store.loadTextAsync(for: id) { [weak self] in self?.closeNote(id) }
            return
        }
        // Only a draft that would be lost needs a question: a clean file is
        // not touched, so closing its note is immediate.
        if let url = note.externalURL, note.isDirty || (note.textLoaded && note.externalBaseline == nil) {
            guard Confirmation.closeNote(title: note.title,
                                         file: url.lastPathComponent).ask() else { return }
        }
        store.deleteNote(id)
        refreshChrome()
        focusEditor()
    }

    // MARK: - Keyboard

    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return false }
        let shift = flags.contains(.shift)
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        // The formatting keys belong to the editor: with the search field or a
        // toolbar control focused they must reach that control instead (T65).
        let formatsToEditor = (view.window?.firstResponder as? NSTextView) === editor.textView
        switch key {
        case "s":
            shift ? saveAs() : save()
            return true
        case "t":
            newNote()
            return true
        case "w":
            closeSelectedNote()
            return true
        case "f":
            let item = NSMenuItem()
            item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            editor.textView.performFindPanelAction(item)
            return true
        case "o":
            openDocument()
            return true
        case "b":
            guard shift == false, formatsToEditor else { return false }
            applyMarkdown(.bold)
            return true
        case "i":
            guard shift == false, formatsToEditor else { return false }
            applyMarkdown(.italic)
            return true
        case "k":
            guard formatsToEditor else { return false }
            applyMarkdown(shift ? .code : .link)
            return true
        case "]":
            guard shift, formatsToEditor else { return false }
            applyMarkdown(.indent)
            return true
        case "[":
            guard shift, formatsToEditor else { return false }
            applyMarkdown(.outdent)
            return true
        case "=", "+":
            changeFontSize(by: 1)
            return true
        case "-":
            changeFontSize(by: -1)
            return true
        default:
            if let number = Int(key), (1...9).contains(number), shift == false {
                let index = number - 1
                if index < filtered.count {
                    store.openNote(id: filtered[index].id)
                }
                return true
            }
            return false
        }
    }

    // MARK: - Markdown (T65)

    @objc private func showFormatMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        addFormatItem(menu, "Bold", .bold, "b", [.command])
        addFormatItem(menu, "Italic", .italic, "i", [.command])
        addFormatItem(menu, "Inline Code", .code, "k", [.command, .shift])
        addFormatItem(menu, "Link", .link, "k", [.command])
        menu.addItem(.separator())
        addFormatItem(menu, "Bulleted List", .bullet)
        addFormatItem(menu, "Numbered List", .numbered)
        addFormatItem(menu, "Checkbox", .checkbox)
        addFormatItem(menu, "Quote", .quote)
        addFormatItem(menu, "Indent", .indent, "]", [.command, .shift])
        addFormatItem(menu, "Outdent", .outdent, "[", [.command, .shift])
        menu.addItem(.separator())
        addFormatItem(menu, "Code Block", .fence)
        addFormatItem(menu, "Table", .table)
        menu.addItem(.separator())
        let availability = NotesRewriteController.shared.availability
        let header = NSMenuItem(title: "Rewrite with Apple Intelligence", action: nil,
                                keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if availability.isAvailable {
            for (index, action) in NotesRewriteAction.allCases.enumerated() {
                let item = NSMenuItem(title: action.menuTitle,
                                      action: #selector(rewriteMenuAction(_:)),
                                      keyEquivalent: "")
                item.tag = index
                item.target = self
                menu.addItem(item)
            }
        } else {
            let item = NSMenuItem(title: availability.summary, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private func addFormatItem(_ menu: NSMenu, _ title: String, _ command: MarkdownCommand,
                               _ key: String = "", _ modifiers: NSEvent.ModifierFlags = []) {
        let item = NSMenuItem(title: title, action: #selector(markdownMenuAction(_:)),
                              keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = command.rawValue
        item.target = self
        menu.addItem(item)
    }

    @objc private func markdownMenuAction(_ sender: NSMenuItem) {
        guard let command = MarkdownCommand(rawValue: sender.tag) else { return }
        applyMarkdown(command)
    }

    /// One formatter call, then the editor applies the result as a single edit;
    /// the store and the highlighter hear about it through the normal change
    /// pipeline, so this is typing as far as they are concerned (T65).
    @objc private func rewriteMenuAction(_ sender: NSMenuItem) {
        let actions = NotesRewriteAction.allCases
        guard sender.tag >= 0, sender.tag < actions.count else { return }
        startRewrite(actions[sender.tag])
    }

    /// One rewrite at a time: the model proposes, the preview shows, and only
    /// Apply changes the note — as one undoable edit (T66).
    private func startRewrite(_ action: NotesRewriteAction) {
        guard let id = currentID, let note = store.note(id: id) else { return }
        let availability = NotesRewriteController.shared.availability
        guard availability.isAvailable else {
            presentRewriteNote(availability.summary)
            return
        }
        let selection = editor.textView.selectedRange()
        let source = NotesRewritePrompt.source(note.text, selection: selection)
        guard source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }
        let range = selection.length > 0
            ? selection
            : NSRange(location: 0, length: (note.text as NSString).length)
        NotesRewriteController.shared.start(action: action, source: source, noteID: id)
        NotesRewritePanelController.shared.show(onApply: { [weak self] text in
            self?.applyRewrite(text, range: range, id: id)
        }, onCancel: { [weak self] in
            self?.focusEditor()
        })
    }

    private func applyRewrite(_ text: String, range: NSRange, id: UUID) {
        guard currentID == id else { return }
        let length = (editor.text as NSString).length
        guard NSMaxRange(range) <= length else {
            presentRewriteNote("The note changed while the model was writing: try again.")
            return
        }
        let change = NotesMarkdownChange(
            range: range, replacement: text,
            selection: NSRange(location: range.location,
                               length: (text as NSString).length)
        )
        editor.apply(change)
        focusEditor()
    }

    private func presentRewriteNote(_ message: String) {
        Confirmation.statement(title: "Notes rewriting", message: message)
            .tell(asSheetFor: view.window)
    }

    private func applyMarkdown(_ command: MarkdownCommand) {
        guard let id = currentID, let note = store.note(id: id) else { return }
        let text = editor.text
        let selection = editor.textView.selectedRange()
        let language = note.language == .plain ? "" : note.language.rawValue
        let change: NotesMarkdownChange?
        switch command {
        case .bold: change = NotesMarkdownFormat.bold(in: text, selection: selection)
        case .italic: change = NotesMarkdownFormat.italic(in: text, selection: selection)
        case .code: change = NotesMarkdownFormat.code(in: text, selection: selection)
        case .link: change = NotesMarkdownFormat.link(in: text, selection: selection)
        case .bullet:
            change = NotesMarkdownFormat.toggleList(.bullet, in: text, selection: selection)
        case .numbered:
            change = NotesMarkdownFormat.toggleList(.numbered, in: text, selection: selection)
        case .checkbox:
            change = NotesMarkdownFormat.toggleList(.checkbox, in: text, selection: selection)
        case .quote: change = NotesMarkdownFormat.toggleQuote(in: text, selection: selection)
        case .indent: change = NotesMarkdownFormat.indent(in: text, selection: selection)
        case .outdent:
            change = NotesMarkdownFormat.indent(in: text, selection: selection, outdent: true)
        case .fence:
            change = NotesMarkdownFormat.toggleFence(in: text, selection: selection,
                                                     language: language)
        case .table: change = NotesMarkdownFormat.table(in: text, selection: selection)
        }
        guard let change else { return }
        editor.apply(change)
        updatePosition()
        focusEditor()
    }

    private func changeFontSize(by delta: CGFloat) {
        let size = min(24, max(10, editor.fontSize + delta))
        editor.fontSize = size
        Settings.set(Double(size), for: .notesFontSize)
        highlighter?.update(theme: theme, baseAttributes: editor.baseAttributes)
    }

    private func present(error: Error, title: String) {
        Confirmation.statement(title: title, message: error.localizedDescription)
            .tell(asSheetFor: view.window)
    }
}
