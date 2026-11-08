import AppKit
import GhosttyKit
import MakiShared
import MakiTerminalCore

/// One terminal pane and its focus border (F1).
final class TerminalPaneHostView: NSView {
    let paneID: PaneID
    let surfaceView: TerminalSurfaceView
    let findBar = TerminalFindBar()
    var accentColor: NSColor = .controlAccentColor
    var isFocused = false {
        didSet { updateBorder() }
    }

    init(paneID: PaneID, surfaceView: TerminalSurfaceView) {
        self.paneID = paneID
        self.surfaceView = surfaceView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(surfaceView)
        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            surfaceView.leadingAnchor.constraint(equalTo: leadingAnchor),
            surfaceView.trailingAnchor.constraint(equalTo: trailingAnchor),
            surfaceView.topAnchor.constraint(equalTo: topAnchor),
            surfaceView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        addSubview(findBar)
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            findBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        updateBorder()
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func updateBorder() {
        guard let layer else { return }
        layer.borderWidth = isFocused ? 1 : 0
        layer.borderColor = accentColor.cgColor
    }
}

/// A selected row painted with the theme instead of the system accent.
final class WorkspaceRowView: NSTableRowView {
    var selectedColor: NSColor = .selectedContentBackgroundColor

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        selectedColor.setFill()
        NSBezierPath(rect: bounds).fill()
    }
}

/// A sidebar row with the selected marker, a pane count and attention dots.
final class WorkspaceCellView: NSTableCellView {
    let dot = NSView()
    let agentDot = NSView()
    let countLabel = NSTextField(labelWithString: "")
    /// The left bar that marks the workspace currently on screen; it does not
    /// depend on the table's focus, so the marker stays visible while the
    /// terminal has the keyboard.
    let accentBar = NSView()
    let accessoriesStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        accentBar.translatesAutoresizingMaskIntoConstraints = false
        accentBar.wantsLayer = true
        accentBar.isHidden = true
        addSubview(accentBar)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.isHidden = true

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dot.isHidden = true

        agentDot.translatesAutoresizingMaskIntoConstraints = false
        agentDot.wantsLayer = true
        agentDot.layer?.cornerRadius = 3
        agentDot.isHidden = true

        accessoriesStack.translatesAutoresizingMaskIntoConstraints = false
        accessoriesStack.orientation = .horizontal
        accessoriesStack.alignment = .centerY
        accessoriesStack.spacing = 6
        accessoriesStack.detachesHiddenViews = true
        accessoriesStack.setViews([countLabel, dot, agentDot], in: .leading)
        addSubview(accessoriesStack)

        NSLayoutConstraint.activate([
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentBar.topAnchor.constraint(equalTo: topAnchor),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            accentBar.widthAnchor.constraint(equalToConstant: 3),

            accessoriesStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            accessoriesStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            agentDot.widthAnchor.constraint(equalToConstant: 6),
            agentDot.heightAnchor.constraint(equalToConstant: 6),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }
}

/// A split view that knows the path of the model node it presents, so a drag
/// can be written back without searching the tree.
final class WorkspaceSplitView: NSSplitView {
    var path: [Int] = []
    var needsInitialPosition = true
    weak var controller: TerminalWindowController?

    override func layout() {
        super.layout()
        guard needsInitialPosition, bounds.width > 0, bounds.height > 0,
              subviews.count >= 2, let controller else { return }
        needsInitialPosition = false
        let total = isVertical ? bounds.width : bounds.height
        let ratio = controller.ratio(at: path)
        setPosition(total * ratio, ofDividerAt: 0)
    }
}

/// A scratch terminal that drops from the top of the screen.
final class TerminalQuakePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The helper's main window (F1): a sidebar of workspaces on the left, the
/// selected workspace's split tree on the right. Surfaces are reused across
/// rebuilds, so switching tabs never restarts a shell.
final class TerminalWindowController: NSWindowController,
                                      NSTableViewDataSource,
                                      NSTableViewDelegate,
                                      NSSplitViewDelegate,
                                      NSWindowDelegate {
    private let runtime: GhosttyRuntime
    private let layoutStore = TerminalLayoutStore()
    private let windowStateStore = TerminalWindowStateStore()
    private var terminalSettings: TerminalSettingsDocument
    private var uiTheme = TerminalUITheme.fallback
    private var addButton: NSButton?
    private var saveTimer: Timer?
    private var windowFrameTimer: Timer?
    private var workspaces: [TerminalWorkspace] = []
    private var selected = 0
    private var nextWorkspaceNumber = 1
    private var paneViews: [PaneID: TerminalPaneHostView] = [:]
    private var isBuilding = false
    private var currentRootView: NSView?

    private var quakePanel: TerminalQuakePanel?
    private var quakeWorkspace: TerminalWorkspace?
    private var quakeHost: TerminalPaneHostView?
    private var quakeVisible = false
    private var cliPath: String? {
        if TerminalCLI.isAvailable() { return TerminalCLI.stableURL.path }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("bin/makidesk"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url.path
    }
    /// Workspaces that produced something worth returning to. Session state:
    /// a dot in the sidebar, cleared by selecting the workspace.
    private var attentionWorkspaces: Set<UUID> = []
    /// Agent lifecycle per workspace, from the `makidesk` CLI; session only.
    private var agentStates: [UUID: AgentState] = [:]
    private var agentLabels: [UUID: String] = [:]

    /// One find session per window: the surface Ghostty is searching and the
    /// bar that collects the needle. Nil while the bar is closed.
    private struct ActiveSearch {
        let view: TerminalSurfaceView
        let host: TerminalPaneHostView
    }
    private var activeSearch: ActiveSearch?
    private var searchDebounce: Timer?

    private let splitView = NSSplitView()
    private let sidebar = NSView()
    private let contentView = NSView()
    private let tableView = NSTableView()
    private let closeButton = NSButton()

    /// The sidebar's own drag type: a foreign string drop is ignored.
    private static let workspaceDragType = NSPasteboard.PasteboardType(
        "com.makidesk.terminal.workspace-row"
    )

    init(runtime: GhosttyRuntime, settings: TerminalSettingsDocument) {
        self.runtime = runtime
        self.terminalSettings = settings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MakiDesk Terminal"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 320)
        super.init(window: window)
        window.delegate = self
        if let saved = windowStateStore.load()?.frame,
           let frame = TerminalWindowGeometry.restoredFrame(
               saved,
               screens: NSScreen.screens.map(\.visibleFrame)
           ) {
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }
        uiTheme = TerminalUITheme(document: TerminalThemeStore().load())
        buildInterface()
        applyUITheme()
        restoreOrCreate()
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    // MARK: - Interface

    private func buildInterface() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false

        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.wantsLayer = true
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.wantsLayer = true

        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(contentView)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)

        window?.contentView = splitView
        buildSidebar()

        DispatchQueue.main.async { [weak self] in
            self?.splitView.setPosition(220, ofDividerAt: 0)
        }
    }

    private func buildSidebar() {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workspace"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.autoresizingMask = [.width]
        tableView.headerView = nil
        tableView.style = .fullWidth
        tableView.rowHeight = 30
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.registerForDraggedTypes([Self.workspaceDragType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        scroll.drawsBackground = false
        scroll.documentView = tableView
        DispatchQueue.main.async { [weak self] in self?.fitSidebarColumn() }

        let bar = NSStackView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 2
        bar.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)

        let add = NSButton(image: NSImage(systemSymbolName: "plus",
                                          accessibilityDescription: "New workspace or SSH session")!,
                           target: self, action: #selector(newWorkspaceMenuAction(_:)))
        add.isBordered = false
        add.bezelStyle = .inline
        add.toolTip = "New workspace or SSH session"
        addButton = add

        closeButton.image = NSImage(systemSymbolName: "minus",
                                    accessibilityDescription: "Close workspace")
        closeButton.target = self
        closeButton.action = #selector(closeWorkspaceAction(_:))
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.toolTip = "Close workspace"

        bar.addArrangedSubview(add)
        bar.addArrangedSubview(closeButton)
        bar.addArrangedSubview(NSView())

        sidebar.addSubview(scroll)
        sidebar.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sidebar.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    // MARK: - Workspaces

    @objc func newWorkspaceAction(_ sender: Any?) {
        newWorkspace()
    }

    private func newWorkspace() {
        let workspace = TerminalWorkspace(title: "Workspace \(nextWorkspaceNumber)")
        nextWorkspaceNumber += 1
        workspaces.append(workspace)
        selected = workspaces.count - 1
        reloadSidebar()
        rebuildContent()
        scheduleSave()
    }

    // MARK: - Persistence

    private func restoreOrCreate() {
        let snapshot = layoutStore.load()
        let restored = snapshot.layout.workspaces.filter { $0.paneCount > 0 }
        guard restored.isEmpty == false else {
            newWorkspace()
            return
        }
        workspaces = restored
        selected = min(max(0, snapshot.layout.selectedIndex), workspaces.count - 1)
        nextWorkspaceNumber = workspaces.count + 1
        reloadSidebar()
        rebuildContent()
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.saveNow()
        }
        RunLoop.main.add(timer, forMode: .common)
        saveTimer = timer
    }

    func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        let layout = TerminalLayout(workspaces: workspaces, selectedIndex: selected)
        _ = layoutStore.save(layout)
        saveWindowFrameNow()
    }

    private func scheduleWindowFrameSave() {
        windowFrameTimer?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.saveWindowFrameNow()
        }
        RunLoop.main.add(timer, forMode: .common)
        windowFrameTimer = timer
    }

    private func saveWindowFrameNow() {
        windowFrameTimer?.invalidate()
        windowFrameTimer = nil
        guard let window else { return }
        _ = windowStateStore.save(TerminalWindowState(frame: window.frame))
    }

    @objc func closeWorkspaceAction(_ sender: Any?) {
        if quakePanel?.isKeyWindow == true {
            hideQuake()
            return
        }
        closeSelectedWorkspace()
    }

    private func closeSelectedWorkspace() {
        guard workspaces.indices.contains(selected), workspaces.count > 1 else {
            NSSound.beep()
            return
        }
        let workspace = workspaces[selected]
        guard confirmClosing(workspace.paneIDs, in: workspace) else { return }
        disposeWorkspace(at: selected)
        attentionWorkspaces.remove(workspaces[selected].id)
        workspaces.remove(at: selected)
        selected = min(selected, workspaces.count - 1)
        reloadSidebar()
        rebuildContent()
        scheduleSave()
    }

    @objc func newWorkspaceMenuAction(_ sender: NSButton) {
        let menu = NSMenu()
        let workspaceItem = NSMenuItem(title: "New Workspace",
                                       action: #selector(newWorkspaceAction(_:)),
                                       keyEquivalent: "")
        workspaceItem.target = self
        menu.addItem(workspaceItem)

        let hasTmux = TmuxSession.executableURL() != nil
        let tmuxItem = NSMenuItem(
            title: hasTmux ? "New tmux Session" : "New tmux Session (tmux not installed)",
            action: #selector(newTmuxSessionAction(_:)),
            keyEquivalent: ""
        )
        tmuxItem.target = self
        tmuxItem.isEnabled = hasTmux
        menu.addItem(tmuxItem)

        let profiles = terminalSettings.sshProfiles.filter(\.isValid)
        if profiles.isEmpty == false {
            menu.addItem(.separator())
            for profile in profiles {
                let item = NSMenuItem(title: "New SSH: \(profile.displayName)",
                                      action: #selector(newSSHSessionAction(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = profile.id.uuidString
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: sender.bounds.height + 4),
                   in: sender)
    }

    @objc func newTmuxSessionAction(_ sender: Any?) {
        let id = UUID()
        let name = TmuxSession.name(for: id)
        var workspace = TerminalWorkspace(id: id, title: "tmux \(name.suffix(4))")
        workspace.setCommand(TmuxSession.command(sessionName: name),
                             for: workspace.focusedPane)
        workspaces.append(workspace)
        selected = workspaces.count - 1
        reloadSidebar()
        rebuildContent()
        scheduleSave()
    }

    @objc func newSSHSessionAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let profile = terminalSettings.sshProfiles.first(where: { $0.id.uuidString == raw }),
              let command = profile.commandLine() else {
            NSSound.beep()
            return
        }
        var workspace = TerminalWorkspace(title: profile.displayName)
        workspace.setCommand(command, for: workspace.focusedPane)
        workspaces.append(workspace)
        selected = workspaces.count - 1
        reloadSidebar()
        rebuildContent()
        scheduleSave()
    }

    @objc func splitRightAction(_ sender: Any?) {
        splitFocusedPane(orientation: .sideBySide)
    }

    @objc func splitDownAction(_ sender: Any?) {
        splitFocusedPane(orientation: .stacked)
    }

    private func splitFocusedPane(orientation: SplitOrientation) {
        guard selected < workspaces.count else { return }
        var workspace = workspaces[selected]
        let directory = workspace.directory(for: workspace.focusedPane)
        guard let newPane = workspace.split(workspace.focusedPane,
                                            orientation: orientation) else { return }
        if let directory { workspace.setDirectory(directory, for: newPane) }
        workspaces[selected] = workspace
        reloadSidebar()
        rebuildContent()
        scheduleSave()
    }

    @objc func toggleZoomAction(_ sender: Any?) {
        guard selected < workspaces.count else { return }
        workspaces[selected].toggleZoom()
        rebuildContent()
        scheduleSave()
    }

    @objc func equalizeSplitsAction(_ sender: Any?) {
        guard selected < workspaces.count else { return }
        workspaces[selected].equalizeSplits()
        rebuildContent()
        scheduleSave()
    }

    @objc func closePaneAction(_ sender: Any?) {
        if quakePanel?.isKeyWindow == true {
            hideQuake()
            return
        }
        closeFocusedPane()
    }

    private func closeFocusedPane() {
        guard selected < workspaces.count else { return }
        let workspace = workspaces[selected]
        // ⌘W closes the workspace when it holds a single terminal, like a tab;
        // with a single workspace it hides the window and keeps the shell.
        guard workspace.paneCount > 1 else {
            if workspaces.count == 1 {
                window?.performClose(nil)
            } else {
                closeSelectedWorkspace()
            }
            return
        }
        let pane = workspace.focusedPane
        guard confirmClosing([pane], in: workspace) else { return }
        var updated = workspace
        guard updated.remove(pane) else {
            NSSound.beep()
            return
        }
        disposePane(pane)
        workspaces[selected] = updated
        reloadSidebar()
        rebuildContent()
        focusPane(updated.focusedPane)
        scheduleSave()
    }

    /// A close that would end a running command asks first. Cancel is the
    /// default button so Return cannot lose the process.
    private func confirmClosing(_ panes: [PaneID], in workspace: TerminalWorkspace) -> Bool {
        let busy = panes.filter { hasRunningCommand($0, in: workspace) }.count
        guard busy > 0 else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if panes.count == 1 {
            alert.messageText = "Close this terminal?"
            alert.informativeText = "A command is still running. Closing the terminal ends it."
        } else {
            alert.messageText = "Close this workspace?"
            alert.informativeText = busy == 1
                ? "A command is still running in one of its terminals."
                : "Commands are still running in \(busy) of its \(panes.count) terminals."
        }
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Close")
        alert.buttons.last?.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func hasRunningCommand(_ pane: PaneID,
                                   in workspace: TerminalWorkspace) -> Bool {
        guard let view = paneViews[pane]?.surfaceView else { return false }
        return view.hasRunningCommand(configuredCommand: workspace.command(for: pane) != nil)
    }

    /// Called when the shell exits or Ghostty asks to close a surface.
    func paneDidExit(_ view: TerminalSurfaceView) {
        if view === quakeHost?.surfaceView {
            closeQuake()
            return
        }
        guard let pane = view.paneID,
              let index = workspaces.firstIndex(where: { $0.contains(pane) }) else { return }

        var workspace = workspaces[index]
        if workspace.paneCount > 1 {
            guard workspace.remove(pane) else { return }
            disposePane(pane)
            workspaces[index] = workspace
            reloadSidebar()
            if index == selected { rebuildContent(); focusPane(workspace.focusedPane) }
            scheduleSave()
            return
        }

        if workspaces.count == 1 {
            // The last shell ended: start a fresh workspace rather than leave
            // an empty window.
            disposeWorkspace(at: index)
            workspaces.removeAll()
            selected = 0
            nextWorkspaceNumber = 1
            newWorkspace()
        } else {
            disposeWorkspace(at: index)
            workspaces.remove(at: index)
            selected = min(index, workspaces.count - 1)
            reloadSidebar()
            rebuildContent()
            scheduleSave()
        }
    }

    /// Applies a status from the helper's CLI. Unknown workspace ids (a stale
    /// shell from another session) are ignored.
    func setAgentState(_ state: AgentState, forWorkspaceID id: UUID, label: String?) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        if state == .done, index == selected, window?.isKeyWindow == true {
            agentStates[id] = nil
            agentLabels[id] = nil
            reloadSidebar()
            return
        }
        agentStates[id] = state
        agentLabels[id] = label
        reloadSidebar()
    }

    /// Marks the workspace that owns `view`. Selecting it, or focusing it when
    /// it is already on screen, clears the mark.
    func markAttention(for view: TerminalSurfaceView?) {
        guard let view, let pane = view.paneID,
              let index = workspaces.firstIndex(where: { $0.contains(pane) }) else { return }
        if index == selected, window?.isKeyWindow == true { return }
        if attentionWorkspaces.insert(workspaces[index].id).inserted {
            reloadSidebar()
        }
    }

    private func clearAttention(for index: Int) {
        guard index >= 0, index < workspaces.count else { return }
        if attentionWorkspaces.remove(workspaces[index].id) != nil {
            reloadSidebar()
        }
    }

    func updateTitle(for view: TerminalSurfaceView, title: String) {
        guard let pane = view.paneID,
              let index = workspaces.firstIndex(where: { $0.contains(pane) }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        workspaces[index].title = trimmed
        reloadSidebar()
        if index == selected { window?.title = trimmed }
        scheduleSave()
    }

    func updateDirectory(for view: TerminalSurfaceView, path: String) {
        guard let pane = view.paneID,
              let index = workspaces.firstIndex(where: { $0.contains(pane) }) else { return }
        workspaces[index].setDirectory(path, for: pane)
        scheduleSave()
    }

    // MARK: - Find

    /// ⌘F: open the find bar for the focused pane, or refocus the open one.
    @objc func showFindAction(_ sender: Any?) {
        if let active = activeSearch, active.view === focusedSurfaceView {
            active.host.findBar.focus()
        } else {
            showFind(for: focusedSurfaceView)
        }
    }

    @objc func findNextAction(_ sender: Any?) {
        navigateSearch(.next)
    }

    @objc func findPreviousAction(_ sender: Any?) {
        navigateSearch(.previous)
    }

    private var focusedSurfaceView: TerminalSurfaceView? {
        if quakeVisible, let host = quakeHost { return host.surfaceView }
        guard selected < workspaces.count else { return nil }
        return paneViews[workspaces[selected].focusedPane]?.surfaceView
    }

    private func host(for view: TerminalSurfaceView) -> TerminalPaneHostView? {
        if quakeHost?.surfaceView === view { return quakeHost }
        return paneViews.values.first { $0.surfaceView === view }
    }

    /// Opens the bar on `view`. Reopening on the surface already searching only
    /// moves the keyboard back to the field, unless Ghostty supplied a new
    /// needle (a `start_search` binding with a query).
    func showFind(for view: TerminalSurfaceView?, needle: String? = nil) {
        guard let view, let host = host(for: view) else { return }
        if let active = activeSearch, active.view === view {
            if let needle, needle.isEmpty == false, needle != host.findBar.needle {
                host.findBar.begin(needle: needle)
                view.lastSearchNeedle = needle
                view.performSearch(needle)
            }
            return
        }

        closeSearch(restoreFocus: false)
        let initial = needle ?? view.lastSearchNeedle
        wire(host.findBar, to: view)
        host.findBar.begin(needle: initial)
        activeSearch = ActiveSearch(view: view, host: host)
        if initial.isEmpty == false {
            view.performSearch(initial)
        }
    }

    /// Ghostty opened a search itself (a keybind or a query); mirror it in the
    /// bar. Our own `search:` calls also come back here, hence the idempotency.
    func searchDidStart(for view: TerminalSurfaceView, needle: String?) {
        if let needle, needle.isEmpty == false {
            showFind(for: view, needle: needle)
        } else if let active = activeSearch, active.view === view {
            active.host.findBar.focus()
        } else {
            showFind(for: view)
        }
    }

    /// The engine ended the session (Escape inside a Ghostty binding, or a
    /// surface close); hide the bar without asking it to end again.
    func searchDidEnd(for view: TerminalSurfaceView) {
        guard let active = activeSearch, active.view === view else { return }
        searchDebounce?.invalidate()
        searchDebounce = nil
        active.host.findBar.finish()
        activeSearch = nil
    }

    func searchTotalDidChange(for view: TerminalSurfaceView, total: Int?) {
        guard let active = activeSearch, active.view === view else { return }
        active.host.findBar.applyTotal(total)
    }

    func searchSelectedDidChange(for view: TerminalSurfaceView, selected: Int?) {
        guard let active = activeSearch, active.view === view else { return }
        active.host.findBar.applySelected(selected)
    }

    private func closeSearch(restoreFocus: Bool = true) {
        searchDebounce?.invalidate()
        searchDebounce = nil
        guard let active = activeSearch else { return }
        activeSearch = nil
        active.view.lastSearchNeedle = active.host.findBar.needle
        active.host.findBar.finish()
        active.view.endSearch()
        guard restoreFocus, active.view.surface != nil else { return }
        if quakeVisible, active.view === quakeHost?.surfaceView {
            quakePanel?.makeFirstResponder(active.view)
        } else {
            window?.makeFirstResponder(active.view)
        }
    }

    private func wire(_ bar: TerminalFindBar, to view: TerminalSurfaceView) {
        bar.onNeedleChange = { [weak self, weak view] text in
            guard let self, let view else { return }
            view.lastSearchNeedle = text
            scheduleSearch(text, for: view)
        }
        bar.onNavigate = { [weak self] direction in
            self?.navigateSearch(direction)
        }
        bar.onClose = { [weak self] in
            self?.closeSearch()
        }
    }

    /// Typing is cheap but the search is not; one delayed run per pause keeps a
    /// long scrollback from being rescanned on every keystroke. The fired
    /// closure checks again, so a superseded query cannot win.
    private func scheduleSearch(_ needle: String, for view: TerminalSurfaceView) {
        searchDebounce?.invalidate()
        searchDebounce = nil
        guard needle.isEmpty == false else {
            view.performSearch("")
            return
        }
        let timer = Timer(timeInterval: 0.12, repeats: false) { [weak self, weak view] _ in
            guard let self, let view, let active = self.activeSearch,
                  active.view === view,
                  active.host.findBar.needle == needle else { return }
            view.performSearch(needle)
        }
        RunLoop.main.add(timer, forMode: .common)
        searchDebounce = timer
    }

    private func navigateSearch(_ direction: TerminalSearchNavigation) {
        guard let active = activeSearch else {
            showFind(for: focusedSurfaceView)
            return
        }
        active.view.navigateSearch(direction)
    }

    // MARK: - Quake

    @objc func toggleQuake() {
        quakeVisible ? hideQuake() : showQuake()
    }

    func showQuake() {
        guard let host = quakeHost ?? makeQuakeHost() else { return }
        let panel = quakePanel ?? makeQuakePanel(host: host)
        panel.setFrame(quakeFrame(), display: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(host.surfaceView)
        host.isFocused = true
        quakeVisible = true
        host.surfaceView.setRendererVisible(true)
        updateRendererVisibility()
        // The panel's occlusion state catches up after it is ordered front.
        DispatchQueue.main.async { [weak self] in self?.updateRendererVisibility() }
    }

    func hideQuake() {
        guard quakeVisible else { return }
        quakeVisible = false
        quakeHost?.isFocused = false
        quakeHost?.surfaceView.setRendererVisible(false)
        quakePanel?.orderOut(nil)
        updateRendererVisibility()
    }

    func hideQuakeIfVisible() {
        hideQuake()
    }

    private func closeQuake() {
        if let quakeView = quakeHost?.surfaceView, activeSearch?.view === quakeView {
            closeSearch(restoreFocus: false)
        }
        quakeVisible = false
        quakePanel?.orderOut(nil)
        quakePanel = nil
        quakeHost?.surfaceView.detach()
        quakeHost?.removeFromSuperview()
        quakeHost = nil
        quakeWorkspace = nil
        updateRendererVisibility()
    }

    private func makeQuakeHost() -> TerminalPaneHostView? {
        let workspace = quakeWorkspace ?? TerminalWorkspace(title: "Quake")
        let pane = workspace.focusedPane
        let surface = TerminalSurfaceView(frame: .zero)
        surface.paneID = pane
        surface.shellCommand = terminalSettings.shell
        surface.hidesMouseWhileTyping = terminalSettings.hideMouseWhileTyping
        surface.environment["MAKIDESK_TERMINAL"] = "1"
        if let cliPath { surface.environment["MAKIDESK_CLI"] = cliPath }
        surface.environment["MAKIDESK_WORKSPACE_ID"] = workspace.id.uuidString
        let host = TerminalPaneHostView(paneID: pane, surfaceView: surface)
        host.accentColor = uiTheme.accent
        host.findBar.apply(theme: uiTheme)
        quakeWorkspace = workspace
        quakeHost = host
        surface.attach(runtime: runtime)
        return host
    }

    private func makeQuakePanel(host: TerminalPaneHostView) -> TerminalQuakePanel {
        let panel = TerminalQuakePanel(contentRect: quakeFrame(),
                                       styleMask: [.borderless],
                                       backing: .buffered,
                                       defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = true
        panel.backgroundColor = uiTheme.background
        panel.appearance = NSAppearance(named: uiTheme.isDark ? .darkAqua : .aqua)
        panel.hasShadow = true
        // A title and an identifier for Accessibility; MakiDesk leaves this
        // panel out of its window switcher by the identifier.
        panel.title = "MakiDesk Quake"
        panel.setAccessibilityIdentifier(TerminalIdentity.quakeAccessibilityIdentifier)
        panel.delegate = self
        panel.contentView = host
        quakePanel = panel
        return panel
    }

    /// The display the pointer is on; if no frame reports it, the one the
    /// helper's window is on, then the main one.
    private func quakeScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) {
            return screen
        }
        return window?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func quakeFrame() -> NSRect {
        let visible = quakeScreen()?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1000, height: 600)
        return TerminalQuakePlacement.frame(in: visible,
                                            heightFraction: terminalSettings.quakeHeightFraction)
    }

    // MARK: - Theme

    private func applyUITheme() {
        window?.appearance = NSAppearance(named: uiTheme.isDark ? .darkAqua : .aqua)
        window?.backgroundColor = uiTheme.background
        window?.titlebarAppearsTransparent = true
        sidebar.layer?.backgroundColor = uiTheme.surface.cgColor
        contentView.layer?.backgroundColor = uiTheme.background.cgColor
        applyQuakeAppearance()
        addButton?.contentTintColor = uiTheme.subtext
        closeButton.contentTintColor = uiTheme.subtext
        reloadSidebar()
        for host in paneViews.values {
            host.accentColor = uiTheme.accent
            host.findBar.apply(theme: uiTheme)
            host.updateBorder()
        }
        if let quakeHost {
            quakeHost.accentColor = uiTheme.accent
            quakeHost.findBar.apply(theme: uiTheme)
            quakeHost.updateBorder()
        }
    }

    private func applyQuakeAppearance() {
        quakePanel?.appearance = NSAppearance(named: uiTheme.isDark ? .darkAqua : .aqua)
        quakePanel?.backgroundColor = uiTheme.background
    }

    // MARK: - Settings

    func applyTerminalSettings() {
        let settings = TerminalSettingsStore().load()
        let theme = TerminalThemeStore().load()
        terminalSettings = settings
        uiTheme = TerminalUITheme(document: theme)
        applyUITheme()
        runtime.apply(settings: settings, theme: theme)
        for host in paneViews.values {
            host.surfaceView.shellCommand = settings.shell
            host.surfaceView.hidesMouseWhileTyping = settings.hideMouseWhileTyping
        }
        quakeHost?.surfaceView.shellCommand = settings.shell
        quakeHost?.surfaceView.hidesMouseWhileTyping = settings.hideMouseWhileTyping
    }

    var allSurfaces: [ghostty_surface_t] {
        var surfaces = paneViews.values.compactMap(\.surfaceView.surface)
        if let quake = quakeHost?.surfaceView.surface { surfaces.append(quake) }
        return surfaces
    }

    // MARK: - Content

    private func rebuildContent() {
        guard selected < workspaces.count else { return }
        // A rebuild can move the searched surface into another tree (or remove
        // it); one session per window stays cheaper and clearer than tracking
        // it across workspaces.
        closeSearch(restoreFocus: false)
        isBuilding = true
        currentRootView?.removeFromSuperview()
        let workspace = workspaces[selected]
        let node = workspace.visibleZoomedPane.map(SplitNode.pane) ?? workspace.root
        let root = build(node, path: [])
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        currentRootView = root
        updateFocusBorders()
        focusPane(workspace.visibleZoomedPane ?? workspace.focusedPane)
        updateRendererVisibility()
        DispatchQueue.main.async { [weak self] in self?.isBuilding = false }
    }

    private func build(_ node: SplitNode, path: [Int]) -> NSView {
        switch node {
        case let .pane(id):
            return paneHost(for: id)
        case let .split(orientation, _, first, second):
            let split = WorkspaceSplitView()
            split.path = path
            split.controller = self
            split.delegate = self
            split.isVertical = orientation == .sideBySide
            split.dividerStyle = .thin
            split.addArrangedSubview(build(first, path: path + [0]))
            split.addArrangedSubview(build(second, path: path + [1]))
            return split
        }
    }

    private func paneHost(for pane: PaneID) -> TerminalPaneHostView {
        if let existing = paneViews[pane] { return existing }

        let surface = TerminalSurfaceView(frame: .zero)
        surface.paneID = pane
        if selected < workspaces.count {
            surface.workingDirectory = workspaces[selected].directory(for: pane)
        }
        surface.shellCommand = selected < workspaces.count
            ? (workspaces[selected].command(for: pane) ?? terminalSettings.shell)
            : terminalSettings.shell
        surface.onFocus = { [weak self] in self?.focusPane(pane) }
        surface.hidesMouseWhileTyping = terminalSettings.hideMouseWhileTyping

        surface.environment["MAKIDESK_TERMINAL"] = "1"
        if let cliPath { surface.environment["MAKIDESK_CLI"] = cliPath }
        if selected < workspaces.count {
            surface.environment["MAKIDESK_WORKSPACE_ID"] = workspaces[selected].id.uuidString
        }
        let host = TerminalPaneHostView(paneID: pane, surfaceView: surface)
        host.accentColor = uiTheme.accent
        host.findBar.apply(theme: uiTheme)
        paneViews[pane] = host
        surface.attach(runtime: runtime)
        return host
    }

    private func disposePane(_ pane: PaneID) {
        guard let host = paneViews.removeValue(forKey: pane) else { return }
        if activeSearch?.view === host.surfaceView {
            closeSearch(restoreFocus: false)
        }
        host.surfaceView.detach()
        host.removeFromSuperview()
    }

    private func disposeWorkspace(at index: Int) {
        guard index < workspaces.count else { return }
        for pane in workspaces[index].paneIDs { disposePane(pane) }
    }

    func detachAllPanes() {
        closeQuake()
        for pane in Array(paneViews.keys) { disposePane(pane) }
        paneViews.removeAll()
        runtime.onSurfaceClosed = nil
        runtime.onTitle = nil
        runtime.onDirectory = nil
    }

    // MARK: - Window

    /// The red button hides the window instead of closing it: the surfaces,
    /// their processes and the saved layout stay alive, and MakiDesk's ⌃⌥O
    /// shows the same window again. Only Quit ends the sessions.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        clearAttention(for: selected)
        if workspaces.indices.contains(selected) {
            let id = workspaces[selected].id
            if agentStates[id] == .done {
                agentStates[id] = nil
                agentLabels[id] = nil
                reloadSidebar()
            }
        }
        // Key transitions are not always accompanied by an occlusion change,
        // and the first one is what lifts the pre-show state at launch.
        updateRendererVisibility()
        DispatchQueue.main.async { [weak self] in self?.updateRendererVisibility() }
    }

    func windowDidBecomeMain(_ notification: Notification) {
        updateRendererVisibility()
    }

    /// Only the main window's frame is remembered; the quake is placed fresh
    /// on every show.
    func windowDidMove(_ notification: Notification) {
        guard let moved = notification.object as? NSWindow, moved === window else { return }
        scheduleWindowFrameSave()
    }

    func windowDidResize(_ notification: Notification) {
        guard let resized = notification.object as? NSWindow, resized === window else { return }
        scheduleWindowFrameSave()
    }

    /// A hidden window, a hidden app or a display that sleeps makes the whole
    /// surface set stop rendering; the shells keep consuming output. Only the
    /// selected workspace is on screen.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        updateRendererVisibility()
    }

    private var mainWindowReportedVisible = false
    private var quakePanelReportedVisible = false

    private func updateRendererVisibility() {
        let mainVisible = isVisible(window, reported: &mainWindowReportedVisible)
        var visiblePanes: Set<PaneID> = []
        if workspaces.indices.contains(selected) {
            let workspace = workspaces[selected]
            visiblePanes = Set(workspace.visibleZoomedPane.map { [$0] } ?? workspace.paneIDs)
        }
        for (pane, host) in paneViews {
            host.surfaceView.setRendererVisible(mainVisible && visiblePanes.contains(pane))
        }
        let quakeOnScreen = quakeVisible
            && isVisible(quakePanel, reported: &quakePanelReportedVisible)
        quakeHost?.surfaceView.setRendererVisible(quakeOnScreen)
    }

    /// `occlusionState` is authoritative on a real display; until a window has
    /// reported it once, a virtual display's ordinary on-screen state is
    /// trusted, and a key window is always visible.
    private func isVisible(_ window: NSWindow?, reported: inout Bool) -> Bool {
        guard let window else { return false }
        let occlusionVisible = window.occlusionState.contains(.visible)
        if occlusionVisible { reported = true }
        return TerminalRendererVisibility.isVisible(
            occlusionVisible: occlusionVisible,
            windowHasReportedVisible: reported,
            isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized,
            isOnActiveSpace: window.isOnActiveSpace,
            isKeyWindow: window.isKeyWindow
        )
    }

    // MARK: - Focus

    @objc func focusPaneLeftAction(_ sender: Any?) { focusPane(in: .left) }
    @objc func focusPaneRightAction(_ sender: Any?) { focusPane(in: .right) }
    @objc func focusPaneUpAction(_ sender: Any?) { focusPane(in: .up) }
    @objc func focusPaneDownAction(_ sender: Any?) { focusPane(in: .down) }

    /// Keyboard focus between splits. The visible frames are read from the
    /// live view hierarchy, so unequal splits and the real divider positions
    /// are what the neighbour search sees.
    private func focusPane(in direction: PaneFocusDirection) {
        guard workspaces.indices.contains(selected) else { return }
        guard workspaces[selected].visibleZoomedPane == nil else {
            NSSound.beep()
            return
        }
        var frames: [PaneID: CGRect] = [:]
        for pane in workspaces[selected].paneIDs {
            guard let host = paneViews[pane], host.window != nil else { continue }
            let frame = host.convert(host.bounds, to: contentView)
            if frame.width > 0, frame.height > 0 { frames[pane] = frame }
        }
        guard let target = TerminalPaneNavigation.neighbor(
            of: workspaces[selected].focusedPane,
            in: frames,
            direction: direction
        ) else {
            NSSound.beep()
            return
        }
        focusPane(target)
    }

    private func focusPane(_ pane: PaneID) {
        guard selected < workspaces.count, workspaces[selected].contains(pane) else { return }
        if workspaces[selected].focus(pane) == false { return }
        clearAttention(for: selected)
        updateFocusBorders()
        if let host = paneViews[pane] {
            window?.makeFirstResponder(host.surfaceView)
        }
    }

    private func updateFocusBorders() {
        guard selected < workspaces.count else { return }
        let focused = workspaces[selected].focusedPane
        for (pane, host) in paneViews {
            host.isFocused = pane == focused
        }
    }

    private static func agentColour(_ state: AgentState) -> NSColor {
        switch state {
        case .working: return .systemBlue
        case .waiting: return .systemOrange
        case .done: return .systemGreen
        }
    }

    // MARK: - Sidebar table

    func numberOfRows(in tableView: NSTableView) -> Int {
        workspaces.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = WorkspaceRowView()
        view.selectedColor = uiTheme.surfaceSelected
        return view
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < workspaces.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("workspaceCell")
        let cell: WorkspaceCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self)
            as? WorkspaceCellView {
            cell = reused
        } else {
            cell = WorkspaceCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            label.font = .systemFont(ofSize: 12.5, weight: .medium)
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: cell.accessoriesStack.leadingAnchor,
                                                constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let workspace = workspaces[row]
        let isCurrent = row == selected
        cell.textField?.stringValue = workspace.title
        cell.textField?.textColor = isCurrent ? uiTheme.text : uiTheme.subtext
        cell.textField?.font = .systemFont(ofSize: 12.5,
                                           weight: isCurrent ? .semibold : .medium)
        cell.layer?.backgroundColor = isCurrent
            ? uiTheme.surfaceSelected.cgColor
            : NSColor.clear.cgColor
        cell.accentBar.layer?.backgroundColor = uiTheme.accent.cgColor
        cell.accentBar.isHidden = isCurrent == false
        let paneCount = workspace.paneCount
        cell.countLabel.stringValue = paneCount > 1 ? "\(paneCount)" : ""
        cell.countLabel.textColor = uiTheme.subtext
        cell.countLabel.isHidden = paneCount <= 1
        cell.countLabel.toolTip = paneCount > 1 ? "\(paneCount) terminals" : nil
        cell.dot.layer?.backgroundColor = uiTheme.accent.cgColor
        cell.dot.isHidden = attentionWorkspaces.contains(workspace.id) == false
        if let state = agentStates[workspace.id] {
            cell.agentDot.isHidden = false
            cell.agentDot.layer?.backgroundColor = Self.agentColour(state).cgColor
            cell.toolTip = agentLabels[workspace.id]
        } else {
            cell.agentDot.isHidden = true
            cell.toolTip = nil
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectWorkspace(at: tableView.selectedRow)
    }

    @objc func selectWorkspaceAction(_ sender: NSMenuItem) {
        selectWorkspace(at: sender.tag)
    }

    @objc func previousWorkspaceAction(_ sender: Any?) {
        guard let index = TerminalWorkspaceNavigation.cycledIndex(
            from: selected, count: workspaces.count, delta: -1
        ) else { return }
        selectWorkspace(at: index)
    }

    @objc func nextWorkspaceAction(_ sender: Any?) {
        guard let index = TerminalWorkspaceNavigation.cycledIndex(
            from: selected, count: workspaces.count, delta: 1
        ) else { return }
        selectWorkspace(at: index)
    }

    private func selectWorkspace(at row: Int) {
        guard workspaces.indices.contains(row), row != selected else { return }
        selected = row
        clearAttention(for: row)
        let id = workspaces[row].id
        if agentStates[id] == .done {
            agentStates[id] = nil
            agentLabels[id] = nil
        }
        reloadSidebar()
        rebuildContent()
        scheduleSave()
    }

    private func reloadSidebar() {
        fitSidebarColumn()
        tableView.reloadData()
        closeButton.isEnabled = workspaces.count > 1
        if selected < workspaces.count {
            tableView.selectRowIndexes(IndexSet(integer: selected),
                                       byExtendingSelection: false)
        }
    }

    /// Keeps the single column as wide as the sidebar, so the row background
    /// does not leave a blank strip on the right when the split is resized.
    private func fitSidebarColumn() {
        guard let column = tableView.tableColumns.first else { return }
        let width = tableView.enclosingScrollView?.contentSize.width ?? sidebar.bounds.width
        guard width > 0, abs(column.width - width) > 0.5 else { return }
        column.width = width
    }

    // MARK: - Reordering

    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard workspaces.indices.contains(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.workspaceDragType)
        return item
    }

    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation)
        -> NSDragOperation {
        guard info.draggingSource as? NSTableView === tableView else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let raw = info.draggingPasteboard.string(forType: Self.workspaceDragType),
              let source = Int(raw),
              workspaces.indices.contains(source) else { return false }
        // `row` is the insertion index before the source is removed; dropping
        // below the source shifts the final index up by one.
        var destination = row > source ? row - 1 : row
        destination = min(max(destination, 0), workspaces.count - 1)
        guard destination != source else { return false }
        applyWorkspaceMove(from: source, to: destination)
        return true
    }

    @objc func moveWorkspaceUpAction(_ sender: Any?) {
        moveSelectedWorkspace(by: -1)
    }

    @objc func moveWorkspaceDownAction(_ sender: Any?) {
        moveSelectedWorkspace(by: 1)
    }

    private func moveSelectedWorkspace(by delta: Int) {
        let destination = selected + delta
        guard workspaces.indices.contains(selected),
              workspaces.indices.contains(destination) else { return }
        applyWorkspaceMove(from: selected, to: destination)
    }

    /// Reorders the sidebar without switching the shell on screen: the moved
    /// row and the selected row can be different.
    private func applyWorkspaceMove(from source: Int, to destination: Int) {
        guard workspaces.indices.contains(source),
              workspaces.indices.contains(destination),
              source != destination else { return }
        let selectedID = workspaces.indices.contains(selected) ? workspaces[selected].id : nil
        let moved = workspaces.remove(at: source)
        workspaces.insert(moved, at: destination)
        if let selectedID,
           let index = workspaces.firstIndex(where: { $0.id == selectedID }) {
            selected = index
        }
        reloadSidebar()
        scheduleSave()
    }

    // MARK: - Split view

    func splitViewDidResizeSubviews(_ notification: Notification) {
        fitSidebarColumn()
        guard isBuilding == false,
              let split = notification.object as? WorkspaceSplitView,
              split.subviews.count >= 2,
              selected < workspaces.count else { return }
        let total = split.isVertical ? split.bounds.width : split.bounds.height
        guard total > 0 else { return }
        let first = split.isVertical ? split.subviews[0].frame.width
                                     : split.subviews[0].frame.height
        workspaces[selected].setRatio(Double(first / total), at: split.path)
    }

    func ratio(at path: [Int]) -> Double {
        guard selected < workspaces.count,
              case let .split(_, ratio, _, _) = workspaces[selected].node(at: path) else {
            return 0.5
        }
        return ratio
    }
}
