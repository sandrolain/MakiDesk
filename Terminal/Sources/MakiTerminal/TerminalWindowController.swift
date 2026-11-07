import AppKit
import GhosttyKit
import MakiShared
import MakiTerminalCore

/// One terminal pane and its focus border (F1).
final class TerminalPaneHostView: NSView {
    let paneID: PaneID
    let surfaceView: TerminalSurfaceView
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
        updateBorder()
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    private func updateBorder() {
        guard let layer else { return }
        layer.borderWidth = isFocused ? 1 : 0
        layer.borderColor = NSColor(red: 0.796, green: 0.651, blue: 0.969, alpha: 1).cgColor
    }
}

/// A sidebar row with an attention dot (F3 L1).
final class WorkspaceCellView: NSTableCellView {
    let dot = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dot.isHidden = true
        addSubview(dot)
        NSLayoutConstraint.activate([
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
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
    private var terminalSettings: TerminalSettingsDocument
    private var saveTimer: Timer?
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
    /// Workspaces that produced something worth returning to. Session state:
    /// a dot in the sidebar, cleared by selecting the workspace.
    private var attentionWorkspaces: Set<UUID> = []

    private let splitView = NSSplitView()
    private let sidebar = NSView()
    private let contentView = NSView()
    private let tableView = NSTableView()
    private let closeButton = NSButton()

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
        window.center()
        buildInterface()
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
        tableView.headerView = nil
        tableView.rowHeight = 30
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        scroll.documentView = tableView

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
    }

    @objc func closeWorkspaceAction(_ sender: Any?) {
        closeSelectedWorkspace()
    }

    private func closeSelectedWorkspace() {
        guard workspaces.count > 1 else {
            NSSound.beep()
            return
        }
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
        rebuildContent()
        scheduleSave()
    }

    @objc func closePaneAction(_ sender: Any?) {
        closeFocusedPane()
    }

    private func closeFocusedPane() {
        guard selected < workspaces.count else { return }
        var workspace = workspaces[selected]
        let pane = workspace.focusedPane
        guard workspace.remove(pane) else {
            NSSound.beep()
            return
        }
        disposePane(pane)
        workspaces[selected] = workspace
        rebuildContent()
        focusPane(workspace.focusedPane)
        scheduleSave()
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

    /// Marks the workspace that owns `view`. Selecting it, or focusing it when
    /// it is already on screen, clears the mark.
    func markAttention(for view: TerminalSurfaceView?) {
        guard let view, let pane = view.paneID,
              let index = workspaces.firstIndex(where: { $0.contains(pane) }) else { return }
        if index == selected, window?.isKeyWindow == true { return }
        if attentionWorkspaces.insert(workspaces[index].id).inserted {
            tableView.reloadData()
        }
    }

    private func clearAttention(for index: Int) {
        guard index >= 0, index < workspaces.count else { return }
        if attentionWorkspaces.remove(workspaces[index].id) != nil {
            tableView.reloadData()
        }
    }

    func updateTitle(for view: TerminalSurfaceView, title: String) {
        guard let pane = view.paneID,
              let index = workspaces.firstIndex(where: { $0.contains(pane) }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        workspaces[index].title = trimmed
        tableView.reloadData()
        if index == selected { window?.title = trimmed }
        scheduleSave()
    }

    func updateDirectory(for view: TerminalSurfaceView, path: String) {
        guard let pane = view.paneID,
              let index = workspaces.firstIndex(where: { $0.contains(pane) }) else { return }
        workspaces[index].setDirectory(path, for: pane)
        scheduleSave()
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
    }

    func hideQuake() {
        guard quakeVisible else { return }
        quakeVisible = false
        quakeHost?.isFocused = false
        quakePanel?.orderOut(nil)
    }

    func hideQuakeIfVisible() {
        hideQuake()
    }

    private func closeQuake() {
        quakeVisible = false
        quakePanel?.orderOut(nil)
        quakePanel = nil
        quakeHost?.surfaceView.detach()
        quakeHost?.removeFromSuperview()
        quakeHost = nil
        quakeWorkspace = nil
    }

    private func makeQuakeHost() -> TerminalPaneHostView? {
        let workspace = quakeWorkspace ?? TerminalWorkspace(title: "Quake")
        let pane = workspace.focusedPane
        let surface = TerminalSurfaceView(frame: .zero)
        surface.paneID = pane
        surface.shellCommand = terminalSettings.shell
        surface.environment["MAKIDESK_TERMINAL"] = "1"
        surface.environment["MAKIDESK_WORKSPACE_ID"] = workspace.id.uuidString
        let host = TerminalPaneHostView(paneID: pane, surfaceView: surface)
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
        panel.backgroundColor = .black
        panel.hasShadow = true
        panel.contentView = host
        quakePanel = panel
        return panel
    }

    private func quakeFrame() -> NSRect {
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
            return NSRect(x: 0, y: 0, width: 1000, height: 420)
        }
        let height = max(240, visible.height * terminalSettings.quakeHeightFraction)
        return NSRect(x: visible.minX, y: visible.maxY - height,
                      width: visible.width, height: height)
    }

    // MARK: - Settings

    func applyTerminalSettings() {
        let settings = TerminalSettingsStore().load()
        let theme = TerminalThemeStore().load()
        terminalSettings = settings
        runtime.apply(settings: settings, theme: theme)
        for host in paneViews.values {
            host.surfaceView.shellCommand = settings.shell
        }
        quakeHost?.surfaceView.shellCommand = settings.shell
    }

    var allSurfaces: [ghostty_surface_t] {
        var surfaces = paneViews.values.compactMap(\.surfaceView.surface)
        if let quake = quakeHost?.surfaceView.surface { surfaces.append(quake) }
        return surfaces
    }

    // MARK: - Content

    private func rebuildContent() {
        guard selected < workspaces.count else { return }
        isBuilding = true
        currentRootView?.removeFromSuperview()
        let root = build(workspaces[selected].root, path: [])
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
        focusPane(workspaces[selected].focusedPane)
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

        surface.environment["MAKIDESK_TERMINAL"] = "1"
        if selected < workspaces.count {
            surface.environment["MAKIDESK_WORKSPACE_ID"] = workspaces[selected].id.uuidString
        }
        let host = TerminalPaneHostView(paneID: pane, surfaceView: surface)
        paneViews[pane] = host
        surface.attach(runtime: runtime)
        return host
    }

    private func disposePane(_ pane: PaneID) {
        guard let host = paneViews.removeValue(forKey: pane) else { return }
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

    func windowDidBecomeKey(_ notification: Notification) {
        clearAttention(for: selected)
    }

    // MARK: - Focus

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

    // MARK: - Sidebar table

    func numberOfRows(in tableView: NSTableView) -> Int {
        workspaces.count
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
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.dot.leadingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = workspaces[row].title
        cell.dot.isHidden = attentionWorkspaces.contains(workspaces[row].id) == false
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < workspaces.count, row != selected else { return }
        selected = row
        clearAttention(for: row)
        rebuildContent()
        scheduleSave()
    }

    private func reloadSidebar() {
        tableView.reloadData()
        closeButton.isEnabled = workspaces.count > 1
        if selected < workspaces.count {
            tableView.selectRowIndexes(IndexSet(integer: selected),
                                       byExtendingSelection: false)
        }
    }

    // MARK: - Split view

    func splitViewDidResizeSubviews(_ notification: Notification) {
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
