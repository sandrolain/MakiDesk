import AppKit
import SwiftUI
import Observation

enum PaletteMode { case browse, search }

/// Shared state of the window palette.
@Observable
final class PaletteModel {
    var items: [ActionableWindow] = []
    var previews: [String: NSImage] = [:]
    var query = ""
    var selection = 0
    var mode: PaletteMode = .browse
    var theme: PaletteTheme = PaletteTheme.all[0]
    var showPreview = true
    var columns = 3
    var opacity: Double = 0.9
    var focusToken = 0

    var filtered: [ActionableWindow] {
        guard !query.isEmpty else { return items }
        let needle = query.lowercased()
        return items.filter {
            $0.title.lowercased().contains(needle) || $0.appName.lowercased().contains(needle)
        }
    }
}

/// One palette for both Opt+Tab (browse) and Opt+Space (search): a grid of live
/// previews, navigable with the keyboard or the mouse, with a filter field.
final class WindowPalette {
    static let shared = WindowPalette()

    private var panel: PalettePanel?
    private var hosting: NSHostingView<PaletteView>?
    private var monitor: Any?
    let model = PaletteModel()

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(store: WorkspaceStore, mode: PaletteMode, backwards: Bool = false) {
        model.theme = store.theme
        model.showPreview = store.showPreview
        model.opacity = store.paletteOpacity
        model.focusToken += 1
        if isVisible {
            if model.mode == mode {
                move(backwards ? -1 : 1)
            } else {
                model.mode = mode
                if mode == .search { model.query = "" }
                model.selection = 0
            }
            return
        }
        model.items = store.actionableWindows()
        guard !model.items.isEmpty else { return }
        model.previews = [:]
        if store.showPreview {
            for window in model.items {
                if let image = WindowController.previewImage(pid: window.pid, frame: window.frame) {
                    model.previews[window.id] = image
                }
            }
        }
        model.query = ""
        model.mode = mode
        model.columns = columnCount(for: model.items.count)
        model.selection = backwards ? model.filtered.count - 1 : 0

        var size = panelSize(items: model.items.count, columns: model.columns)
        size = CGSize(width: size.width * store.paletteScale, height: size.height * store.paletteScale)
        let panel = self.panel ?? makePanel(size: size)
        self.panel = panel
        panel.setContentSize(size)
        if hosting == nil {
            let hosting = NSHostingView(rootView: PaletteView(
                model: model,
                onActivate: { [weak self] id in self?.activate(id) },
                onClose: { [weak self] in self?.hide() }
            ))
            hosting.frame = CGRect(origin: .zero, size: size)
            panel.contentView = hosting
            self.hosting = hosting
        }
        place(panel, store: store)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        installMonitor()
        highlightSelection()
    }

    func hide() {
        removeMonitor()
        panel?.orderOut(nil)
    }

    private func move(_ delta: Int) {
        let count = model.filtered.count
        guard count > 0 else { return }
        model.selection = (model.selection + delta + count) % count
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
        highlightSelection()
    }

    private func highlightSelection() {
        guard WorkspaceStore.shared.showMiniMap else { return }
        let list = model.filtered
        guard model.selection < list.count else { return }
        let window = list[model.selection]
        let mapped = WorkspaceWindow(title: window.title, appName: window.appName,
                                     x: window.frame.minX, y: window.frame.minY,
                                     width: window.frame.width, height: window.frame.height)
        MiniMapController.shared.show(windows: [mapped], highlightedIDs: [mapped.id])
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
                activateSelection()
                return true
            }
            return false
        }
        switch event.keyCode {
        case 53: hide(); return true                       // Esc
        case 36, 76: activateSelection(); return true      // Return / Enter
        case 123: moveGrid(-1, 0); return true             // Left
        case 124: moveGrid(1, 0); return true              // Right
        case 125: moveGrid(0, 1); return true              // Down
        case 126: moveGrid(0, -1); return true             // Up
        case 48: return model.mode == .browse              // Tab cycles in browse mode
        default: return false
        }
    }

    private func activateSelection() {
        let list = model.filtered
        guard model.selection < list.count else { hide(); return }
        activate(list[model.selection].id)
    }

    private func activate(_ id: String) {
        guard let window = WorkspaceStore.shared.actionableWindows().first(where: { $0.id == id }) else {
            hide(); return
        }
        hide()
        WorkspaceStore.shared.focus(window)
    }

    private func columnCount(for items: Int) -> Int {
        switch items {
        case 0...4: return 2
        case 5...9: return 3
        default: return 4
        }
    }

    private func panelSize(items: Int, columns: Int) -> CGSize {
        let cardWidth: CGFloat = 250
        let cardHeight: CGFloat = 210
        let rows = max(1, Int(ceil(Double(items) / Double(columns))))
        let width = min(CGFloat(columns) * cardWidth + 60, 1400)
        let height = min(CGFloat(rows) * cardHeight + 90, 900)
        return CGSize(width: width, height: height)
    }

    /// Centres the palette but shifts it away from the overlay so they don't
    /// overlap.
    private func place(_ panel: NSWindow, store: WorkspaceStore) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
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

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(model.theme.subtext)
                    TextField("Filter windows…", text: $model.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18))
                        .foregroundStyle(model.theme.text)
                        .frame(width: 320)
                        .focused($focused)
                        .onSubmit { activateSelection() }
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).fill(model.theme.surface))
                Spacer()
            }
            .padding(.vertical, 14)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: model.columns), spacing: 16) {
                        ForEach(Array(model.filtered.enumerated()), id: \.element.id) { index, window in
                            card(window, selected: index == model.selection)
                                .id(window.id)
                                .onHover { if $0 { model.selection = index } }
                                .onTapGesture { onActivate(window.id) }
                        }
                    }
                    .padding(20)
                }
                .onChange(of: model.selection) { _, _ in
                    let list = model.filtered
                    if model.selection < list.count {
                        withAnimation { proxy.scrollTo(list[model.selection].id, anchor: .center) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 20).fill(model.theme.background.opacity(model.opacity)))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(model.theme.border, lineWidth: 1))
        .onChange(of: model.query) { _, _ in model.selection = 0 }
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { _, _ in focused = true }
    }

    private func activateSelection() {
        let list = model.filtered
        if model.selection < list.count { onActivate(list[model.selection].id) }
    }

    private func card(_ window: ActionableWindow, selected: Bool) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: window.color).opacity(0.22))
                if model.showPreview, let preview = model.previews[window.id] {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                } else {
                    Image(systemName: window.minimized ? "dock.rectangle" : "macwindow")
                        .font(.system(size: 44))
                        .foregroundStyle(Color(nsColor: window.color))
                }
            }
            .frame(height: 150)
            Text(window.title.isEmpty ? window.appName : window.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1).foregroundStyle(model.theme.text)
            Text(window.appName)
                .font(.system(size: 10)).lineLimit(1).foregroundStyle(model.theme.subtext)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(selected ? model.theme.surfaceSelected : model.theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? model.theme.accent : .clear, lineWidth: 3))
    }
}
