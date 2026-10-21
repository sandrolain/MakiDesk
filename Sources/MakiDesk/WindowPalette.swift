import AppKit
import SwiftUI
import Observation

enum PaletteMode { case browse, search }

/// How the palette panel is laid out (T13).
enum PaletteLayout: Equatable {
    /// Fixed-size cards in a panel centred on the screen.
    case compact
    /// Cards scaled to fill the screen's visible frame (menu bar / Dock kept).
    case fullScreen
}

/// Everything about the panel's geometry, computed from the layout mode so the
/// sizing code has a single source of truth (T13).
struct PaletteMetrics {
    let layout: PaletteLayout
    let columns: Int
    let rows: Int
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    /// The preview box. Its width/height ratio is always the screen's own
    /// ratio, so a box is never an over-wide or over-tall ribbon (T15).
    let thumbnailWidth: CGFloat
    let thumbnailHeight: CGFloat
    let spacing: CGFloat
    let padding: CGFloat
    /// Room for the search field and the footer, whichever apply.
    let chrome: CGFloat
    let fontSize: CGFloat
    let iconSize: CGFloat
    let badgeSize: CGFloat
    let badgeSymbolSize: CGFloat
    /// Size of the whole panel, already including padding and chrome.
    let panelSize: CGSize
    /// Width reserved for the groups side column (G3), already part of
    /// `panelSize`; zero when the column is hidden.
    let groupColumnWidth: CGFloat

    /// Corner radius of the panel's background, following the card scale.
    var panelCornerRadius: CGFloat { layout == .fullScreen ? 28 : 20 }

    /// Width of the grid of cards, without the panel padding.
    var gridWidth: CGFloat {
        CGFloat(columns) * cardWidth + CGFloat(max(0, columns - 1)) * spacing
    }

    /// Height of the grid of cards, without the panel padding and chrome.
    var gridHeight: CGFloat {
        CGFloat(rows) * cardHeight + CGFloat(max(0, rows - 1)) * spacing
    }

    /// Height left to the scrolling grid: the panel minus the search field /
    /// footer chrome. Full screen fills it, so a short grid can be centred.
    var gridAreaHeight: CGFloat { max(0, panelSize.height - chrome) }
}

/// The layout actions offered in the palette footer (T14), plus Focus (T17):
/// bring the ticked windows into use and put the rest away.
enum PaletteLayoutCommand { case tile, goldenSpiral, auto, content, focus }

/// Pure geometry for the palette panel: same inputs, same layout, so the
/// sizing can be tested without a screen (T13).
enum PaletteLayoutEngine {
    /// The automatic column count for a given number of windows (2–4).
    static func automaticColumns(for itemCount: Int) -> Int {
        switch itemCount {
        case 0...4: return 2
        case 5...9: return 3
        default: return 4
        }
    }

    /// The columns actually used: the configured count (0 = automatic), never
    /// more than the windows available and never more than `maximum`.
    static func columns(configured: Int, itemCount: Int, maximum: Int = 8) -> Int {
        let wanted = configured > 0 ? configured : automaticColumns(for: itemCount)
        return max(1, min(wanted, max(1, min(itemCount, maximum))))
    }

    /// Metrics for `itemCount` cards in the given layout. `available` is the
    /// screen's visible frame size (menu bar and Dock already excluded),
    /// `columns` is the configured grid width (0 = automatic),
    /// `maxCardWidth` is the largest a card may get, in points, and
    /// `groupColumnWidth` reserves room for the groups side column (G3).
    ///
    /// One palette, one set of elements: the search field and the footer are
    /// always there, so the chrome they need is constant and the geometry does
    /// not depend on whether the palette is filtering or cycling.
    static func metrics(itemCount: Int, layout: PaletteLayout,
                        columns: Int, maxCardWidth: CGFloat,
                        available: CGSize, groupColumnWidth: CGFloat = 0) -> PaletteMetrics {
        // The screen's own proportions drive the shape of every preview box, so
        // a box is never an over-wide or over-tall ribbon (T15).
        let aspect = max(0.5, available.width / max(1, available.height))
        switch layout {
        case .compact:
            return compactMetrics(itemCount: itemCount,
                                  columns: columns, maxCardWidth: maxCardWidth,
                                  available: available, aspect: aspect,
                                  groupColumnWidth: groupColumnWidth)
        case .fullScreen:
            return fullScreenMetrics(itemCount: itemCount,
                                     columns: columns, maxCardWidth: maxCardWidth,
                                     available: available, aspect: aspect,
                                     groupColumnWidth: groupColumnWidth)
        }
    }

    /// Width of the groups side column (G3): room for the number, an optional
    /// name, the member count and the row's three commands.
    static let groupColumnWidth: CGFloat = 196

    /// Height taken by the two text lines and the spacing between them, for a
    /// given font size. Kept here so the card and the grid maths agree.
    static func textBlockHeight(fontSize: CGFloat) -> CGFloat {
        fontSize * 2.22 + 8 * (fontSize / 12)
    }

    /// The default panel. Preview boxes keep the screen's proportions (T15).
    private static func compactMetrics(itemCount: Int,
                                       columns configuredColumns: Int,
                                       maxCardWidth: CGFloat,
                                       available: CGSize,
                                       aspect: CGFloat,
                                       groupColumnWidth: CGFloat) -> PaletteMetrics {
        let columns = PaletteLayoutEngine.columns(configured: configuredColumns, itemCount: itemCount)
        let rows = max(1, Int(ceil(Double(max(1, itemCount)) / Double(columns))))
        // Room for the search field (about 68 pt) and the footer (about 38 pt).
        let chrome: CGFloat = 120
        let spacing: CGFloat = 16
        let padding: CGFloat = 20
        let fontSize: CGFloat = 12
        let cardPadding: CGFloat = 10
        let maxPanelWidth = min(1400, max(available.width, 600))
        let maxPanelHeight = min(900, max(available.height, 400))

        // The wanted size, shrunk only as far as needed to make the configured
        // columns fit the screen's width (T15); the groups column takes its
        // width off the cards, never off the screen edge.
        let fitCardWidth = (maxPanelWidth - groupColumnWidth - 2 * padding - CGFloat(columns - 1) * spacing)
            / CGFloat(columns)
        let cardWidth = max(80, min(maxCardWidth, fitCardWidth))

        let thumbnailWidth = max(60, cardWidth - 2 * cardPadding)
        let thumbnailHeight = thumbnailWidth / aspect
        let cardHeight = thumbnailHeight + 2 * cardPadding + textBlockHeight(fontSize: fontSize)

        let width = CGFloat(columns) * cardWidth + 2 * padding + CGFloat(columns - 1) * spacing
            + groupColumnWidth
        let height = min(CGFloat(rows) * cardHeight + 2 * padding + CGFloat(rows - 1) * spacing + chrome,
                         maxPanelHeight)
        return PaletteMetrics(
            layout: .compact, columns: columns, rows: rows,
            cardWidth: cardWidth, cardHeight: cardHeight,
            thumbnailWidth: thumbnailWidth, thumbnailHeight: thumbnailHeight,
            spacing: spacing, padding: padding, chrome: chrome,
            fontSize: fontSize, iconSize: 30, badgeSize: 22,
            badgeSymbolSize: 11,
            panelSize: CGSize(width: width, height: height),
            groupColumnWidth: groupColumnWidth
        )
    }

    /// Cards scaled to fill the visible frame. The **columns are the same as the
    /// normal mode** and only the size changes, up to `maxCardWidth`. Each
    /// preview box keeps the screen's proportions and is made as large as its
    /// cell allows, so the grid fits without scrolling unless the boxes would
    /// otherwise be too small (T15).
    private static func fullScreenMetrics(itemCount: Int,
                                          columns configuredColumns: Int,
                                          maxCardWidth: CGFloat,
                                          available: CGSize,
                                          aspect: CGFloat,
                                          groupColumnWidth: CGFloat) -> PaletteMetrics {
        let padding: CGFloat = 40
        let spacing: CGFloat = 24
        // Room for the search field and the footer, which grow with the font.
        let chrome: CGFloat = 170
        /// Below this a box would be a stamp, so the grid is allowed to scroll.
        let minimumThumbnailHeight: CGFloat = 90
        let count = max(1, itemCount)
        let columns = PaletteLayoutEngine.columns(configured: configuredColumns, itemCount: itemCount)
        let rows = (count + columns - 1) / columns

        let cellWidth = (available.width - groupColumnWidth - 2 * padding - CGFloat(columns - 1) * spacing)
            / CGFloat(columns)
        let cellHeight = (available.height - chrome - 2 * padding - CGFloat(rows - 1) * spacing) / CGFloat(rows)

        // A gentle font grow: the box, not the text, takes most of the extra
        // room, so enlarging the layout grows the previews first.
        let fontSize = min(20, max(13, 10 + cellWidth / 120))
        let cardPadding = 10 * (fontSize / 12)
        let text = textBlockHeight(fontSize: fontSize)

        // Never wider than the user's maximum, never wider than the cell.
        let innerWidth = max(80, min(cellWidth, maxCardWidth) - 2 * cardPadding)
        let innerHeight = max(minimumThumbnailHeight, cellHeight - 2 * cardPadding - text)
        let thumbnailWidth = max(80, min(innerWidth, innerHeight * aspect))
        let thumbnailHeight = thumbnailWidth / aspect
        let cardWidth = thumbnailWidth + 2 * cardPadding
        let cardHeight = thumbnailHeight + 2 * cardPadding + text

        return PaletteMetrics(
            layout: .fullScreen, columns: columns, rows: rows,
            cardWidth: cardWidth, cardHeight: cardHeight,
            thumbnailWidth: thumbnailWidth, thumbnailHeight: thumbnailHeight,
            spacing: spacing, padding: padding, chrome: chrome,
            fontSize: fontSize, iconSize: 30 * (fontSize / 12),
            badgeSize: 22 * (fontSize / 12), badgeSymbolSize: 11 * (fontSize / 12),
            panelSize: CGSize(width: max(600, available.width), height: max(400, available.height)),
            groupColumnWidth: groupColumnWidth
        )
    }
}

/// One row of the palette's groups column (G3): enough to show the number, an
/// optional name, the saved member count and the global shortcut, and to drive
/// the group's recall/reset.
struct PaletteGroupRow: Identifiable, Equatable {
    let slot: Int
    let name: String?
    /// Saved members, whether or not they are on screen right now.
    let memberCount: Int
    /// Whether this group is the one on screen right now: its scene is the one
    /// that cleared the desktop (T15).
    var isOnScreen: Bool = false

    var id: Int { slot }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return "Group \(slot)"
    }
}

/// Shared state of the window palette.
@Observable
final class PaletteModel {
    var items: [ActionableWindow] = []
    var previews: [String: NSImage] = [:]
    var query = ""
    var selection = 0
    var mode: PaletteMode = .browse
    var theme: PaletteTheme = PaletteTheme.all[0]
    var animationsEnabled = true
    var animationDuration = 0.22
    var showPreview = true
    var columns = 3
    var opacity: Double = 0.9
    /// Whether cards carry the per-app tint (T12).
    var tintedCards = true
    /// Panel geometry; drives the whole view (T13).
    var metrics = PaletteMetrics(layout: .compact, columns: 3, rows: 2, cardWidth: 250,
                                 cardHeight: 196, thumbnailWidth: 230, thumbnailHeight: 144,
                                 spacing: 16, padding: 20, chrome: 100, fontSize: 12,
                                 iconSize: 30, badgeSize: 22, badgeSymbolSize: 11,
                                 panelSize: CGSize(width: 560, height: 560),
                                 groupColumnWidth: 0)
    /// Ticked cards. The ticks are the group being edited: they are empty
    /// outside group editing and follow the group's live members inside it.
    var selectedIDs: Set<String> = []
    /// Bumped when the search field should take focus (Opt+Space only).
    var focusToken = 0
    /// The nine groups, as the side column shows them (G3).
    var groupRows: [PaletteGroupRow] = []
    /// The group currently being edited from the column. While it is set the
    /// ticked cards *are* the group's members.
    var selectedGroupSlot: Int?
    /// A group whose Reset is waiting for its second, confirming press (G3).
    var groupPendingReset: Int?
    /// Group numbers each visible window belongs to, keyed by window id: the
    /// badges drawn on the thumbnails.
    var groupBadges: [String: [Int]] = [:]
    var isLoadingWindows = false

    var filtered: [ActionableWindow] {
        guard !query.isEmpty else { return items }
        let needle = query.lowercased()
        return items.filter {
            $0.title.lowercased().contains(needle) || $0.appName.lowercased().contains(needle)
        }
    }
}

/// One palette for both Opt+Tab (browse) and Opt+Space (search): a grid of live
/// previews, navigable with the keyboard or the mouse. The filter field only
/// exists in search mode — with Opt+Tab the user holds Option to keep cycling,
/// so a text field would be meaningless (E1).
final class WindowPalette {
    static let shared = WindowPalette()

    private var panel: PalettePanel?
    private var hosting: NSHostingView<PaletteView>?
    private var monitor: Any?
    /// Re-captures the thumbnails at a steady pace while the palette is open.
    private var refreshTimer: Timer?
    /// Set after ⌥Q/⌥M so releasing Option does not then activate (and, for a
    /// just-minimised window, immediately un-minimise) the selection.
    private var suppressReleaseActivation = false
    private var pendingReleaseActivation = false
    private var loadGeneration = 0
    private var previewGeneration = 0
    /// Keep the opening display across key presses and async inventory updates.
    private var presentationDisplayID: CGDirectDisplayID?
    private var originWindowID: String?
    private var openedBackwards = false
    private var pendingBrowseSteps = 0
    private var previewCosts: [String: Int] = [:]
    private var previewDimensions: [String: CGFloat] = [:]
    private static let previewByteLimit = 32 * 1024 * 1024
    private var visiblePreviewIDs = Set<String>()
    private var pendingPreviewLoad: DispatchWorkItem?
    @ObservationIgnored private weak var store: WorkspaceStore?
    let model = PaletteModel()

    /// Where the pointer was when hover last counted — or when the keyboard last
    /// moved the selection. A card may take the selection from the pointer only
    /// if the pointer actually moved since then (T28).
    private var hoverAnchor: CGPoint = .zero

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Pushes the current store settings into the open palette (theme, tint,
    /// layout mode) without re-scanning the windows; used by Settings so a
    /// change is visible immediately.
    func applySettings(from store: WorkspaceStore) {
        model.theme = store.theme
        model.animationsEnabled = store.effectiveAnimationsEnabled
        model.animationDuration = store.animationDuration
        model.showPreview = store.showPreview
        model.opacity = store.paletteOpacity
        model.tintedCards = store.paletteTintedCards
        guard isVisible, let panel else { return }
        updateLayout(in: panel, store: store, rescan: true)
    }

    func show(store: WorkspaceStore, mode: PaletteMode, backwards: Bool = false) {
        self.store = store
        model.theme = store.theme
        model.animationsEnabled = store.effectiveAnimationsEnabled
        model.animationDuration = store.animationDuration
        model.showPreview = store.showPreview
        model.opacity = store.paletteOpacity
        model.tintedCards = store.paletteTintedCards
        suppressReleaseActivation = false
        pendingReleaseActivation = false

        let wasVisible = isVisible
        if !wasVisible {
            selectPresentationScreen(store.paletteScreenLocation)
            originWindowID = store.mostRecentFocusedWindowID
            openedBackwards = backwards
            pendingBrowseSteps = 0
        }
        let previousMode = model.mode
        let previousID = model.selection < model.filtered.count ? model.filtered[model.selection].id : nil
        // Opening under a still cursor must not move the selection (T28).
        hoverAnchor = NSEvent.mouseLocation

        // Cycling with ⌥Tab re-enters `show` on every key press. Only a new open
        // or mode change requests a refresh; the latest published snapshot is
        // shown immediately while the refresh runs off the event path.
        let needsRefresh = !wasVisible || previousMode != mode
        if needsRefresh {
            let ordered = store.orderedWindowsForPalette(store.cachedActionableWindows())
            model.items = wasVisible ? orderedForSession(ordered) : ordered
            model.isLoadingWindows = true
        }
        if model.items.isEmpty && !needsRefresh && !model.isLoadingWindows { hide(); return }
        pruneSelection()

        // The column is shown in both modes, so a group being edited stays
        // selected and ticked between them; the badges always follow the
        // current window list.
        refreshGroupState()
        if model.selectedGroupSlot != nil { syncGroupTicks() }

        model.mode = mode
        if mode == .browse || !wasVisible { model.query = "" }

        if !wasVisible {
            model.selection = mode == .browse ? initialBrowseSelection() : 0
        } else if previousMode != mode {
            model.selection = 0
        } else {
            if let previousID, let index = model.filtered.firstIndex(where: { $0.id == previousID }) {
                model.selection = index
            } else {
                model.selection = min(model.selection, model.filtered.count - 1)
            }
            move(backwards ? -1 : 1)
        }

        model.selection = min(max(model.selection, 0), max(0, model.filtered.count - 1))

        if mode == .search { model.focusToken += 1 }

        let panel = self.panel ?? makePanel(size: .zero)
        self.panel = panel
        // Compute the geometry first so previews are captured at the right
        // resolution for the layout about to be shown (full screen captures
        // larger images).
        updateLayout(in: panel, store: store, rescan: false)
        loadPreviews(for: model.items, refresh: !wasVisible)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        // Nothing holds the keyboard in browse mode: the panel is key now, and
        // AppKit would otherwise hand the focus to the search field (T29).
        if mode == .browse { panel.makeFirstResponder(nil) }
        installMonitor()
        startRefreshTimer()
        highlightSelection()
        if needsRefresh {
            loadGeneration += 1
            let generation = loadGeneration
            WindowIndex.shared.refreshAsync { [weak self, weak store] _ in
                guard let self, let store, self.isVisible, self.loadGeneration == generation else { return }
                let previousID = self.selectedWindow()?.id
                let wasWaitingForRelease = self.pendingReleaseActivation
                let refreshed = self.orderedForSession(
                    store.orderedWindowsForPalette(store.cachedActionableWindows()))
                self.model.items = refreshed
                self.model.isLoadingWindows = false
                guard !refreshed.isEmpty else { self.hide(); return }
                self.pruneSelection()
                if let previousID, let index = self.model.filtered.firstIndex(where: { $0.id == previousID }) {
                    self.model.selection = index
                } else {
                    self.model.selection = self.model.mode == .browse ? self.initialBrowseSelection() : 0
                }
                self.refreshGroupState()
                self.updateLayout(in: panel, store: store, rescan: false)
                self.loadPreviews(for: refreshed, refresh: false)
                self.highlightSelection()
                if wasWaitingForRelease {
                    self.pendingReleaseActivation = false
                    self.activateSelection()
                }
            }
        }
    }

    /// Recomputes the panel geometry for the current layout mode, resizes the
    /// panel (full screen: exactly the visible frame) and re-centres it.
    private func updateLayout(in panel: NSWindow, store: WorkspaceStore, rescan: Bool) {
        let layout: PaletteLayout = store.paletteFullScreen ? .fullScreen : .compact
        let screen = presentationScreen
        let available = screen?.visibleFrame.size
            ?? CGSize(width: 1440, height: 900)
        // The column is shown in both modes, so it always takes its width off
        // the grid area; the search field and the footer are always there too,
        // so the chrome is the same whichever mode the palette is in.
        let groupColumnWidth = PaletteLayoutEngine.groupColumnWidth
        let metrics = PaletteLayoutEngine.metrics(
            itemCount: model.items.count,
            layout: layout,
            columns: store.paletteColumns,
            maxCardWidth: CGFloat(store.paletteMaxCardWidth),
            available: available,
            groupColumnWidth: groupColumnWidth
        )
        model.metrics = metrics
        model.columns = metrics.columns

        if layout == .fullScreen {
            panel.hasShadow = false
        } else {
            panel.hasShadow = true
        }
        panel.setContentSize(metrics.panelSize)
        hosting?.frame = CGRect(origin: .zero, size: metrics.panelSize)
        if hosting == nil {
            let hosting = NSHostingView(rootView: PaletteView(
                model: model,
                onActivate: { [weak self] id in self?.activate(id) },
                onClose: { [weak self] in self?.hide() },
                onLayoutCommand: { [weak self] command in self?.applyLayout(command) },
                onFocusSearch: { [weak self] in self?.enterSearch() },
                onSelectGroup: { [weak self] slot in self?.selectGroup(slot) },
                onRecallGroup: { [weak self] slot in self?.recallGroupFromColumn(slot) },
                onResetGroup: { [weak self] slot in self?.requestGroupReset(slot) },
                onToggleGroupMember: { [weak self] id in self?.toggleGroupMember(id) },
                onHoverCard: { [weak self] index in self?.pointerHovered(index) },
                onCardVisibility: { [weak self] id, visible in self?.cardVisibilityChanged(id, visible: visible) }
            ))
            hosting.frame = CGRect(origin: .zero, size: metrics.panelSize)
            panel.contentView = hosting
            self.hosting = hosting
        }
        place(panel, store: store, layout: layout, screen: screen)
        if rescan { loadPreviews(for: model.items, refresh: true) }
    }

    func hide() {
        loadGeneration += 1
        previewGeneration += 1
        pendingReleaseActivation = false
        model.isLoadingWindows = false
        // Leaving the palette ends the group-editing mode: the ticks belong to
        // the group, so the next open starts with none.
        deselectGroup()
        model.groupPendingReset = nil
        removeMonitor()
        stopRefreshTimer()
        model.query = ""
        panel?.orderOut(nil)
        MainActor.assumeIsolated { WindowCapture.cancelPaletteCapture() }
        model.previews.removeAll()
        previewCosts.removeAll()
        previewDimensions.removeAll()
        visiblePreviewIDs.removeAll()
        pendingPreviewLoad?.cancel()
        pendingPreviewLoad = nil
    }

    /// Handles the ⌥Space hot key when the palette is already open. Carbon
    /// consumes that combination system-wide, so the palette's local monitor
    /// never sees the key event — and therefore never gets to run its own space
    /// key. In browse mode the press turns the open palette into a search: the
    /// field takes the focus and releasing ⌥ no longer picks a window. Already
    /// searching, it steps to the next result, as it always did.
    func handleSpaceHotKey() {
        guard isVisible else { return }
        guard let store else { return }
        guard model.mode == .browse else {
            show(store: store, mode: .search)
            return
        }
        enterSearch()
    }

    /// Moves the open palette into search mode: the field takes the focus, what
    /// is typed filters, and releasing ⌥ leaves the panel open instead of
    /// activating the highlighted window. Nothing is re-scanned — the list and
    /// the thumbnails are the ones already on screen.
    func enterSearch() {
        guard isVisible, model.mode != .search else { return }
        model.mode = .search
        model.query = ""
        model.selection = 0
        model.focusToken += 1
    }

    /// Loads previews asynchronously off the main thread, delivering each image
    /// as it is ready. No full-desktop scan, no main-thread block (B1).
    ///
    /// The last thumbnails are kept in memory: opening the palette shows them
    /// immediately and only replaces them as fresh captures arrive, so the grid
    /// never blinks empty. `refresh` re-captures every window (bypassing the
    /// capture cache) and is used when the palette opens and on the periodic
    /// timer; while cycling only the missing previews are requested.
    private func loadPreviews(for items: [ActionableWindow], refresh: Bool) {
        guard model.showPreview else {
            if !model.previews.isEmpty { model.previews = [:] }
            previewCosts.removeAll()
            previewDimensions.removeAll()
            MainActor.assumeIsolated { WindowCapture.cancelPaletteCapture() }
            return
        }
        // Drop previews of windows that no longer exist, keep the rest.
        let liveIDs = Set(items.map(\.id))
        model.previews = model.previews.filter { liveIDs.contains($0.key) }
        previewCosts = previewCosts.filter { liveIDs.contains($0.key) }
        previewDimensions = previewDimensions.filter { liveIDs.contains($0.key) }
        let maxDimension = previewMaxDimension
        let selectedID = selectedWindow()?.id
        // Selection first; other requests preserve the stable visual order.
        let eligible = visiblePreviewIDs.isEmpty ? Set(items.prefix(12).map(\.id)) : visiblePreviewIDs
        let prioritized = items.filter { eligible.contains($0.id) || $0.id == selectedID }
            .sorted { $0.id == selectedID && $1.id != selectedID }
        let requests = prioritized.compactMap { window -> WindowCapture.Request? in
            guard let id = window.windowID else { return nil }
            if !refresh, model.previews[window.id] != nil,
               previewDimensions[window.id] == maxDimension { return nil }
            return WindowCapture.Request(key: window.id, windowID: id)
        }
        guard !requests.isEmpty else { return }
        let generation = previewGeneration
        // Full-screen cards are much larger: capture at a higher resolution so
        // the same image is not upscaled into a big thumbnail.
        MainActor.assumeIsolated { [weak self] in
            guard let self, self.previewGeneration == generation else { return }
            WindowCapture.capture(requests, maxDimension: maxDimension, force: refresh) { [weak self] key, image in
                guard let self, self.isVisible, self.model.showPreview, self.previewGeneration == generation,
                      self.previewMaxDimension == maxDimension,
                      self.model.items.contains(where: { $0.id == key }) else { return }
                self.model.previews[key] = image
                self.previewDimensions[key] = maxDimension
                self.previewCosts[key] = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    .map { $0.bytesPerRow * $0.height } ?? 0
                self.trimPreviews(protecting: self.selectedWindow()?.id)
            }
        }
    }

    private var previewMaxDimension: CGFloat {
        let limit: CGFloat = model.metrics.layout == .fullScreen ? 1280 : 640
        return min(limit, max(160, (model.metrics.thumbnailWidth * (presentationScreen?.backingScaleFactor ?? 2)).rounded()))
    }

    private func cardVisibilityChanged(_ id: String, visible: Bool) {
        if visible { visiblePreviewIDs.insert(id) } else { visiblePreviewIDs.remove(id) }
        pendingPreviewLoad?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isVisible else { return }
            self.loadPreviews(for: self.model.items, refresh: false)
        }
        pendingPreviewLoad = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func trimPreviews(protecting selectedID: String?) {
        var bytes = previewCosts.values.reduce(0, +)
        for window in model.items.reversed() where bytes > Self.previewByteLimit && window.id != selectedID {
            bytes -= previewCosts.removeValue(forKey: window.id) ?? 0
            previewDimensions[window.id] = nil
            model.previews[window.id] = nil
        }
        if bytes > Self.previewByteLimit, let selectedID {
            model.previews[selectedID] = nil
            previewCosts[selectedID] = nil
            previewDimensions[selectedID] = nil
        }
    }

    /// Starts the periodic thumbnail refresh, once per visible session.
    private func startRefreshTimer() {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.loadPreviews(for: self.model.items, refresh: true)
            // The index is updated by AX notifications and resize commands.
            // Read its published snapshot only; never make the timer perform
            // a synchronous system-wide discovery while the panel is visible.
            self.refreshWindowSnapshot()
            // Keep the column and the badges live while the palette is open, so
            // a member added or removed with the global shortcuts (or a digit)
            // shows up here too.
            self.refreshGroupState()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func refreshWindowSnapshot() {
        guard let store else { return }
        let refreshed = orderedForSession(store.orderedWindowsForPalette(store.cachedActionableWindows()))
        let oldIDs = model.items.map(\.id)
        let newIDs = refreshed.map(\.id)
        let contentUnchanged = oldIDs == newIDs && zip(model.items, refreshed).allSatisfy { old, new in
            old.title == new.title && old.frame == new.frame && old.minimized == new.minimized
        }
        guard !contentUnchanged else { return }

        let selectedID = selectedWindow()?.id
        model.items = refreshed
        guard !refreshed.isEmpty else { hide(); return }
        pruneSelection()
        if let selectedID, let index = model.filtered.firstIndex(where: { $0.id == selectedID }) {
            model.selection = index
        } else {
            model.selection = min(model.selection, max(0, model.filtered.count - 1))
        }
        refreshGroupState()
        if model.selectedGroupSlot != nil { syncGroupTicks() }
        updateLayout(in: panel ?? makePanel(size: .zero), store: store, rescan: false)
        loadPreviews(for: refreshed, refresh: false)
        highlightSelection()
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// How often the thumbnails are re-captured while the palette is open.
    private static let refreshInterval: TimeInterval = 2

    private func move(_ delta: Int) {
        let count = model.filtered.count
        guard count > 0 else {
            if model.isLoadingWindows { pendingBrowseSteps += delta }
            return
        }
        model.selection = (model.selection + delta + count) % count
        suppressReleaseActivation = false
        // The keyboard owns the selection from now on: a pointer standing still
        // over a card is not a reason to take it back (T28).
        hoverAnchor = NSEvent.mouseLocation
        highlightSelection()
    }

    private func moveGrid(_ dx: Int, _ dy: Int) {
        let count = model.filtered.count
        guard count > 0 else { return }
        let columns = max(1, model.columns)
        var index = model.selection + dx + dy * columns
        if index < 0 { index = 0 }
        if index >= count { index = count - 1 }
        model.selection = index
        suppressReleaseActivation = false
        hoverAnchor = NSEvent.mouseLocation
        highlightSelection()
    }

    /// The pointer asks for the card under it — but only when it is actually
    /// being moved. While the arrow keys scroll the grid under a still cursor,
    /// SwiftUI reports the card that ends up beneath it as hovered; accepting
    /// that would snatch the selection back from the keyboard every time. A
    /// report from the same place as the last one is not a move, so it is
    /// ignored, and the card the keyboard chose stays chosen (T28).
    private func pointerHovered(_ index: Int) {
        let now = NSEvent.mouseLocation
        let moved = Self.pointerMoved(from: hoverAnchor, to: now)
        hoverAnchor = now
        guard moved, index != model.selection else { return }
        model.selection = index
    }

    /// Whether a pointer report is a real move: a point of jitter is not one.
    /// Pure, so the rule can be tested without a mouse (T28).
    static func pointerMoved(from anchor: CGPoint, to point: CGPoint) -> Bool {
        abs(point.x - anchor.x) > 1 || abs(point.y - anchor.y) > 1
    }

    /// Shows the whole layout on the overlay with the selection highlighted, so
    /// the user keeps the context of where each window sits (A15).
    private func highlightSelection() {
        guard WorkspaceStore.shared.showMiniMap else { return }
        let list = model.filtered
        guard model.selection < list.count else { return }
        let selected = list[model.selection]
        let mapped = model.items.map { window in
            WorkspaceWindow(title: window.title, appName: window.appName,
                            x: window.frame.minX, y: window.frame.minY,
                            width: window.frame.width, height: window.frame.height,
                            systemID: window.id)
        }
        let highlighted = Set(mapped.filter { $0.systemID == selected.id }.map(\.id))
        MiniMapController.shared.show(windows: mapped, highlightedIDs: highlighted)
    }

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }

    private func handle(_ event: NSEvent) -> Bool {
        if event.type == .flagsChanged {
            if model.mode == .browse, !event.modifierFlags.contains(.option) {
                if suppressReleaseActivation {
                    suppressReleaseActivation = false
                    return true
                }
                if model.isLoadingWindows {
                    if model.items.isEmpty {
                        pendingReleaseActivation = true
                    } else {
                        activateSelection()
                    }
                } else {
                    activateSelection()
                }
                return true
            }
            return false
        }
        switch event.keyCode {
        case 53:                                           // Esc: leave the group, then close
            // While browsing Esc first leaves the group being edited; while
            // searching it closes the palette, as it always did.
            if model.mode == .browse, model.selectedGroupSlot != nil {
                deselectGroup()
            } else {
                hide()
            }
            return true
        case 36, 76:                                       // Return / Enter
            // A selected group means "lay it out" while browsing; while
            // searching ↩ opens the highlighted result and ⌘↩ still recalls the
            // group being edited.
            if let slot = model.selectedGroupSlot,
               model.mode == .browse || event.modifierFlags.contains(.command) {
                recallGroupFromColumn(slot)
            } else {
                activateSelection()
            }
            return true
        case 51:                                           // Delete: reset the selected group
            guard model.mode == .browse, let slot = model.selectedGroupSlot else { return false }
            requestGroupReset(slot)
            return true
        case 123: moveGrid(-1, 0); return true             // Left
        case 124: moveGrid(1, 0); return true              // Right
        case 125: moveGrid(0, 1); return true              // Down
        case 126: moveGrid(0, -1); return true             // Up
        case 48: return true                               // Tab: cycling is the global ⌥⇥ hot key
        case 49:                                           // Space: the search field
            guard model.mode == .browse else { return false }
            enterSearch()
            return true
        default: break
        }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let digit = Self.groupSlot(for: event, characters: key)
        // ⌘1…⌘9 picks a group from the column. The column shows in both modes,
        // and the keys are only meaningful with ⌘, so this works while
        // searching too (it never steals a letter typed into the field).
        if event.modifierFlags.contains(.command), let digit {
            selectGroup(digit)
            return true
        }
        // The rest are matched by the character the key produces (so they follow
        // the active keyboard layout) and only in browse mode, where Option is
        // held; in search mode they belong to the filter field.
        guard model.mode == .browse else { return false }
        // ⌥1…⌥9 adds or removes the card under the highlight to/from that group:
        // the practical way to build a group, moving with Tab / the arrows.
        if let digit, let window = selectedWindow() {
            toggleGroupMember(window.id, slot: digit)
            return true
        }
        let isQ = key == "q" || (key.isEmpty && event.keyCode == 12)
        let isM = key == "m" || (key.isEmpty && event.keyCode == 46)
        guard isQ || isM else { return false }
        suppressReleaseActivation = true
        if isM {
            minimizeSelection()                            // ⌥M — minimise
        } else if event.modifierFlags.contains(.shift) {
            quitSelection()                                // ⌥⇧Q — quit app
        } else {
            closeSelection()                               // ⌥Q — close window
        }
        return true
    }

    private func selectedWindow() -> ActionableWindow? {
        let list = model.filtered
        guard model.selection < list.count else { return nil }
        return list[model.selection]
    }

    /// The group number (1…9) behind a key press, or nil. Read from the character
    /// the key produces, falling back to the physical number row because ⌥ turns
    /// digits into symbols on most layouts (⌥1 → “¡”).
    private static func groupSlot(for event: NSEvent, characters: String) -> Int? {
        if let slot = Int(characters), (1...9).contains(slot) { return slot }
        let row: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        guard let index = row.firstIndex(of: event.keyCode) else { return nil }
        return index + 1
    }

    // MARK: - Ticked cards and the layout commands

    /// Drops ids that no longer exist (after a close/quit or a re-scan).
    private func pruneSelection() {
        guard !model.selectedIDs.isEmpty else { return }
        let live = Set(model.items.map(\.id))
        model.selectedIDs.formIntersection(live)
    }

    /// Applies a layout command to the ticked windows — the members of the group
    /// being edited — or to all of them when no group is selected (nothing is
    /// ticked then). The palette closes and the ticks are cleared.
    private func applyLayout(_ command: PaletteLayoutCommand) {
        guard let store else { return }
        let selected = model.items.filter { model.selectedIDs.contains($0.id) }
        store.lastLayoutSelection = selected
        model.selectedIDs = []
        hide()
        switch command {
        case .tile:
            store.tileOnScreen(gap: store.gap, selection: selected)
        case .goldenSpiral:
            store.autoLayout(selection: selected)
        case .auto:
            store.suggestLayout(selection: selected)
        case .content:
            store.contentLayout(selection: selected)
        case .focus:
            store.focus(on: selected)
        }
    }

    // MARK: - Groups in the side column (G3)

    /// Rebuilds the nine rows from the store. Cheap (no window scan), so it runs
    /// on every refresh to keep the counts live.
    private func refreshGroupRows() {
        guard let store else { return }
        model.groupRows = (1...9).map { slot in
            let group = store.groups[slot]
            return PaletteGroupRow(slot: slot, name: group?.name, memberCount: group?.members.count ?? 0,
                                   isOnScreen: store.activeGroupSlot == slot)
        }
    }

    /// Aligns the ticks with the selected group, so the ticks *are* the group:
    /// one system, which is also what the column's count and the card badges
    /// are read from.
    private func syncGroupTicks() {
        guard let store, let slot = model.selectedGroupSlot else { return }
        model.selectedIDs = Set(store.groupMembers(of: slot, among: model.items).map(\.id))
    }

    /// Selects group `slot` for editing, or deselects it when it is already the
    /// selected one. Selecting sets the ticks to its members; the ticks exist
    /// only for the group being edited.
    private func selectGroup(_ slot: Int) {
        guard (1...9).contains(slot) else { return }
        if model.selectedGroupSlot == slot {
            deselectGroup()
            return
        }
        model.selectedGroupSlot = slot
        model.groupPendingReset = nil
        refreshGroupRows()
        syncGroupTicks()
    }

    /// Leaves group editing. The ticks belong to the group, so they go with it.
    private func deselectGroup() {
        guard model.selectedGroupSlot != nil else { return }
        model.selectedGroupSlot = nil
        model.groupPendingReset = nil
        model.selectedIDs = []
    }

    /// Adds or removes the window behind card `id` to/from group `slot`, and
    /// persists it. The store shows the HUD. The group is not selected in the
    /// column: ⌥1…⌥9 edits membership while you keep browsing.
    private func toggleGroupMember(_ id: String, slot: Int) {
        guard let store, let window = model.items.first(where: { $0.id == id }) else { return }
        store.toggleMembership(of: window, in: slot)
        refreshGroupState()
    }

    /// Adds or removes the card from the group currently being edited.
    private func toggleGroupMember(_ id: String) {
        guard let slot = model.selectedGroupSlot else { return }
        toggleGroupMember(id, slot: slot)
    }

    /// Recalls a group and closes the palette, like pressing its global
    /// shortcut but with the palette's own list of windows.
    private func recallGroupFromColumn(_ slot: Int) {
        guard let store else { return }
        hide()
        store.recallGroup(slot: slot)
    }

    /// Reset is destructive but trivially undone (members are re-added), so the
    /// confirmation lives in the row: the first press arms it, the second
    /// clears. No modal inside a non-activating panel.
    private func requestGroupReset(_ slot: Int) {
        guard let store else { return }
        if model.groupPendingReset == slot {
            model.groupPendingReset = nil
            store.clearGroup(slot: slot)
            refreshGroupState()
        } else {
            model.groupPendingReset = slot
        }
    }

    /// Keeps the column and the badges live: the counts and the group numbers on
    /// the cards follow changes made anywhere (global shortcuts, the menu, this
    /// column), and while a group is being edited the ticks follow too.
    private func refreshGroupState() {
        refreshGroupRows()
        refreshGroupBadges()
        guard model.selectedGroupSlot != nil else { return }
        syncGroupTicks()
    }

    /// Recomputes which groups each visible card belongs to, for the badges on
    /// the thumbnails.
    private func refreshGroupBadges() {
        guard let store else { return }
        model.groupBadges = store.groupSlots(among: model.items)
    }

    /// Re-fits the panel after the window list shrank, so the grid and the
    /// panel keep matching the number of cards.
    private func refreshLayout() {
        guard let store, let panel, isVisible else { return }
        updateLayout(in: panel, store: store, rescan: false)
    }

    /// ⌥Q: closes the highlighted window (the app keeps its unsaved-changes
    /// prompt). The card is removed in place so the grid does not shuffle, then
    /// the list is reconciled once the window is really gone.
    private func closeSelection() {
        guard let window = selectedWindow() else { return }
        suppressReleaseActivation = true
        WorkspaceStore.shared.close(window)
        model.items.removeAll { $0.id == window.id }
        model.previews[window.id] = nil
        pruneSelection()
        refreshGroupState()
        guard !model.items.isEmpty else { hide(); return }
        model.selection = min(model.selection, max(0, model.filtered.count - 1))
        loadPreviews(for: model.items, refresh: false)
        highlightSelection()
        refreshLayout()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.isVisible else { return }
            self.reconcileItems()
        }
    }

    /// ⌥M: minimises the highlighted window. It is updated in place (staying in
    /// the grid with a Dock icon, so it can be brought back) to keep the order
    /// and the selection stable.
    private func minimizeSelection() {
        guard let window = selectedWindow() else { return }
        suppressReleaseActivation = true
        WorkspaceStore.shared.minimize(window)
        if let index = model.items.firstIndex(where: { $0.id == window.id }) {
            model.items[index].minimized = true
            model.items[index].state = .minimized
        }
        model.previews[window.id] = nil
        highlightSelection()
    }

    /// ⌥⇧Q: quits the selected window's application (`terminate()`, never forced,
    /// so the app keeps its save prompts). All that app's cards are removed.
    private func quitSelection() {
        guard let window = selectedWindow() else { return }
        suppressReleaseActivation = true
        WorkspaceStore.shared.quit(window)
        let pid = window.pid
        model.items.removeAll { $0.pid == pid }
        model.previews = model.previews.filter { key, _ in
            model.items.contains { $0.id == key && !$0.minimized }
        }
        pruneSelection()
        refreshGroupState()
        guard !model.items.isEmpty else { hide(); return }
        model.selection = min(model.selection, max(0, model.filtered.count - 1))
        loadPreviews(for: model.items, refresh: false)
        highlightSelection()
        refreshLayout()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isVisible else { return }
            self.reconcileItems()
        }
    }

    /// Re-reads the list after a close, in case the app kept the window open
    /// (unsaved-changes prompt) or other windows changed meanwhile.
    private func reconcileItems() {
        WindowIndex.shared.invalidate()
        let generation = loadGeneration
        WindowIndex.shared.refreshAsync { [weak self] _ in
            guard let self, self.isVisible, self.loadGeneration == generation else { return }
            self.applyReconciledItems()
        }
    }

    private func applyReconciledItems() {
        let store = WorkspaceStore.shared
        let fresh = orderedForSession(store.orderedWindowsForPalette(store.cachedActionableWindows()))
        guard !fresh.isEmpty else { hide(); return }
        let selectedID = selectedWindow()?.id
        model.items = fresh
        pruneSelection()
        refreshGroupState()
        model.previews = model.previews.filter { key, _ in
            fresh.contains { $0.id == key && !$0.minimized }
        }
        if let selectedID, let index = model.filtered.firstIndex(where: { $0.id == selectedID }) {
            model.selection = index
        } else {
            model.selection = min(model.selection, max(0, model.filtered.count - 1))
        }
        loadPreviews(for: model.items, refresh: false)
        highlightSelection()
        refreshLayout()
    }

    private func activateSelection() {
        let list = model.filtered
        guard model.selection < list.count else { hide(); return }
        activate(list[model.selection].id)
    }

    private func orderedForSession(_ incoming: [ActionableWindow]) -> [ActionableWindow] {
        let byID = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        return PaletteOrdering.stableOrder(existing: model.items.map(\.id), incoming: incoming.map(\.id))
            .compactMap { byID[$0] }
    }

    private func initialBrowseSelection() -> Int {
        let ids = model.filtered.map(\.id)
        guard !ids.isEmpty else { return 0 }
        let initial = PaletteOrdering.initialSelection(ids: ids, origin: originWindowID, backwards: openedBackwards)
        return ((initial + pendingBrowseSteps) % ids.count + ids.count) % ids.count
    }

    /// Acts on the window already in `model.items` — no second full desktop scan,
    /// and the action is never lost if an id changed meanwhile (A11). Brings an
    /// off-screen window back on screen, not just to the front.
    private func activate(_ id: String) {
        guard let window = model.items.first(where: { $0.id == id }) else { hide(); return }
        hide()
        WorkspaceStore.shared.bringOnScreen(window)
    }

    /// Places the panel: full screen fills the visible frame exactly, compact is
    /// centred but shifted away from the overlay so they don't overlap.
    private func place(_ panel: NSWindow, store: WorkspaceStore, layout: PaletteLayout, screen: NSScreen?) {
        guard let screen else { return }
        let frame = screen.visibleFrame
        switch layout {
        case .fullScreen:
            panel.setFrame(CGRect(origin: frame.origin, size: panel.frame.size), display: true)
            return
        case .compact:
            let width = panel.frame.width
            let height = panel.frame.height
            var origin = CGPoint(x: frame.midX - width / 2, y: frame.midY - height / 2)
            let paletteFrame = CGRect(origin: origin, size: panel.frame.size)
            let overlay = store.overlayFrame
            if paletteFrame.intersects(overlay) {
                origin.y = overlay.midY > frame.midY
                    ? frame.minY + 24
                    : frame.maxY - height - 24
            }
            panel.setFrameOrigin(origin)
        }
    }

    private func selectPresentationScreen(_ location: PaletteScreenLocation) {
        let screens = NSScreen.screens
        let focusedID = NSScreen.main.flatMap(Self.displayID)
        let focusedIndex = focusedID.flatMap { id in screens.firstIndex { Self.displayID($0) == id } }
        let index = location.screenIndex(frames: screens.map(\.frame),
                                         focusedIndex: focusedIndex, mouse: NSEvent.mouseLocation)
        presentationDisplayID = index.flatMap { Self.displayID(screens[$0]) }
    }

    private var presentationScreen: NSScreen? {
        let screens = NSScreen.screens
        if let presentationDisplayID,
           let screen = screens.first(where: { Self.displayID($0) == presentationDisplayID }) {
            return screen
        }
        // The opening display may have been disconnected while the panel is up.
        return NSScreen.main ?? screens.first
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func makePanel(size: CGSize) -> PalettePanel {
        let panel = PalettePanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        return panel
    }
}

final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct PaletteView: View {
    @Bindable var model: PaletteModel
    let onActivate: (String) -> Void
    let onClose: () -> Void
    let onLayoutCommand: (PaletteLayoutCommand) -> Void
    /// The field took the focus: behave as a search from now on.
    let onFocusSearch: () -> Void
    /// Groups column (G3).
    let onSelectGroup: (Int) -> Void
    let onRecallGroup: (Int) -> Void
    let onResetGroup: (Int) -> Void
    let onToggleGroupMember: (String) -> Void
    /// The pointer moved over a card (T28).
    let onHoverCard: (Int) -> Void
    let onCardVisibility: (String, Bool) -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            // The groups column is always there: it is the point of the ⌥Space
            // palette, and useful in the plain ⌥Tab switcher too.
            groupsColumn
            Rectangle()
                .fill(model.theme.surface.opacity(0.8))
                .frame(width: 1)
            VStack(spacing: 0) {
                // One panel, one set of elements: the field is always here. The
                // mode only decides who owns the keyboard — browsing keeps it
                // unfocused and dimmed (⌥ is held, releasing picks a window),
                // searching focuses it and keeps the panel open.
                HStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(model.theme.subtext)
                        TextField(model.mode == .search ? "Filter windows…" : "Filter windows — ⌥Space",
                                  text: $model.query)
                            .textFieldStyle(.plain)
                            .font(.system(size: 18 * scale))
                            .foregroundStyle(model.theme.text)
                            .frame(width: 320 * scale)
                            .focused($focused)
                            .onSubmit { activateSelection() }
                            // In browse mode the keyboard belongs to the grid,
                            // and a field that cannot take the focus is
                            // the only way to keep it out when the panel
                            // becomes key: otherwise AppKit hands the focus to
                            // the first thing that will take it — this field —
                            // and ⌥Tab starts typing into a search (T29).
                            // A click still turns the palette into a search,
                            // through the container's tap below.
                            .disabled(model.mode != .search)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if model.mode != .search { onFocusSearch() }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10).fill(model.theme.surface))
                    .opacity(model.mode == .search ? 1 : 0.7)
                    Spacer()
                }
                .padding(.vertical, 14)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(model.metrics.cardWidth), spacing: model.metrics.spacing),
                                                 count: model.columns),
                                  spacing: model.metrics.spacing) {
                            ForEach(Array(model.filtered.enumerated()), id: \.element.id) { index, window in
                                PaletteCard(window: window,
                                            preview: model.previews[window.id],
                                            showPreview: model.showPreview,
                                            tinted: model.tintedCards,
                                            selected: index == model.selection,
                                            layoutSelected: model.selectedIDs.contains(window.id),
                                            metrics: model.metrics,
                                            theme: model.theme,
                                            groupSlots: model.groupBadges[window.id] ?? [],
                                            editedSlot: model.selectedGroupSlot)
                                    .id(window.id)
                                    .onAppear { onCardVisibility(window.id, true) }
                                    .onDisappear { onCardVisibility(window.id, false) }
                                    // The pointer chooses a card only when it is
                                    // actually moving: entering it, or moving
                                    // inside it (continuous hover is what makes
                                    // the second case work). A report with the
                                    // pointer still where the keyboard left it is
                                    // ignored by the palette (T28).
                                    .onHover { if $0 { onHoverCard(index) } }
                                    .onContinuousHover { phase in
                                        if case .active = phase { onHoverCard(index) }
                                    }
                                    .onTapGesture {
                                        // In browse mode, with a group being
                                        // edited, a click adds or removes the
                                        // window from it; otherwise it opens
                                        // the window (which is what a click on
                                        // a search result should always do).
                                        if model.mode == .browse, model.selectedGroupSlot != nil {
                                            onToggleGroupMember(window.id)
                                        } else {
                                            onActivate(window.id)
                                        }
                                    }
                            }
                        }
                        // Fixed-width cards keep every preview box at the screen's
                        // proportions; the grid is then centred in the panel.
                        .frame(width: model.metrics.gridWidth)
                        .padding(model.metrics.padding)
                        // Full screen fills the screen: centre the grid vertically
                        // when it is shorter than the space, so few windows are not
                        // stuck to the top. Compact keeps the panel snug to the grid.
                        .frame(maxWidth: .infinity,
                               minHeight: model.metrics.layout == .fullScreen ? model.metrics.gridAreaHeight : 0,
                               alignment: .center)
                    }
                    .overlay {
                        if model.items.isEmpty && model.isLoadingWindows {
                            VStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Finding windows…")
                                    .font(.system(size: model.metrics.fontSize))
                                    .foregroundStyle(model.theme.subtext)
                            }
                        }
                    }
                    .onChange(of: model.selection) { _, _ in
                        let list = model.filtered
                        if model.selection < list.count {
                            if model.animationsEnabled {
                                withAnimation(.easeOut(duration: model.animationDuration)) {
                                    proxy.scrollTo(list[model.selection].id, anchor: .center)
                                }
                            } else {
                                proxy.scrollTo(list[model.selection].id, anchor: .center)
                            }
                        }
                    }
                }

                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: model.metrics.panelCornerRadius)
            .fill(model.theme.background.opacity(model.opacity)))
        .overlay(RoundedRectangle(cornerRadius: model.metrics.panelCornerRadius)
            .stroke(model.theme.border, lineWidth: 1))
        .onChange(of: model.query) { _, _ in model.selection = 0 }
        .onChange(of: model.mode) { _, mode in
            focused = mode == .search
            if mode != .search { focused = false }
        }
        .onChange(of: model.focusToken) { _, _ in
            if model.mode == .search { focused = true }
        }
        // Whatever puts the caret in the field — ⌥Space, or a click — turns the
        // palette into a search: from then on it stays open when ⌥ is released
        // and the keys go to the field.
        .onChange(of: focused) { _, isFocused in
            if isFocused, model.mode == .browse { onFocusSearch() }
        }
        .onAppear { focused = model.mode == .search }
    }

    private var scale: CGFloat { model.metrics.fontSize / 12 }

    // MARK: - Groups column (G3)

    /// The nine groups down the side of the palette. Clicking one points the
    /// ticks at its members; its buttons recall or reset it. It stays visible in
    /// both modes, so a group being edited keeps its ticks while searching.
    private var groupsColumn: some View {
        ScrollView {
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "square.on.square").font(.system(size: 10 * scale))
                    Text("GROUPS")
                        .font(.system(size: 10 * scale, weight: .bold))
                        .tracking(0.6)
                    Spacer()
                }
                .foregroundStyle(model.theme.subtext)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 4)

                ForEach(model.groupRows) { row in
                    groupRow(row)
                }
            }
            .padding(.vertical, 8)
        }
        .frame(width: PaletteLayoutEngine.groupColumnWidth, alignment: .top)
        .frame(maxHeight: .infinity)
    }

    private func groupRow(_ row: PaletteGroupRow) -> some View {
        let isSelected = model.selectedGroupSlot == row.slot
        let isPending = model.groupPendingReset == row.slot
        return VStack(alignment: .leading, spacing: 5) {
            // The tap lives on the top line only, so the Recall/Reset buttons
            // below it keep their own, unambiguous clicks.
            HStack(spacing: 8) {
                Text("\(row.slot)")
                    .font(.system(size: 12 * scale, weight: .bold).monospacedDigit())
                    .frame(width: 16, alignment: .leading)
                    .foregroundStyle(model.theme.text)
                // Filled when this group is the scene on screen (T15), clear
                // otherwise, so the row keeps its width either way.
                Circle()
                    .fill(row.isOnScreen ? model.theme.accent : Color.clear)
                    .frame(width: 5 * scale, height: 5 * scale)
                    .help(row.isOnScreen ? "On screen now" : "")
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.displayName)
                        .font(.system(size: 12 * scale, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(model.theme.text)
                    Text("⌃⌥\(row.slot)")
                        .font(.system(size: 9.5 * scale).monospaced())
                        .foregroundStyle(model.theme.subtext)
                }
                Spacer(minLength: 4)
                Text("\(row.memberCount)")
                    .font(.system(size: 11 * scale, weight: .semibold).monospacedDigit())
                    .foregroundStyle(row.memberCount > 0 ? model.theme.text
                                                         : model.theme.subtext.opacity(0.55))
            }
            .contentShape(Rectangle())
            .onTapGesture { onSelectGroup(row.slot) }

            if isSelected {
                HStack(spacing: 6) {
                    columnButton("Recall", symbol: "arrow.up.left.and.arrow.down.right") {
                        onRecallGroup(row.slot)
                    }
                    columnButton(isPending ? "Confirm" : "Reset",
                                 symbol: isPending ? "exclamationmark.triangle.fill" : "trash") {
                        onResetGroup(row.slot)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? model.theme.surface : Color.clear))
        .padding(.horizontal, 6)
        .help("\(row.displayName) — click to edit its members, then Recall")
    }

    private func columnButton(_ title: String, symbol: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10 * scale))
                Text(title).font(.system(size: 11 * scale, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(model.theme.surface))
            .foregroundStyle(title == "Confirm" ? Color.red : model.theme.text)
        }
        .buttonStyle(.plain)
    }

    /// Footer: the key hints and the layout commands. The hints follow the mode,
    /// because the keys do — while browsing ⌥ is held (and releasing it picks the
    /// highlighted window), while searching it is not and the field has the keys.
    private var footer: some View {
        HStack(spacing: 16 * scale) {
            if model.mode == .browse {
                keyHint("⏎", "open")
                keyHint("⌥Q", "close")
                keyHint("⌥⇧Q", "quit")
                keyHint("⌥M", "minimize")
                keyHint("1…9", "group")
                keyHint("⌥Space", "search")
            } else {
                keyHint("↑↓", "choose")
                keyHint("⏎", "open")
                keyHint("⌥Space", "next")
                keyHint("esc", "close")
            }
            Spacer()
            if let slot = model.selectedGroupSlot {
                let name = model.groupRows.first { $0.slot == slot }?.displayName ?? "Group \(slot)"
                Text("Editing \(name) · \(model.selectedIDs.count)")
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .foregroundStyle(model.theme.text)
            } else {
                Text(model.selectedIDs.isEmpty
                     ? "Layouts act on the windows in view"
                     : "Layouts act on the ticked windows")
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(model.theme.subtext)
            }
            commandButton("Tile", symbol: "square.grid.3x3") { onLayoutCommand(.tile) }
            commandButton("Golden", symbol: "circle.hexagongrid") { onLayoutCommand(.goldenSpiral) }
            commandButton("Content", symbol: "rectangle.3.group") { onLayoutCommand(.content) }
            commandButton("Auto", symbol: "wand.and.stars") { onLayoutCommand(.auto) }
            commandButton("Focus", symbol: "eye") { onLayoutCommand(.focus) }
        }
        .padding(.horizontal, model.metrics.padding)
        .padding(.bottom, 12 * scale)
    }

    private func commandButton(_ title: String, symbol: String? = nil,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10 * scale)) }
                Text(title).font(.system(size: 11 * scale, weight: .semibold))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(model.theme.surface))
            .foregroundStyle(model.theme.text)
        }
        .buttonStyle(.plain)
    }

    private func activateSelection() {
        let list = model.filtered
        if model.selection < list.count { onActivate(list[model.selection].id) }
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 11 * scale, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(model.theme.surface))
                .foregroundStyle(model.theme.text)
            Text(label)
                .font(.system(size: 11 * scale))
                .foregroundStyle(model.theme.subtext)
        }
    }
}

/// A single preview card. Its own `View` so SwiftUI can skip re-rendering the
/// cards whose inputs did not change when only the selection moves — keeping the
/// thumbnails steady (no flicker).
private struct PaletteCard: View {
    let window: ActionableWindow
    let preview: NSImage?
    let showPreview: Bool
    let tinted: Bool
    let selected: Bool
    let layoutSelected: Bool
    let metrics: PaletteMetrics
    let theme: PaletteTheme
    /// The groups this window belongs to, shown as number badges; the one being
    /// edited is highlighted.
    let groupSlots: [Int]
    let editedSlot: Int?

    /// Minimised windows are drawn faded so their off-screen state is visible
    /// even when a (stale) preview is present.
    private var dimmed: Bool { window.state != .normal }
    /// The neutral background used when the per-app tint is off (T12).
    private var surfaceTint: Color {
        tinted ? Color(nsColor: window.color) : theme.surface
    }
    private var glyphTint: Color {
        tinted ? Color(nsColor: window.color) : theme.subtext
    }

    var body: some View {
        VStack(spacing: 8 * (metrics.fontSize / 12)) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(surfaceTint.opacity(dimmed ? 0.10 : 0.22))
                if showPreview, let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                        .opacity(dimmed ? 0.45 : 1)
                } else if let icon = window.icon {
                    // No live thumbnail (minimised / off-screen / permission):
                    // show the app's real icon instead of a generic glyph.
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: metrics.iconSize * 2, height: metrics.iconSize * 2)
                        .opacity(dimmed ? 0.7 : 0.9)
                } else {
                    Image(systemName: window.state == .minimized ? "dock.rectangle" : "macwindow")
                        .font(.system(size: metrics.iconSize * 1.5))
                        .foregroundStyle(glyphTint)
                        .opacity(dimmed ? 0.55 : 1)
                }
            }
            // The box keeps the screen's proportions (T15), so a preview is
            // never stretched into an over-wide or over-tall ribbon.
            .frame(width: metrics.thumbnailWidth, height: metrics.thumbnailHeight)
            // A minimised window gets a hatched overlay.
            .overlay { if dimmed { DiagonalHatch(color: theme.subtext.opacity(0.22)) } }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) { stateBadge }
            .overlay(alignment: .bottomTrailing) { appIcon }
            .overlay(alignment: .topLeading) { selectionTick }
            .overlay(alignment: .bottomLeading) { groupBadges }
            Text(window.title.isEmpty ? window.appName : window.title)
                .font(.system(size: metrics.fontSize, weight: .semibold))
                .lineLimit(1).foregroundStyle(theme.text)
            Text(window.appName)
                .font(.system(size: metrics.fontSize * 0.85)).lineLimit(1).foregroundStyle(theme.subtext)
        }
        .padding(10 * (metrics.fontSize / 12))
        .background(RoundedRectangle(cornerRadius: 14).fill(selected ? theme.surfaceSelected : theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(selected ? theme.accent : (layoutSelected ? theme.border : .clear),
                    lineWidth: selected ? 3 : 2))
    }

    /// Tick shown on the cards of the group being edited (G3), top-left so it
    /// never collides with the state badge or the app icon. Without a group
    /// there is no tick: the palette is then just a window switcher.
    @ViewBuilder private var selectionTick: some View {
        if layoutSelected, editedSlot != nil {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: metrics.badgeSymbolSize + 5, weight: .bold))
                .foregroundStyle(theme.accent)
                .padding(6)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(theme.border, lineWidth: 1))
                .padding(6)
        }
    }

    /// The group numbers this window belongs to, bottom-left, so a glance says
    /// which groups a recall would bring along with it. The group being edited
    /// (if any) is filled with the accent colour.
    @ViewBuilder private var groupBadges: some View {
        if !groupSlots.isEmpty {
            HStack(spacing: 3) {
                ForEach(groupSlots, id: \.self) { slot in
                    let editing = slot == editedSlot
                    Text("\(slot)")
                        .font(.system(size: metrics.badgeSymbolSize + 1, weight: .bold).monospacedDigit())
                        .foregroundStyle(editing ? theme.background : theme.text)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(editing ? theme.accent : theme.surface, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.border, lineWidth: 1))
                }
            }
            .padding(7)
            .help(groupSlots.map { "Group \($0)" }.joined(separator: ", "))
        }
    }

    /// State indicator (T5): minimised. Top-right, so it never collides with
    /// the app icon in the bottom-right (T3).
    @ViewBuilder private var stateBadge: some View {
        switch window.state {
        case .normal:
            EmptyView()
        case .minimized:
            badge(symbol: "dock.rectangle", label: "Minimized")
        case .unavailable:
            badge(symbol: "clock", label: "Temporarily unavailable")
        }
    }

    /// The owning app's icon (T3), bottom-right, over a light material so it
    /// stays legible on any thumbnail.
    @ViewBuilder private var appIcon: some View {
        if let icon = window.icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: metrics.iconSize, height: metrics.iconSize)
                .padding(3)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.border, lineWidth: 1))
                .opacity(0.95)
                .padding(7)
                .help(window.appName)
        }
    }

    private func badge(symbol: String, label: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: metrics.badgeSymbolSize, weight: .semibold))
            .foregroundStyle(theme.text)
            .padding(5)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.border, lineWidth: 1))
            .padding(6)
            .help(label)
    }
}

/// Light diagonal stripes marking a minimised window (T5).
private struct DiagonalHatch: View {
    let color: Color
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 9
            var x = -size.height
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(path, with: .color(color), lineWidth: 1)
                x += spacing
            }
        }
        .allowsHitTesting(false)
    }
}
