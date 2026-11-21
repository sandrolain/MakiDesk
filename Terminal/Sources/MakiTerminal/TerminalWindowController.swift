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
            findBar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
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
    let transportLabel = NSTextField(labelWithString: "")
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

        transportLabel.translatesAutoresizingMaskIntoConstraints = false
        transportLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        transportLabel.textColor = .tertiaryLabelColor
        transportLabel.isHidden = true

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
        accessoriesStack.setViews([transportLabel, countLabel, dot, agentDot], in: .leading)
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
    weak var controller: TerminalWindowController?
    var isApplyingStoredRatio = false
    private var didScheduleInitialPosition = false

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0,
              subviews.count >= 2, controller != nil,
              didScheduleInitialPosition == false else { return }
        didScheduleInitialPosition = true
        DispatchQueue.main.async { [weak self] in
            self?.applyStoredRatio()
        }
    }

    private func applyStoredRatio() {
        guard let controller, bounds.width > 0, bounds.height > 0,
              subviews.count >= 2 else { return }
        let total = isVertical ? bounds.width : bounds.height
        let available = total - dividerThickness
        guard available > 0 else { return }
        let target = available * controller.ratio(at: path)
        let current = isVertical ? subviews[0].frame.width : subviews[0].frame.height
        guard abs(current - target) > 1 else { return }
        isApplyingStoredRatio = true
        setPosition(target, ofDividerAt: 0)
        isApplyingStoredRatio = false
    }
}

/// A two-pane root layout with a constraint-backed, draggable sidebar.
/// NSSplitView can recalculate its divider from pane constraints after layout,
/// so the root uses an explicit width constraint like the Notes panel does.
final class TerminalSidebarSplitView: NSView {
    private static let minimumSidebar: CGFloat = 160
    private static let minimumContent: CGFloat = 360
    static let defaultSidebar: CGFloat = 220

    private let sidebarHolder = NSView()
    private let contentHolder = NSView()
    private let divider = TerminalSidebarDividerView()
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var sidebarWidth = TerminalSidebarSplitView.defaultSidebar
    var onSidebarWidthChange: (() -> Void)?

    var currentSidebarWidth: CGFloat {
        sidebarWidth
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        divider.onDrag = { [weak self] delta in self?.resizeSidebar(by: delta) }
        for view in [sidebarHolder, divider, contentHolder] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        sidebarWidthConstraint = sidebarHolder.widthAnchor.constraint(equalToConstant: sidebarWidth)
        NSLayoutConstraint.activate([
            sidebarHolder.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebarHolder.topAnchor.constraint(equalTo: topAnchor),
            sidebarHolder.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebarWidthConstraint,
            divider.leadingAnchor.constraint(equalTo: sidebarHolder.trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 5),
            contentHolder.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            contentHolder.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentHolder.topAnchor.constraint(equalTo: topAnchor),
            contentHolder.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let maximum = max(Self.minimumSidebar, bounds.width - 5 - Self.minimumContent)
        if sidebarWidth > maximum {
            setSidebarWidth(maximum)
        }
    }

    func setSides(sidebar: NSView, content: NSView) {
        for (view, holder) in [(sidebar, sidebarHolder), (content, contentHolder)] {
            view.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
                view.topAnchor.constraint(equalTo: holder.topAnchor),
                view.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            ])
        }
    }

    func setSidebarWidth(_ width: CGFloat, notify: Bool = false) {
        guard width.isFinite else { return }
        let maximum = bounds.width > 0
            ? max(Self.minimumSidebar, bounds.width - 5 - Self.minimumContent)
            : CGFloat.greatestFiniteMagnitude
        let wanted = min(max(width, Self.minimumSidebar), maximum)
        guard wanted != sidebarWidth else { return }
        sidebarWidth = wanted
        sidebarWidthConstraint.constant = wanted
        if notify { onSidebarWidthChange?() }
    }

    private func resizeSidebar(by delta: CGFloat) {
        setSidebarWidth(sidebarWidth + delta, notify: true)
    }
}

private final class TerminalSidebarDividerView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var previousX: CGFloat?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSBezierPath(rect: NSRect(x: (bounds.width - 1) / 2,
                                  y: 0, width: 1, height: bounds.height)).fill()
    }

    override func mouseDown(with event: NSEvent) {
        previousX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        if let previousX { onDrag?(x - previousX) }
        previousX = x
    }

    override func mouseUp(with event: NSEvent) {
        previousX = nil
    }
}

/// A scratch terminal that drops from the top of the screen.
final class TerminalQuakePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum TerminalLayoutSaveResult: Equatable {
    case saved
    case readOnly
    case failed
}

private final class GitSidebarNode {
    let name: String
    var status: String?
    let isDirectory: Bool
    var children: [GitSidebarNode] = []
    init(name: String, status: String? = nil, isDirectory: Bool = false) {
        self.name = name
        self.status = status
        self.isDirectory = isDirectory
    }
}

/// The helper's main window (F1): a sidebar of workspaces on the left, the
/// selected workspace's split tree on the right. Surfaces are reused across
/// rebuilds, so switching tabs never restarts a shell.
final class TerminalWindowController: NSWindowController,
                                      NSTableViewDataSource,
                                      NSTableViewDelegate,
                                      NSOutlineViewDataSource,
                                      NSOutlineViewDelegate,
                                      NSSplitViewDelegate,
                                      NSWindowDelegate {
    private static let minimumGitSidebarWidth: CGFloat = 140
    private static let minimumTerminalContentWidth: CGFloat = 180
    private static let gitSidebarDividerWidth: CGFloat = 5

    private let runtime: GhosttyRuntime
    private let layoutStore = TerminalLayoutStore()
    private let windowStateStore = TerminalWindowStateStore()
    private let persistenceQueue = DispatchQueue(label: "com.makidesk.terminal.persistence")
    private var terminalSettings: TerminalSettingsDocument
    private var uiTheme = TerminalUITheme.fallback
    private var addButton: NSButton?
    private var saveTimer: Timer?
    private var windowFrameTimer: Timer?
    private var layoutRevision: UInt64 = 0
    private var pendingLayoutWrite: (revision: UInt64, layout: TerminalLayout)?
    private var layoutWriteInFlight = false
    private var layoutPersistenceIsReadOnly = false
    private var persistenceWarnings: [String] = []
    private var isPersistenceWarningPresented = false
    private var windowFrameRevision: UInt64 = 0
    private var workspaces: [TerminalWorkspace] = []
    private var recoveryGeneration: UInt64 = 0
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
    private var gitRefreshLifecycle = GitSidebarRefreshLifecycle()
    private var gitRefreshTimer: Timer?
    private var gitRefreshInFlight = false
    private var gitRefreshPending = false
    private var gitSidebarVisible: Bool {
        get { gitRefreshLifecycle.isEnabled }
        set { gitRefreshLifecycle.setEnabled(newValue) }
    }
    private var gitSidebarWidth: NSLayoutConstraint?
    private var gitSidebarStoredWidth: CGFloat = 280
    private var gitRootTrailingConstraint: NSLayoutConstraint?
    private var gitSidebarContentConstraints: [NSLayoutConstraint] = []
    private let gitSidebar = NSView()
    private let gitSidebarDivider = TerminalSidebarDividerView()
    private let gitSidebarTitle = NSTextField(labelWithString: "Git changes")
    private let gitOutlineView = NSOutlineView()
    private var gitTreeRoots: [GitSidebarNode] = []

    private let splitView = TerminalSidebarSplitView(frame: .zero)
    private let sidebar = NSView()
    private let contentView = NSView()
    private let tableView = NSTableView()
    private let closeButton = NSButton()
    private let agentStatusLabel = NSTextField(labelWithString: "No active agent")
    private let codexUsageHeader = NSTextField(labelWithString: "Codex account")
    private let codexUsageDetails = NSTextField(labelWithString: "Usage is not available yet")
    private let codexUsageUpdated = NSTextField(labelWithString: "Not updated")
    private let codexRefreshButton = NSButton()
    private let codexUsageStack = NSStackView()
    private let codexUsageReader: AccountUsageProvider = CodexAccountUsageReader()
    private var codexUsage: CodexAccountUsage?
    private var codexUsageError: String?
    private var codexUsageTimer: Timer?
    private var codexUsageLifecycle = CodexUsageRefreshLifecycle()

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
        let savedWindowState = windowStateStore.load()
        if let saved = savedWindowState?.frame,
           let frame = TerminalWindowGeometry.restoredFrame(
               saved,
               screens: NSScreen.screens.map(\.visibleFrame)
           ) {
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }
        if let sidebarWidth = savedWindowState?.sidebarWidth {
            splitView.setSidebarWidth(CGFloat(sidebarWidth))
        }
        if let gitSidebarWidth = savedWindowState?.gitSidebarWidth,
           gitSidebarWidth.isFinite, gitSidebarWidth > 0 {
            self.gitSidebarStoredWidth = CGFloat(gitSidebarWidth)
        }
        splitView.onSidebarWidthChange = { [weak self] in
            guard let self else { return }
            self.splitView.layoutSubtreeIfNeeded()
            self.contentView.layoutSubtreeIfNeeded()
            if self.gitSidebar.isHidden == false { self.clampGitSidebarWidth() }
            self.scheduleWindowFrameSave()
        }
        if TmuxSession.executableURL() == nil {
            persistenceWarnings.append("tmux is not installed. Workspace layout will be restored, but live shells and running commands cannot survive quitting or a crash.")
        }
        if let version = windowStateStore.futureVersionOnDisk {
            persistenceWarnings.append("The saved Terminal window state uses format version \(version). This version will leave it untouched.")
        }
        uiTheme = TerminalUITheme(document: TerminalThemeStore().load())
        buildInterface()
        applyUITheme()
        restoreOrCreate()
        if savedWindowState?.gitSidebarVisible == true {
            gitSidebarVisible = true
            gitSidebarTitle.stringValue = "Git changes"
            setGitSidebarExpanded(true)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    // MARK: - Interface

    private func buildInterface() {
        splitView.translatesAutoresizingMaskIntoConstraints = false

        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.wantsLayer = true
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.wantsLayer = true

        splitView.setSides(sidebar: sidebar, content: contentView)
        window?.contentView = splitView
        buildSidebar()

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
        let settings = NSButton(image: NSImage(systemSymbolName: "gearshape",
                                               accessibilityDescription: "Terminal settings")!,
                                target: self, action: #selector(openSettingsAction(_:)))
        settings.isBordered = false
        settings.toolTip = "Terminal Settings"
        bar.addArrangedSubview(settings)
        bar.addArrangedSubview(NSView())

        agentStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        agentStatusLabel.font = .systemFont(ofSize: 11)
        agentStatusLabel.textColor = .secondaryLabelColor
        agentStatusLabel.lineBreakMode = .byTruncatingTail
        sidebar.addSubview(agentStatusLabel)

        codexUsageStack.translatesAutoresizingMaskIntoConstraints = false
        codexUsageStack.orientation = .vertical
        codexUsageStack.alignment = .leading
        codexUsageStack.spacing = 3
        codexUsageStack.edgeInsets = NSEdgeInsets(top: 6, left: 11, bottom: 6, right: 8)
        codexUsageStack.wantsLayer = true
        codexUsageStack.layer?.cornerRadius = 7

        codexUsageHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        let usageTopRow = NSStackView()
        usageTopRow.orientation = .horizontal
        usageTopRow.alignment = .centerY
        usageTopRow.spacing = 4
        codexRefreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh Codex usage")
        codexRefreshButton.isBordered = false
        codexRefreshButton.bezelStyle = .inline
        codexRefreshButton.target = self
        codexRefreshButton.action = #selector(refreshCodexUsageAction(_:))
        codexRefreshButton.toolTip = "Refresh Codex usage"
        usageTopRow.addArrangedSubview(codexUsageHeader)
        usageTopRow.addArrangedSubview(NSView())
        usageTopRow.addArrangedSubview(codexRefreshButton)

        codexUsageDetails.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        codexUsageDetails.textColor = .secondaryLabelColor
        codexUsageDetails.maximumNumberOfLines = 7
        codexUsageDetails.lineBreakMode = .byWordWrapping
        codexUsageDetails.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        codexUsageUpdated.font = .systemFont(ofSize: 9)
        codexUsageUpdated.textColor = .tertiaryLabelColor
        codexUsageStack.addArrangedSubview(usageTopRow)
        codexUsageStack.addArrangedSubview(codexUsageDetails)
        codexUsageStack.addArrangedSubview(codexUsageUpdated)
        for view in [usageTopRow, codexUsageDetails, codexUsageUpdated] {
            view.widthAnchor.constraint(equalTo: codexUsageStack.widthAnchor, constant: -19).isActive = true
        }
        sidebar.addSubview(codexUsageStack)

        let gitToggle = NSButton(image: NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "Toggle Git changes")!, target: self, action: #selector(toggleGitSidebar(_:)))
        gitToggle.isBordered = false
        gitToggle.toolTip = "Toggle Git changes for focused terminal"
        bar.addArrangedSubview(gitToggle)

        sidebar.addSubview(scroll)
        sidebar.addSubview(bar)
        gitSidebar.translatesAutoresizingMaskIntoConstraints = false
        gitSidebar.wantsLayer = true
        gitSidebar.layer?.backgroundColor = uiTheme.surface.cgColor
        gitSidebar.isHidden = true
        gitSidebarDivider.translatesAutoresizingMaskIntoConstraints = false
        gitSidebarDivider.isHidden = true
        gitSidebarDivider.onDrag = { [weak self] delta in
            self?.resizeGitSidebar(by: delta)
        }
        gitSidebarTitle.translatesAutoresizingMaskIntoConstraints = false
        gitSidebarTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let gitScroll = NSScrollView()
        gitScroll.translatesAutoresizingMaskIntoConstraints = false
        gitScroll.hasVerticalScroller = true
        gitScroll.borderType = .noBorder
        gitScroll.drawsBackground = false
        gitOutlineView.headerView = nil
        gitOutlineView.indentationPerLevel = 14
        gitOutlineView.rowSizeStyle = .small
        gitOutlineView.backgroundColor = uiTheme.surface
        gitOutlineView.dataSource = self
        gitOutlineView.delegate = self
        let gitColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("git-path"))
        gitColumn.title = "File"
        gitOutlineView.addTableColumn(gitColumn)
        gitOutlineView.outlineTableColumn = gitColumn
        gitScroll.documentView = gitOutlineView
        contentView.addSubview(gitSidebarDivider)
        gitSidebar.addSubview(gitSidebarTitle)
        gitSidebar.addSubview(gitScroll)
        contentView.addSubview(gitSidebar)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sidebar.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: agentStatusLabel.topAnchor, constant: -6),
            agentStatusLabel.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            agentStatusLabel.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            agentStatusLabel.bottomAnchor.constraint(equalTo: codexUsageStack.topAnchor, constant: -5),
            codexUsageStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 7),
            codexUsageStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -7),
            codexUsageStack.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -6),
            bar.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 34),
            gitSidebarDivider.trailingAnchor.constraint(equalTo: gitSidebar.leadingAnchor),
            gitSidebarDivider.widthAnchor.constraint(equalToConstant: Self.gitSidebarDividerWidth),
            gitSidebarDivider.topAnchor.constraint(equalTo: contentView.topAnchor),
            gitSidebarDivider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            gitSidebar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            gitSidebar.topAnchor.constraint(equalTo: contentView.topAnchor),
            gitSidebar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        gitSidebarContentConstraints = [
            gitSidebarTitle.leadingAnchor.constraint(equalTo: gitSidebar.leadingAnchor, constant: 12),
            gitSidebarTitle.trailingAnchor.constraint(equalTo: gitSidebar.trailingAnchor, constant: -8),
            gitSidebarTitle.topAnchor.constraint(equalTo: gitSidebar.topAnchor, constant: 12),
            gitScroll.leadingAnchor.constraint(equalTo: gitSidebar.leadingAnchor, constant: 12),
            gitScroll.trailingAnchor.constraint(equalTo: gitSidebar.trailingAnchor, constant: -8),
            gitScroll.topAnchor.constraint(equalTo: gitSidebarTitle.bottomAnchor, constant: 8),
            gitScroll.bottomAnchor.constraint(equalTo: gitSidebar.bottomAnchor, constant: -8),
        ]
        gitSidebarWidth = gitSidebar.widthAnchor.constraint(equalToConstant: 0)
        gitSidebarWidth?.priority = .required
        gitSidebarWidth?.constant = 0
        gitSidebarWidth?.isActive = true
    }

    // MARK: - Workspaces

    @objc func newWorkspaceAction(_ sender: Any?) {
        newWorkspace()
    }

    private func newWorkspace() {
        var workspace = TerminalWorkspace(title: "Workspace \(nextWorkspaceNumber)")
        nextWorkspaceNumber += 1
        workspace.setCommand(persistentPaneCommand(for: workspace.focusedPane,
                                                   workspaceID: workspace.id,
                                                   command: terminalSettings.shell),
                             for: workspace.focusedPane)
        workspaces.append(workspace)
        selected = workspaces.count - 1
        reloadSidebar()
        rebuildContent()
        scheduleSave()
    }

    // MARK: - Persistence

    private func restoreOrCreate() {
        defer { recoverOrphanedTmuxSessions() }
        let snapshot = layoutStore.load()
        layoutPersistenceIsReadOnly = snapshot.canSave == false
        if case let .futureVersion(version) = snapshot.state {
            persistenceWarnings.append("The saved Terminal workspaces use format version \(version). Workspace changes will not be saved until you open them with a compatible version.")
        }
        let restored = snapshot.layout.workspaces.filter { $0.paneCount > 0 }
        guard restored.isEmpty == false else {
            newWorkspace()
            return
        }
        var didMigrateCommands = false
        workspaces = restored.map { savedWorkspace in
            var workspace = savedWorkspace
            for pane in workspace.paneIDs {
                let savedCommand = workspace.command(for: pane)
                if let savedCommand, TmuxSession.isAttachCommand(savedCommand) { continue }
                let persistentCommand = persistentPaneCommand(
                    for: pane, workspaceID: workspace.id,
                    command: savedCommand ?? terminalSettings.shell
                )
                guard persistentCommand != savedCommand else { continue }
                workspace.setCommand(persistentCommand, for: pane)
                didMigrateCommands = true
            }
            return workspace
        }
        selected = min(max(0, snapshot.layout.selectedIndex), workspaces.count - 1)
        nextWorkspaceNumber = workspaces.count + 1
        reloadSidebar()
        rebuildContent()
        if didMigrateCommands { scheduleSave() }
    }

    private func recoverOrphanedTmuxSessions() {
        guard TmuxSession.executableURL() != nil else { return }
        recoveryGeneration &+= 1
        let generation = recoveryGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = TmuxSession.existingPaneSessions()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.recoveryGeneration == generation else { return }
                let sessions: [TmuxSession.ExistingPaneSession]
                switch result {
                case let .success(found):
                    sessions = found
                case let .failure(error):
                    self.recordPersistenceWarning(
                        "Could not check for orphaned tmux sessions: \(error.userMessage)."
                    )
                    return
                }
                let knownPaneIDs = Set(self.workspaces.flatMap(\.paneIDs))
                let orphaned = sessions.filter { knownPaneIDs.contains($0.paneID) == false }
                guard orphaned.isEmpty == false else { return }
                let groups = Dictionary(grouping: orphaned) {
                    $0.workspaceID ?? $0.paneID.raw
                }
                var firstRecoveredIndex: Int?
                for groupID in groups.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                    guard let panes = groups[groupID]?.sorted(by: {
                        $0.paneID.description < $1.paneID.description
                    }), panes.isEmpty == false else { continue }
                    let workspaceID = panes.first?.workspaceID ?? groupID
                    var index = self.workspaces.firstIndex(where: { $0.id == workspaceID })
                    if index == nil {
                        let first = panes[0].paneID
                        self.workspaces.append(TerminalWorkspace(
                            id: workspaceID,
                            title: "Recovered Terminal",
                            firstPane: first
                        ))
                        index = self.workspaces.count - 1
                        firstRecoveredIndex = firstRecoveredIndex ?? index
                    }
                    guard let index else { continue }
                    for record in panes where self.workspaces[index].contains(record.paneID) == false {
                        var workspace = self.workspaces[index]
                        guard workspace.split(workspace.focusedPane,
                                               orientation: .sideBySide,
                                               newPane: record.paneID) != nil else { continue }
                        self.workspaces[index] = workspace
                    }
                    for record in panes {
                        self.workspaces[index].setCommand(
                            TmuxSession.command(for: record.paneID,
                                                environment: ["MAKIDESK_TERMINAL": "1",
                                                              "MAKIDESK_WORKSPACE_ID": workspaceID.uuidString]),
                            for: record.paneID
                        )
                    }
                }
                if let firstRecoveredIndex { self.selected = firstRecoveredIndex }
                self.reloadSidebar()
                self.rebuildContent()
                self.scheduleSave()
            }
        }
    }

    private func persistentPaneCommand(for pane: PaneID,
                                       workspaceID: UUID,
                                       command: String?) -> String? {
        guard let executable = TmuxSession.executableURL()?.path else { return command }
        if let command, TmuxSession.isAttachCommand(command) { return command }
        return TmuxSession.command(for: pane, shellCommand: command,
                                   environment: ["MAKIDESK_TERMINAL": "1",
                                                 "MAKIDESK_WORKSPACE_ID": workspaceID.uuidString],
                                   executable: executable)
    }

    private func scheduleSave() {
        layoutRevision &+= 1
        saveTimer?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.scheduleLayoutWrite()
        }
        RunLoop.main.add(timer, forMode: .common)
        saveTimer = timer
    }

    private func scheduleLayoutWrite() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard layoutPersistenceIsReadOnly == false else { return }
        pendingLayoutWrite = (
            revision: layoutRevision,
            layout: TerminalLayout(workspaces: workspaces, selectedIndex: selected)
        )
        startNextLayoutWrite()
    }

    private func startNextLayoutWrite() {
        guard layoutWriteInFlight == false, let write = pendingLayoutWrite else { return }
        pendingLayoutWrite = nil
        layoutWriteInFlight = true
        persistenceQueue.async { [weak self] in
            guard let self else { return }
            let saved = self.layoutStore.save(write.layout)
            let futureVersion = self.layoutStore.futureVersionOnDisk
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.layoutWriteInFlight = false
                guard write.revision == self.layoutRevision else {
                    self.startNextLayoutWrite()
                    return
                }
                self.handleLayoutWrite(saved: saved, futureVersion: futureVersion)
                self.startNextLayoutWrite()
            }
        }
    }

    private func handleLayoutWrite(saved: Bool, futureVersion: Int?) {
        if let futureVersion {
            layoutPersistenceIsReadOnly = true
            recordPersistenceWarning("The saved Terminal workspaces now use format version \(futureVersion). Workspace changes are not being saved.")
        } else if saved == false {
            recordPersistenceWarning("MakiDesk Terminal could not save the workspace layout. Check available disk space and file permissions; the last saved layout is still intact.")
        }
    }

    func saveNow() -> TerminalLayoutSaveResult {
        saveTimer?.invalidate()
        saveTimer = nil
        windowFrameTimer?.invalidate()
        windowFrameTimer = nil
        windowFrameRevision &+= 1
        layoutRevision &+= 1
        pendingLayoutWrite = nil
        let layout = TerminalLayout(workspaces: workspaces, selectedIndex: selected)
        let frameState = window.map { windowState(for: $0.frame) }
        let canWriteLayout = layoutPersistenceIsReadOnly == false
        let result = persistenceQueue.sync {
            let layoutSaved = canWriteLayout ? layoutStore.save(layout) : true
            let layoutFutureVersion = layoutStore.futureVersionOnDisk
            let frameSaved = frameState.map(windowStateStore.save) ?? true
            let frameFutureVersion = windowStateStore.futureVersionOnDisk
            return (layoutSaved, layoutFutureVersion, frameSaved, frameFutureVersion)
        }
        if let version = result.1 {
            layoutPersistenceIsReadOnly = true
            recordPersistenceWarning("The saved Terminal workspaces use format version \(version). Workspace changes are not being saved.")
        }
        if let version = result.3 {
            recordPersistenceWarning("The saved Terminal window state uses format version \(version). This version will leave it untouched.")
        }
        if result.0 == false && result.1 == nil {
            recordPersistenceWarning("MakiDesk Terminal could not save the workspace layout. Check available disk space and file permissions; the last saved layout is still intact.")
        }
        if result.2 == false && result.3 == nil {
            recordPersistenceWarning("MakiDesk Terminal could not save the window and sidebar sizes. Check available disk space and file permissions.")
        }
        if (result.0 == false && result.1 == nil)
            || (result.2 == false && result.3 == nil) {
            return .failed
        }
        return layoutPersistenceIsReadOnly || result.1 != nil || result.3 != nil ? .readOnly : .saved
    }

    func presentPersistenceWarningIfNeeded() {
        guard isPersistenceWarningPresented == false,
              persistenceWarnings.isEmpty == false,
              let window, window.isVisible,
              window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Terminal state needs attention"
        alert.informativeText = persistenceWarnings.joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        isPersistenceWarningPresented = true
        alert.beginSheetModal(for: window) { [weak self] _ in
            self?.isPersistenceWarningPresented = false
        }
    }

    private func recordPersistenceWarning(_ message: String) {
        guard persistenceWarnings.contains(message) == false else { return }
        persistenceWarnings.append(message)
        presentPersistenceWarningIfNeeded()
    }

    /// An alert (close confirmation or quit) took the keyboard; put it back in
    /// the pane the user was using.
    func restoreFocusAfterAlert() {
        guard workspaces.indices.contains(selected) else { return }
        let workspace = workspaces[selected]
        focusPane(workspace.visibleZoomedPane ?? workspace.focusedPane)
    }

    private func scheduleWindowFrameSave() {
        windowFrameRevision &+= 1
        windowFrameTimer?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.saveWindowFrameSoon(revision: self.windowFrameRevision)
        }
        RunLoop.main.add(timer, forMode: .common)
        windowFrameTimer = timer
    }

    private func saveWindowFrameSoon(revision: UInt64) {
        windowFrameTimer?.invalidate()
        windowFrameTimer = nil
        guard let window else { return }
        let state = windowState(for: window.frame)
        persistenceQueue.async { [weak self] in
            guard let self else { return }
            let saved = self.windowStateStore.save(state)
            let futureVersion = self.windowStateStore.futureVersionOnDisk
            DispatchQueue.main.async { [weak self] in
                guard let self, revision == self.windowFrameRevision else { return }
                if let futureVersion {
                    self.recordPersistenceWarning("The saved Terminal window state uses format version \(futureVersion). This version will leave it untouched.")
                } else if saved == false {
                    self.recordPersistenceWarning("MakiDesk Terminal could not save the window and sidebar sizes. Check available disk space and file permissions.")
                }
            }
        }
    }

    private func windowState(for frame: CGRect) -> TerminalWindowState {
        TerminalWindowState(frame: frame,
                            sidebarWidth: Double(splitView.currentSidebarWidth),
                            gitSidebarWidth: Double(gitSidebarStoredWidth),
                            gitSidebarVisible: gitSidebarVisible)
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
        disposeWorkspace(at: selected, terminateTmuxSessions: true)
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
        if hasTmux {
            let attachItem = NSMenuItem(title: "Attach Unattached tmux Session…",
                                        action: #selector(showUnattachedTmuxSessions(_:)),
                                        keyEquivalent: "")
            attachItem.target = self
            attachItem.representedObject = sender
            menu.addItem(attachItem)
        }

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

    @objc private func showUnattachedTmuxSessions(_ sender: NSMenuItem) {
        guard let button = sender.representedObject as? NSButton else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak button] in
            let result = TmuxSession.unattachedSessions()
            DispatchQueue.main.async {
                guard let self, let button else { return }
                let menu = NSMenu()
                switch result {
                case let .success(sessions) where sessions.isEmpty:
                    let empty = NSMenuItem(title: "No unattached tmux sessions",
                                           action: nil, keyEquivalent: "")
                    empty.isEnabled = false
                    menu.addItem(empty)
                case let .success(sessions):
                    for session in sessions {
                        let item = NSMenuItem(title: session.name,
                                              action: #selector(self.attachTmuxSession(_:)),
                                              keyEquivalent: "")
                        item.target = self
                        item.representedObject = session
                        menu.addItem(item)
                    }
                case let .failure(error):
                    let failed = NSMenuItem(
                        title: "Could not list tmux sessions: \(error.userMessage)",
                        action: nil,
                        keyEquivalent: ""
                    )
                    failed.isEnabled = false
                    menu.addItem(failed)
                }
                menu.popUp(positioning: nil,
                           at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
            }
        }
    }

    @objc private func attachTmuxSession(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? TmuxSession.UnattachedSession,
              let executable = TmuxSession.executableURL()?.path else { return }
        let id = UUID()
        var workspace = TerminalWorkspace(id: id, title: "tmux · \(session.name)")
        let escapedTarget = "'\(session.target.replacingOccurrences(of: "'", with: "'\\''"))'"
        workspace.setCommand("exec \(executable) attach-session -t \(escapedTarget)",
                             for: workspace.focusedPane)
        workspaces.append(workspace)
        selected = workspaces.count - 1
        reloadSidebar()
        rebuildContent()
        scheduleSave()
    }

    private func applyTmuxStatusPreference() {
        for workspace in workspaces {
            for pane in workspace.paneIDs {
                guard let command = workspace.command(for: pane),
                      let name = TmuxSession.target(in: command) else { continue }
                setTmuxStatusBarVisible(terminalSettings.showTmuxStatusBar,
                                        sessionName: name)
            }
        }
    }

    private func setTmuxStatusBarVisible(_ visible: Bool, sessionName: String) {
        TmuxSession.setStatusBarVisible(visible, sessionName: sessionName) { [weak self] result in
            guard case let .failure(error) = result else { return }
            self?.recordPersistenceWarning(
                "Could not update the tmux status bar: \(error.userMessage)."
            )
        }
    }

    @objc func newTmuxSessionAction(_ sender: Any?) {
        let id = UUID()
        let pane = PaneID()
        let name = TmuxSession.name(for: pane)
        var workspace = TerminalWorkspace(id: id, title: "tmux \(name.suffix(4))",
                                           firstPane: pane)
        workspace.setCommand(TmuxSession.command(
            sessionName: name,
            environment: ["MAKIDESK_TERMINAL": "1",
                          "MAKIDESK_WORKSPACE_ID": id.uuidString]
        ),
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
        workspace.setCommand(persistentPaneCommand(for: workspace.focusedPane,
                                                   workspaceID: workspace.id,
                                                   command: command),
                             for: workspace.focusedPane)
        workspaces.append(workspace)
        selected = workspaces.count - 1
        reloadSidebar()
        rebuildContent()
        scheduleSave()
    }

    /// Opens a new workspace running the container's shell. The Docker helper
    /// sends only a container reference and an allow-listed shell; the command
    /// is composed here, with quoting, and is persisted like an SSH session.
    func openDockerExec(containerID: String, shell: String, title: String?) {
        guard let command = DockerExecValidation.command(containerID: containerID,
                                                         shell: shell) else {
            NSSound.beep()
            return
        }
        var workspace = TerminalWorkspace(title: title ?? "Docker")
        workspace.setCommand(persistentPaneCommand(for: workspace.focusedPane,
                                                   workspaceID: workspace.id,
                                                   command: command),
                             for: workspace.focusedPane)
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
        workspace.setCommand(persistentPaneCommand(for: newPane,
                                                   workspaceID: workspace.id,
                                                   command: terminalSettings.shell),
                             for: newPane)
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

    @objc func moveFocusedPaneToNewWorkspaceAction(_ sender: Any?) {
        guard workspaces.indices.contains(selected) else { return }
        var source = workspaces[selected]
        guard source.paneCount > 1 else { NSSound.beep(); return }
        let pane = source.focusedPane
        let title = source.title
        let directory = source.directory(for: pane)
        let command = source.command(for: pane)
        guard source.remove(pane) else { return }
        workspaces[selected] = source
        var destination = TerminalWorkspace(title: title, firstPane: pane)
        destination.setDirectory(directory ?? "", for: pane)
        destination.setCommand(command, for: pane)
        workspaces.append(destination)
        selected = workspaces.count - 1
        reloadSidebar()
        rebuildContent()
        focusPane(pane)
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
        disposePane(pane, terminateTmuxSession: true,
                    command: workspace.command(for: pane))
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
            if let command = workspace.command(for: panes[0]),
               TmuxSession.isAttachCommand(command) {
                alert.messageText = "Close this terminal and end its tmux session?"
                alert.informativeText = "Processes running in this session will be stopped."
            } else {
                alert.messageText = "Close this terminal?"
                alert.informativeText = "A command is still running. Closing the terminal ends it."
            }
        } else {
            let persistentCount = panes.filter { pane in
                guard let command = workspace.command(for: pane) else { return false }
                return TmuxSession.isAttachCommand(command)
            }.count
            if persistentCount == panes.count {
                alert.messageText = "Close this workspace and end its tmux sessions?"
                alert.informativeText = "Processes running in these sessions will be stopped."
            } else {
                alert.messageText = "Close this workspace?"
                let summary = busy == 1
                    ? "A command is still running in one of its terminals."
                    : "Commands are still running in \(busy) of its \(panes.count) terminals."
                alert.informativeText = persistentCount > 0
                    ? summary + " Closing the workspace also ends its \(persistentCount) tmux session(s)."
                    : summary
            }
        }
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Close")
        alert.buttons.last?.hasDestructiveAction = true
        let confirmed = alert.runModal() == .alertSecondButtonReturn
        if confirmed == false {
            // The alert takes key focus; put the keyboard back in the pane the
            // user was working in instead of leaving it on the window.
            focusPane(workspace.visibleZoomedPane ?? workspace.focusedPane)
        }
        return confirmed
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
    @discardableResult
    func setAgentState(_ state: AgentState, forWorkspaceID id: UUID, label: String?) -> Bool {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return false }
        let changed = agentStates[id] != state
        if state == .done, index == selected, window?.isKeyWindow == true {
            agentStates[id] = nil
            agentLabels[id] = nil
            reloadSidebar()
            return changed
        }
        agentStates[id] = state
        agentLabels[id] = label
        reloadSidebar()
        return changed
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
        // Only the selected pane owns the tab/window title. Other split panes
        // may emit their own transient agent titles and must not fight it.
        guard workspaces[index].focusedPane == pane else { return }
        workspaces[index].title = trimmed
        reloadSidebar()
        if index == selected { window?.title = trimmed }
        scheduleSave()
    }

    func target(for view: TerminalSurfaceView) -> (workspaceID: UUID, paneID: PaneID)? {
        guard let pane = view.paneID,
              let workspace = workspaces.first(where: { $0.contains(pane) }) else { return nil }
        return (workspace.id, pane)
    }

    func focusTarget(workspaceID: UUID, paneID: PaneID?) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        if index != selected { selectWorkspace(at: index) }
        if let paneID, workspaces[selected].contains(paneID) { focusPane(paneID) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSettingsAction(_ sender: Any?) {
        TerminalAppDelegate.shared?.requestSettings()
    }

    @objc private func toggleGitSidebar(_ sender: Any?) {
        gitSidebarVisible.toggle()
        gitRefreshTimer?.invalidate()
        gitRefreshTimer = nil
        if gitSidebarVisible {
            gitRefreshLifecycle.setWindowVisible(window?.isVisible == true)
            startGitRefreshTimerIfNeeded()
        }
        if gitSidebarVisible { setGitSidebarExpanded(true) }
        else { setGitSidebarExpanded(false) }
        gitSidebarTitle.stringValue = "Git changes"
        scheduleWindowFrameSave()
        refreshGitSidebar()
    }

    private func setGitSidebarExpanded(_ expanded: Bool) {
        if expanded { clampGitSidebarWidth() }
        gitSidebar.isHidden = !expanded
        gitSidebarDivider.isHidden = !expanded
        gitSidebarWidth?.constant = expanded ? gitSidebarStoredWidth : 0
        if expanded {
            NSLayoutConstraint.activate(gitSidebarContentConstraints)
        } else {
            NSLayoutConstraint.deactivate(gitSidebarContentConstraints)
        }
        if let root = currentRootView {
            gitRootTrailingConstraint?.isActive = false
            let constraint = expanded
                ? root.trailingAnchor.constraint(equalTo: gitSidebarDivider.leadingAnchor)
                : root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
            gitRootTrailingConstraint = constraint
            constraint.isActive = true
        }
        contentView.layoutSubtreeIfNeeded()
    }

    private func resizeGitSidebar(by delta: CGFloat) {
        guard gitSidebarVisible, contentView.bounds.width > 0 else { return }
        let maximum = max(Self.minimumGitSidebarWidth,
                          contentView.bounds.width - Self.minimumTerminalContentWidth
                            - Self.gitSidebarDividerWidth)
        let wanted = min(max(gitSidebarStoredWidth - delta, Self.minimumGitSidebarWidth),
                         maximum)
        guard wanted != gitSidebarStoredWidth else { return }
        gitSidebarStoredWidth = wanted
        gitSidebarWidth?.constant = wanted
        scheduleWindowFrameSave()
    }

    private func clampGitSidebarWidth() {
        guard contentView.bounds.width > 0 else { return }
        let maximum = max(Self.minimumGitSidebarWidth,
                          contentView.bounds.width - Self.minimumTerminalContentWidth
                            - Self.gitSidebarDividerWidth)
        let wanted = min(max(gitSidebarStoredWidth, Self.minimumGitSidebarWidth), maximum)
        guard wanted != gitSidebarStoredWidth else { return }
        gitSidebarStoredWidth = wanted
        gitSidebarWidth?.constant = wanted
        scheduleWindowFrameSave()
    }

    private func showGitSidebarMessage(_ message: String) {
        gitTreeRoots = [GitSidebarNode(name: message)]
        gitOutlineView.reloadData()
        setGitSidebarExpanded(true)
    }

    private func refreshGitSidebar() {
        guard gitRefreshLifecycle.shouldRefresh, window?.isVisible == true,
              selected < workspaces.count else {
            gitTreeRoots = []
            gitOutlineView.reloadData()
            setGitSidebarExpanded(false)
            return
        }
        let generation = gitRefreshLifecycle.beginRequest()
        let workspace = workspaces[selected]
        let pane = workspace.focusedPane
        let savedDirectory = workspace.directory(for: pane)
        let tmuxTarget = workspace.command(for: pane).flatMap(TmuxSession.target(in:))
        guard savedDirectory != nil || tmuxTarget != nil else {
            showGitSidebarMessage("Waiting for terminal directory")
            return
        }
        guard gitRefreshInFlight == false else {
            gitRefreshPending = true
            return
        }
        gitRefreshInFlight = true
        if let savedDirectory {
            gitSidebarTitle.stringValue =
                "Git changes · \(URL(fileURLWithPath: savedDirectory).lastPathComponent)"
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let directory = tmuxTarget.flatMap {
                TmuxSession.currentPaneDirectory(target: $0)
            } ?? savedDirectory
            let result = directory.flatMap(GitStatusReader.read(directory:))
            let tree: [GitChangedFileTreeNode]
            if case let .success(_, files)? = result {
                tree = GitChangedFilesParser.tree(files)
            } else {
                tree = []
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.gitRefreshInFlight = false
                let refreshAgain = self.gitRefreshPending
                self.gitRefreshPending = false
                guard self.gitRefreshLifecycle.canPublish(generation),
                      self.gitSidebarVisible, self.selected < self.workspaces.count,
                      self.workspaces[self.selected].focusedPane == pane else {
                    if refreshAgain { self.refreshGitSidebar() }
                    return
                }
                guard directory != nil else {
                    self.showGitSidebarMessage("Waiting for terminal directory")
                    if refreshAgain { self.refreshGitSidebar() }
                    return
                }
                guard let result else {
                    self.showGitSidebarMessage("Git status unavailable")
                    if refreshAgain { self.refreshGitSidebar() }
                    return
                }
                switch result {
                case .notRepository:
                    self.showGitSidebarMessage("No Git repository in this directory")
                case let .success(root, _):
                    self.gitSidebarTitle.stringValue =
                        "Git changes · \(URL(fileURLWithPath: root).lastPathComponent)"
                    self.gitTreeRoots = Self.makeGitTree(tree)
                    if self.gitTreeRoots.isEmpty {
                        self.gitTreeRoots = [GitSidebarNode(name: "Working tree clean")]
                    }
                    self.gitOutlineView.reloadData()
                    self.gitOutlineView.expandItem(nil, expandChildren: true)
                    self.setGitSidebarExpanded(self.gitSidebarVisible)
                case let .failure(failure):
                    self.showGitSidebarMessage(Self.message(for: failure))
                }
                if refreshAgain { self.refreshGitSidebar() }
            }
        }
    }

    private func startGitRefreshTimerIfNeeded() {
        guard gitSidebarVisible, window?.isVisible == true, gitRefreshTimer == nil else { return }
        gitRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshGitSidebar()
        }
    }

    private func stopGitRefreshTimer() {
        gitRefreshTimer?.invalidate()
        gitRefreshTimer = nil
    }

    private static func message(for failure: GitStatusReadFailure) -> String {
        switch failure {
        case .directoryUnavailable: return "Git directory unavailable"
        case .commandFailed: return "Git status failed"
        case .outputTooLarge: return "Git status output is too large"
        case .couldNotStart: return "Git could not be started"
        }
    }

    private func setGitWindowVisible(_ visible: Bool) {
        gitRefreshLifecycle.setWindowVisible(visible)
        if visible {
            startGitRefreshTimerIfNeeded()
            refreshGitSidebar()
        } else {
            stopGitRefreshTimer()
            gitRefreshPending = false
        }
    }

    func hideMainWindow() {
        setGitWindowVisible(false)
        window?.orderOut(nil)
        updateRendererVisibility()
    }

    func updateDirectory(for view: TerminalSurfaceView, path: String) {
        guard let pane = view.paneID,
              let index = workspaces.firstIndex(where: { $0.contains(pane) }) else { return }
        workspaces[index].setDirectory(path, for: pane)
        scheduleSave()
        if index == selected, pane == workspaces[index].focusedPane { refreshGitSidebar() }
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
        panel.isExcludedFromWindowsMenu = true
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
        codexUsageStack.layer?.backgroundColor = uiTheme.surfaceSelected.cgColor
        codexUsageHeader.textColor = uiTheme.text
        codexUsageDetails.textColor = uiTheme.subtext
        codexUsageUpdated.textColor = uiTheme.subtext.withAlphaComponent(0.75)
        codexRefreshButton.contentTintColor = uiTheme.subtext
        contentView.layer?.backgroundColor = uiTheme.background.cgColor
        gitSidebar.layer?.backgroundColor = uiTheme.surface.cgColor
        gitSidebarTitle.textColor = uiTheme.text
        gitOutlineView.backgroundColor = uiTheme.surface
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
        applyTmuxStatusPreference()
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
        let rootTrailing = gitSidebar.isHidden
            ? root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
            : root.trailingAnchor.constraint(equalTo: gitSidebarDivider.leadingAnchor)
        gitRootTrailingConstraint?.isActive = false
        gitRootTrailingConstraint = rootTrailing
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rootTrailing,
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
        if selected < workspaces.count,
           let command = workspaces[selected].command(for: pane),
           let sessionName = TmuxSession.target(in: command) {
            setTmuxStatusBarVisible(terminalSettings.showTmuxStatusBar,
                                    sessionName: sessionName)
        }
        return host
    }

    private func disposePane(_ pane: PaneID,
                             terminateTmuxSession: Bool = false,
                             command: String? = nil) {
        if terminateTmuxSession, let command {
            TmuxSession.terminate(command: command)
        }
        guard let host = paneViews.removeValue(forKey: pane) else { return }
        if activeSearch?.view === host.surfaceView {
            closeSearch(restoreFocus: false)
        }
        host.surfaceView.detach()
        host.removeFromSuperview()
    }

    private func disposeWorkspace(at index: Int,
                                  terminateTmuxSessions: Bool = false) {
        guard index < workspaces.count else { return }
        let workspace = workspaces[index]
        for pane in workspace.paneIDs {
            disposePane(pane, terminateTmuxSession: terminateTmuxSessions,
                        command: workspace.command(for: pane))
        }
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
        hideMainWindow()
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        setGitWindowVisible(window?.isVisible == true)
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
        if gitSidebar.isHidden == false { clampGitSidebarWidth() }
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
        updateCodexUsageLifecycle(isVisible: mainVisible && NSApp.isHidden == false)
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

    private func updateCodexUsageLifecycle(isVisible: Bool) {
        let becameVisible = codexUsageLifecycle.setVisible(isVisible)
        if isVisible {
            if codexUsageTimer == nil {
                codexUsageTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
                    self?.refreshCodexUsage()
                }
            }
            if becameVisible { refreshCodexUsage() }
        } else {
            codexUsageTimer?.invalidate()
            codexUsageTimer = nil
            codexUsageReader.cancel()
            renderCodexUsage()
        }
    }

    @objc private func refreshCodexUsageAction(_ sender: Any?) {
        refreshCodexUsage()
    }

    private func refreshCodexUsage() {
        guard window?.isVisible == true,
              let generation = codexUsageLifecycle.beginRefresh() else { return }
        codexUsageError = nil
        codexRefreshButton.isEnabled = false
        codexUsageUpdated.stringValue = "Refreshing…"
        codexUsageReader.refresh { [weak self] result in
            guard let self,
                  self.codexUsageLifecycle.finishRefresh(generation: generation),
                  self.window?.isVisible == true else { return }
            self.codexRefreshButton.isEnabled = true
            switch result {
            case .success(let usage):
                self.codexUsage = usage
                self.codexUsageError = nil
            case .failure(let error):
                self.codexUsageError = error.localizedDescription
            }
            self.renderCodexUsage()
        }
    }

    private func renderCodexUsage() {
        var lines: [String] = []
        if let usage = codexUsage {
            lines.append(contentsOf: usage.windows.map { window in
                let remaining = window.resetsAt.map { " · resets \(Self.shortDateTime($0))" } ?? ""
                return "\(window.label): \(window.usedPercent)% used\(remaining)"
            })
            if let tokens = usage.lifetimeTokens {
                lines.append("Lifetime tokens: \(Self.grouped(tokens))")
            }
            if let tokens = usage.peakDailyTokens {
                lines.append("Peak day: \(Self.grouped(tokens)) tokens")
            }
            if let credits = usage.resetCredits {
                lines.append("Reset credits: \(credits)")
            }
            lines.append(contentsOf: usage.creditSummaries)
            if lines.isEmpty { lines.append("No quota or usage metrics provided") }
            codexUsageUpdated.stringValue = codexUsageError == nil
                ? "Updated \(Self.shortDateTime(usage.updatedAt))"
                : "Stale · last updated \(Self.shortDateTime(usage.updatedAt))"
        } else {
            lines.append("Usage is not available yet")
            codexUsageUpdated.stringValue = "Not updated"
        }
        if let codexUsageError {
            lines.append("Update failed: \(codexUsageError)")
        }
        codexUsageDetails.stringValue = lines.joined(separator: "\n")
    }

    private static func shortDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func grouped(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
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
        refreshGitSidebar()
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

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? GitSidebarNode)?.children.count ?? gitTreeRoots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? GitSidebarNode)?.children[index] ?? gitTreeRoots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? GitSidebarNode)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? GitSidebarNode else { return nil }
        let cell = NSTextField(labelWithString: node.status.map { "\(node.name)  \($0)" } ?? node.name)
        cell.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        cell.lineBreakMode = .byTruncatingMiddle
        cell.textColor = node.status.map { gitChangeColor(for: $0) } ?? uiTheme.subtext
        cell.toolTip = node.name
        return cell
    }

    private func gitChangeColor(for status: String) -> NSColor {
        switch GitChangedFileChangeKind(status: status) {
        case .deleted: return .systemRed
        case .modified: return .systemYellow
        case .added: return .systemGreen
        case .other: return uiTheme.text
        }
    }

    private static func makeGitTree(_ tree: [GitChangedFileTreeNode]) -> [GitSidebarNode] {
        tree.map { node in
            let result = GitSidebarNode(name: node.name,
                                        status: node.status,
                                        isDirectory: node.isDirectory)
            result.children = makeGitTree(node.children)
            return result
        }
    }

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
        let isTmux = workspace.paneIDs.contains { pane in
            workspace.command(for: pane).map(TmuxSession.isAttachCommand) ?? false
        }
        cell.transportLabel.stringValue = isTmux ? "MUX" : "SH"
        cell.transportLabel.textColor = isTmux ? uiTheme.accent : uiTheme.subtext
        cell.transportLabel.isHidden = false
        cell.transportLabel.toolTip = isTmux ? "tmux-backed terminal" : "Shell terminal"
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
        if workspaces.indices.contains(selected),
           let state = agentStates[workspaces[selected].id] {
            let label = agentLabels[workspaces[selected].id]
            let stateText: String
            switch state {
            case .working: stateText = "Codex / Agent working"
            case .waiting: stateText = "Codex / Agent waiting"
            case .done: stateText = "Codex / Agent finished"
            }
            agentStatusLabel.stringValue = [stateText, label].compactMap { $0 }.joined(separator: " · ")
        } else {
            agentStatusLabel.stringValue = "No active agent"
        }
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
        guard isBuilding == false,
              let split = notification.object as? WorkspaceSplitView,
              split.subviews.count >= 2,
              split.isApplyingStoredRatio == false,
              selected < workspaces.count else { return }
        let total = split.isVertical ? split.bounds.width : split.bounds.height
        let available = total - split.dividerThickness
        guard available > 0 else { return }
        let first = split.isVertical ? split.subviews[0].frame.width
                                     : split.subviews[0].frame.height
        if workspaces[selected].setRatio(Double(first / available), at: split.path) {
            scheduleSave()
        }
    }

    func ratio(at path: [Int]) -> Double {
        guard selected < workspaces.count,
              case let .split(_, ratio, _, _) = workspaces[selected].node(at: path) else {
            return 0.5
        }
        return ratio
    }
}
