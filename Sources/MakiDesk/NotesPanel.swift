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

    private override init() {
        super.init()
        themeObserver = NotificationCenter.default.addObserver(
            forName: .makiDeskThemeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.content?.applyTheme()
        }
    }

    var isVisible: Bool { window?.isVisible == true }
    var isKey: Bool { window?.isKeyWindow == true }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        if window == nil { build() }
        guard let window, let content else { return }

        store.loadIfNeeded()
        if store.notes.isEmpty { store.newNote() }
        if store.selectedTab == nil || store.note(id: store.selectedTab!) == nil,
           let first = store.notes.first {
            store.openNote(id: first.id)
        }

        content.applyTheme()
        content.reloadEverything()
        place(window)
        applyMovability(to: window)
        content.updateToolbar()

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        content.focusEditor()
    }

    /// Closes the panel the way the app means it: the drafts are written first,
    /// and the shelf of open tabs survives for the next time.
    func hide() {
        guard let window else { return }
        if store.anchor == nil { store.updateWindowFrame(window.frame) }
        store.flush()
        window.orderOut(nil)
    }

    /// Inserts text at the cursor of the open note (used from the shelf, T31).
    func insertText(_ text: String) {
        show()
        content?.insertTextAtCursor(text)
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
        if let side = store.anchor {
            applyAnchor(side, to: window)
            return
        }
        if let frame = store.windowFrame,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            window.setFrame(frame, display: false)
            return
        }
        guard let screen = NSScreen.main else { return }
        let size = NSSize(width: 900, height: 620)
        let visible = screen.visibleFrame
        let width = min(size.width, visible.width - 40)
        let height = min(size.height, visible.height - 40)
        let frame = NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2,
                           width: width, height: height)
        window.setFrame(frame, display: false)
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

    private func applyAnchor(_ side: NotesAnchor, to window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
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

/// Accepts files dropped anywhere on the panel and opens them as notes.
@MainActor
final class NotesDropView: NSView {
    var onFiles: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func urls(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        return sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = urls(from: sender)
        guard urls.isEmpty == false else { return false }
        onFiles?(urls)
        return true
    }
}

// MARK: - Panel content

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
    private var filtered: [Note] = []
    private var isRefreshing = false

    init(store: NotesStore) {
        self.store = store
        let themeID = UserDefaults.standard.string(forKey: "themeID") ?? "catppuccin-mocha"
        self.theme = NotesSyntaxTheme(theme: PaletteTheme.named(themeID))
        self.editor = NotesEditorView(theme: self.theme)
        super.init(nibName: nil, bundle: nil)
        let savedSize = UserDefaults.standard.double(forKey: "notesFontSize")
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
        store.loadIfNeeded()
        filtered = store.notes

        editor.onTextChange = { [weak self] text in
            guard let self, let id = self.currentID else { return }
            self.store.updateText(text, for: id)
            self.highlighter?.schedule()
            self.updatePosition()
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
        table.rowHeight = 46
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
        for subview in [newButton, openButton, saveButton, saveAsButton, revealButton,
                        closeButton, floatButton, anchorLeftButton, anchorRightButton,
                        toolbarSeparator1, toolbarSeparator2, toolbarHairline] {
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

            toolbarSeparator1.leadingAnchor.constraint(equalTo: saveAsButton.trailingAnchor, constant: 8),
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
        let themeID = UserDefaults.standard.string(forKey: "themeID") ?? "catppuccin-mocha"
        theme = NotesSyntaxTheme(theme: PaletteTheme.named(themeID))
        let background = theme.background
        let sidebarColor = background.blended(withFraction: 0.05,
                                              of: background.luminance < 0.5 ? .white : .black) ?? background

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
        filtered = store.filtered(search.stringValue)
        loadEditor()
        refreshChrome()
    }

    func focusEditor() {
        DispatchQueue.main.async { [weak self] in
            self?.editor.focus()
        }
    }

    func insertTextAtCursor(_ text: String) {
        guard currentID != nil else { return }
        editor.textView.insertText(text, replacementRange: editor.textView.selectedRange())
        editor.focus()
    }

    // MARK: - Editor

    private func loadEditor() {
        guard let id = store.selectedTab, let note = store.note(id: id) else {
            currentID = nil
            highlighter = nil
            editor.isHidden = true
            emptyLabel.isHidden = false
            updateStatus()
            return
        }
        store.refreshExternalState(id)
        let current = store.note(id: id) ?? note
        currentID = id
        editor.isHidden = false
        emptyLabel.isHidden = true
        editor.setText(current.text, cursor: current.cursor)
        installHighlighter(for: current)
        updateStatus()
    }

    private func installHighlighter(for note: Note) {
        highlighter = nil
        guard note.language != .plain else { return }
        highlighter = NotesHighlighter(textView: editor.textView, language: note.language,
                                       theme: theme, baseAttributes: editor.baseAttributes)
        highlighter?.apply()
    }

    private func updatePosition() {
        guard currentID != nil else { positionLabel.stringValue = ""; return }
        let selection = editor.textView.selectedRange()
        let text = editor.textView.string as NSString
        let location = min(selection.location, text.length)
        let prefix = text.substring(to: location)
        let line = prefix.components(separatedBy: "\n").count
        let column = location - (prefix as NSString).range(of: "\n", options: .backwards).location
        let columnNumber = (prefix as NSString).range(of: "\n", options: .backwards).location == NSNotFound
            ? location + 1 : column
        positionLabel.stringValue = "Ln \(line), Col \(columnNumber)"
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
        if let url = note.externalURL {
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

    private func refreshChrome() {
        guard isRefreshing == false else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if store.selectedTab != currentID { loadEditor() }
        filtered = store.filtered(search.stringValue)
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

    @objc private func searchChanged() {
        filtered = store.filtered(search.stringValue)
        refreshChrome()
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSSearchField === search { searchChanged() }
    }

    // MARK: - Actions

    @objc private func newNote() {
        store.newNote()
        filtered = store.filtered(search.stringValue)
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
        if note.externalURL == nil {
            saveAs()
            return
        }
        do {
            try store.saveToExternal(id)
            updateStatus()
        } catch {
            present(error: error, title: "Could not save the note")
        }
    }

    private func saveAs() {
        guard let id = currentID, let note = store.note(id: id), let window = view.window else { return }
        let panel = NSSavePanel()
        panel.title = "Save Note"
        panel.nameFieldStringValue = suggestedFileName(for: note)
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try self.store.saveAs(id, to: url)
                self.loadEditor()
                self.refreshChrome()
            } catch {
                self.present(error: error, title: "Could not save the note")
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
        var firstError: Error?
        for url in urls {
            do {
                _ = try store.openExternal(url)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        filtered = store.filtered(search.stringValue)
        refreshChrome()
        if let firstError { present(error: firstError, title: "Could not open the file") }
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
        // Only a draft that would be lost needs a question: a clean file is
        // not touched, so closing its note is immediate.
        if let url = note.externalURL, note.isDirty || note.externalBaseline == nil {
            let alert = NSAlert()
            alert.messageText = "Close “\(note.title)”?"
            alert.informativeText = "The note is a draft of \(url.lastPathComponent). The file is not deleted; the draft and its link to the file are removed."
            alert.addButton(withTitle: "Close Note")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
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

    private func changeFontSize(by delta: CGFloat) {
        let size = min(24, max(10, editor.fontSize + delta))
        editor.fontSize = size
        UserDefaults.standard.set(Double(size), forKey: "notesFontSize")
        highlighter?.update(theme: theme, baseAttributes: editor.baseAttributes)
    }

    private func present(error: Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}


/// A two-pane split with a fixed sidebar and a draggable divider. `NSSplitView`
/// kept ignoring its own divider position once the panes used Auto Layout, so
/// this small view does the one thing the notes panel needs: a remembered
/// sidebar width and a divider the user can drag (T20).
@MainActor
final class NotesSplitView: NSView {
    static let minimumSidebar: CGFloat = 190
    static let maximumSidebar: CGFloat = 360
    private static let defaultSidebar: CGFloat = 230
    private static let defaultsKey = "notesSidebarWidth"

    var dividerColor: NSColor = .separatorColor {
        didSet { divider.lineColor = dividerColor }
    }

    private let divider = DividerView()
    private let sidebarHolder = NSView()
    private let detailHolder = NSView()
    private var sidebarWidth: NSLayoutConstraint!
    private var width: CGFloat = NotesSplitView.defaultSidebar

    init() {
        super.init(frame: .zero)
        let saved = UserDefaults.standard.double(forKey: Self.defaultsKey)
        if saved >= Double(Self.minimumSidebar), saved <= Double(Self.maximumSidebar) {
            width = CGFloat(saved)
        }
        divider.lineColor = dividerColor
        divider.onDrag = { [weak self] delta in self?.drag(by: delta) }
        divider.onEnd = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(Double(self.width), forKey: Self.defaultsKey)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func addSides(sidebar: NSView, detail: NSView) {
        for view in [sidebarHolder, divider, detailHolder] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        detail.translatesAutoresizingMaskIntoConstraints = false
        sidebarHolder.addSubview(sidebar)
        detailHolder.addSubview(detail)

        sidebarWidth = sidebarHolder.widthAnchor.constraint(equalToConstant: width)
        NSLayoutConstraint.activate([
            sidebarHolder.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebarHolder.topAnchor.constraint(equalTo: topAnchor),
            sidebarHolder.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebarWidth,

            divider.leadingAnchor.constraint(equalTo: sidebarHolder.trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 3),

            detailHolder.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            detailHolder.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailHolder.topAnchor.constraint(equalTo: topAnchor),
            detailHolder.bottomAnchor.constraint(equalTo: bottomAnchor),

            sidebar.leadingAnchor.constraint(equalTo: sidebarHolder.leadingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: sidebarHolder.trailingAnchor),
            sidebar.topAnchor.constraint(equalTo: sidebarHolder.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: sidebarHolder.bottomAnchor),

            detail.leadingAnchor.constraint(equalTo: detailHolder.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: detailHolder.trailingAnchor),
            detail.topAnchor.constraint(equalTo: detailHolder.topAnchor),
            detail.bottomAnchor.constraint(equalTo: detailHolder.bottomAnchor),
        ])
    }

    private func drag(by delta: CGFloat) {
        let wanted = min(max(width + delta, Self.minimumSidebar), Self.maximumSidebar)
        guard wanted != width else { return }
        width = wanted
        sidebarWidth.constant = wanted
    }
}

/// The draggable hairline between the list and the editor.
@MainActor
final class DividerView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    var lineColor: NSColor = .separatorColor {
        didSet { needsDisplay = true }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        lineColor.setFill()
        NSRect(x: bounds.midX, y: 0, width: 1, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.deltaX)
    }

    override func mouseUp(with event: NSEvent) {
        onEnd?()
    }
}

/// A small toolbar button: an SF Symbol with a hover background, the way a
/// document toolbar looks in a slim titlebar.
/// A small toolbar button: an SF Symbol above its label, with a hover
/// background. The icon and label are drawn together so the pair stays
/// centred in the bar, the way a native toolbar item does.
@MainActor
final class IconButton: NSButton {
    static let labelFont = NSFont.systemFont(ofSize: 9, weight: .medium)

    var label: String? {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var icon: NSImage? {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private var hovered = false
    private var tracking: NSTrackingArea?
    private var tint: NSColor = .secondaryLabelColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        imagePosition = .imageOnly
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 5
        alignment = .center
        setButtonType(.momentaryChange)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isEnabled: Bool {
        didSet { updateBackground() }
    }

    override var intrinsicContentSize: NSSize {
        guard let label else { return NSSize(width: 24, height: 24) }
        let width = (label as NSString).size(withAttributes: [.font: Self.labelFont]).width
        return NSSize(width: max(34, ceil(width) + 10), height: 40)
    }

    /// The icon and its label share one colour, including the accent used for
    /// the active docking edge.
    func setTint(_ color: NSColor) {
        tint = color
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let icon, let label else { return }
        let tinted = icon.withSymbolConfiguration(.init(paletteColors: [tint])) ?? icon
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.labelFont,
            .foregroundColor: tint,
        ]
        let iconSize = tinted.size
        let labelSize = (label as NSString).size(withAttributes: attributes)
        // A fixed icon slot keeps every icon on the same line even though SF
        // Symbols have different heights; the labels share one baseline at
        // the bottom of the bar.
        let iconSlot: CGFloat = 18
        let gap: CGFloat = 2
        let bottomInset: CGFloat = 4
        let labelY = bounds.height - labelSize.height - bottomInset
        let slotY = labelY - gap - iconSlot
        let iconY = slotY + (iconSlot - iconSize.height) / 2
        // The button is flipped: y grows downwards.
        tinted.draw(in: NSRect(x: floor((bounds.width - iconSize.width) / 2),
                               y: floor(iconY),
                               width: iconSize.width, height: iconSize.height))
        (label as NSString).draw(at: NSPoint(x: floor((bounds.width - labelSize.width) / 2),
                                             y: floor(labelY)),
                                 withAttributes: attributes)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateBackground()
    }

    private func updateBackground() {
        guard isEnabled, hovered else {
            layer?.backgroundColor = NSColor.clear.cgColor
            return
        }
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
    }
}

/// A row of the notes list: title and a one-line detail.
@MainActor
final class NoteCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let dotView = NSView()

    private var onClose: (() -> Void)?
    private var theme: NotesSyntaxTheme?
    private var isCurrent = false
    private var isDirty = false
    private var isHovered = false
    private var tracking: NSTrackingArea?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 10.5)
        detailLabel.lineBreakMode = .byTruncatingTail

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close note")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.focusRingType = .none
        closeButton.refusesFirstResponder = true
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close the note"

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3.5
        dotView.toolTip = "Not saved to the file yet — hover to close"

        for subview in [titleLabel, detailLabel, dotView, closeButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            detailLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),

            dotView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -17),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 7),
            dotView.heightAnchor.constraint(equalToConstant: 7),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, detail: String, theme: NotesSyntaxTheme,
                   isDirty: Bool, isCurrent: Bool,
                   onClose: @escaping () -> Void) {
        self.theme = theme
        self.isDirty = isDirty
        self.isCurrent = isCurrent
        self.onClose = onClose
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        titleLabel.textColor = theme.text
        detailLabel.textColor = theme.subtext
        updateAccessory()
        needsDisplay = true
    }

    /// The open note stays marked even when the panel is not the key window,
    /// so it never blends into the rest of the list.
    override func draw(_ dirtyRect: NSRect) {
        guard isCurrent, let theme else { return }
        // Full-width row: the colour reaches the sidebar edges, the text keeps
        // its own padding.
        theme.accent.withAlphaComponent(0.16).setFill()
        bounds.fill()
        theme.accent.setFill()
        NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAccessory()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAccessory()
    }

    @objc private func closeClicked() {
        let close = onClose
        close?()
    }

    private func updateAccessory() {
        // A changed file shows the dot; hovering turns it into the close
        // button, exactly like a tab would.
        let showsDot = isDirty && isHovered == false
        dotView.isHidden = showsDot == false
        closeButton.isHidden = showsDot
        closeButton.contentTintColor = isHovered ? (theme?.text ?? .labelColor) : (theme?.subtext ?? .secondaryLabelColor)
        dotView.layer?.backgroundColor = NSColor.systemOrange.cgColor
    }
}
