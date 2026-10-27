import AppKit
import Carbon.HIToolbox
import ImageIO
import SwiftUI

// MARK: - Model

@MainActor
@Observable
final class ClipboardModel {
    var entries: [ClipboardEntry] = []
    var selection = 0
    var theme: PaletteTheme = PaletteTheme.all[0]
    var opacity: Double = 0.98
    var animationsEnabled = true
    var animationDuration = 0.22

    var selectedEntry: ClipboardEntry? {
        entries.indices.contains(selection) ? entries[selection] : nil
    }

    func reload(from history: ClipboardHistory) {
        let selectedID = selectedEntry?.id
        entries = history.entries
        if let selectedID, let index = entries.firstIndex(where: { $0.id == selectedID }) {
            selection = index
        } else if entries.isEmpty {
            selection = 0
        } else {
            selection = min(selection, entries.count - 1)
        }
    }

    func move(by delta: Int) {
        guard entries.isEmpty == false else { selection = 0; return }
        selection = min(max(0, selection + delta), entries.count - 1)
    }

    func moveToStart() { selection = 0 }

    func moveToEnd() {
        selection = max(0, entries.count - 1)
    }
}

// MARK: - Panel

/// The clipboard picker (T21): a lightweight panel over the active app. A
/// choice puts the text back on the pasteboard and pastes it where the user
/// was working.
@MainActor
final class ClipboardController: NSObject, NSWindowDelegate {
    static let shared = ClipboardController()

    private static let size = NSSize(width: 560, height: 420)

    private let history = ClipboardHistory.shared
    private let model = ClipboardModel()
    private var panel: ClipboardPanel?
    private var hosting: NSHostingView<ClipboardView>?
    private var monitor: Any?
    private var previousApp: NSRunningApplication?
    private var notesWasKey = false
    private let focusReturn = PanelFocusReturn()

    var isVisible: Bool { panel?.isVisible == true }

    private override init() {
        super.init()
        history.onChange = { [weak self] in
            guard let self, self.isVisible else { return }
            self.model.reload(from: self.history)
        }
        NotificationCenter.default.addObserver(
            forName: .makiDeskThemeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.theme = PaletteTheme.named(
                    UserDefaults.standard.string(forKey: "themeID") ?? "mocha")
            }
        }
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        // A password prompt must not put the earlier history on screen.
        guard IsSecureEventInputEnabled() == false else {
            HUDController.shared.show("Clipboard history is off while secure input is active",
                                      symbol: "lock.fill")
            return
        }
        if isVisible {
            panel?.makeKeyAndOrderFront(nil)
            return
        }

        history.start()
        focusReturn.capture()
        previousApp = NSWorkspace.shared.frontmostApplication
        notesWasKey = NotesController.shared.isKey
        model.theme = PaletteTheme.named(UserDefaults.standard.string(forKey: "themeID") ?? "mocha")
        model.animationsEnabled = WorkspaceStore.shared.effectiveAnimationsEnabled
        model.animationDuration = WorkspaceStore.shared.animationDuration
        model.reload(from: history)

        let panel = buildIfNeeded()
        place(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        // The local monitor takes the arrows and Return; nothing in the view
        // needs the keyboard focus.
        panel.makeFirstResponder(nil)
        installMonitor()
    }

    func hide(restoringFocus: Bool = true) {
        guard isVisible else { return }
        let restoreFocus = focusReturn.takeRestoreAction(
            ownsKeyboard: restoringFocus && panel?.isKeyWindow == true)
        removeMonitor()
        panel?.orderOut(nil)
        previousApp = nil
        restoreFocus?()
    }

    private func buildIfNeeded() -> ClipboardPanel {
        if let panel { return panel }
        let hosting = NSHostingView(rootView: ClipboardView(
            model: model,
            onPick: { [weak self] entry in self?.paste(entry) },
            onClear: { ClipboardHistory.shared.clear() },
            onShelf: { [weak self] entry in
                self?.hide(restoringFocus: false)
                ShelfController.shared.add(text: entry.text)
            }
        ))
        hosting.frame = NSRect(origin: .zero, size: Self.size)

        let panel = ClipboardPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.delegate = self
        self.panel = panel
        self.hosting = hosting
        return panel
    }

    /// Compact picker on the screen where the pointer is, like the palette.
    private func place(_ panel: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = Self.size
        let frame = NSRect(x: visible.midX - size.width / 2,
                           y: visible.midY - size.height / 2 + 40,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: false)
    }

    // MARK: - Pasting

    private func paste(_ entry: ClipboardEntry) {
        let target = previousApp
        let pasteIntoNotes = notesWasKey
        let targetIsUs = target?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        hide(restoringFocus: targetIsUs)

        let pasteboard = NSPasteboard.general
        let item = NSPasteboardItem()
        guard item.setString(entry.text, forType: .string), pasteboard.writeObjects([item]) else {
            HUDController.shared.show("Could not write to the clipboard", symbol: "exclamationmark.triangle.fill")
            return
        }
        history.markPasteboardSeen()
        history.promote(entry)

        if let target, targetIsUs == false {
            guard AXIsProcessTrusted() else {
                HUDController.shared.show("Accessibility not granted · the text is on the clipboard",
                                          symbol: "exclamationmark.triangle.fill")
                return
            }
            if target.activate(options: []) {
                let targetPID = target.processIdentifier
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else { return }
                    Self.postCommandV()
                }
                return
            }
        }
        // The notes panel (or another text field of ours) was in front. If no
        // responder takes the paste, fall back to the open note's cursor.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard NSApp.isActive else { return }
            let handled = NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            if handled == false, pasteIntoNotes, NotesController.shared.isVisible, NSApp.isActive {
                NotesController.shared.insertText(entry.text)
            }
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            switch event.specialKey {
            case .upArrow: self.model.move(by: -1); return nil
            case .downArrow: self.model.move(by: 1); return nil
            case .pageUp: self.model.move(by: -6); return nil
            case .pageDown: self.model.move(by: 6); return nil
            case .home: self.model.moveToStart(); return nil
            case .end: self.model.moveToEnd(); return nil
            default: break
            }
            switch Int(event.keyCode) {
            case Int(kVK_Return), Int(kVK_ANSI_KeypadEnter):
                if let entry = self.model.selectedEntry { self.paste(entry) }
                return nil
            case Int(kVK_Escape):
                self.hide()
                return nil
            default:
                return event
            }
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        if isVisible { hide(restoringFocus: false) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}

final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - View

struct ClipboardView: View {
    @Bindable var model: ClipboardModel
    let onPick: (ClipboardEntry) -> Void
    let onClear: () -> Void
    let onShelf: (ClipboardEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(model.theme.border.opacity(0.55))
                .frame(height: 1)
            if model.entries.isEmpty {
                empty
            } else {
                list
            }
            Rectangle()
                .fill(model.theme.border.opacity(0.55))
                .frame(height: 1)
            footer
        }
        .frame(width: 560, height: 420)
        .background(RoundedRectangle(cornerRadius: 14)
            .fill(model.theme.background.opacity(model.opacity)))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(model.theme.border.opacity(0.8), lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.theme.accent)
            Text("Clipboard")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.theme.text)
            Spacer()
            Text(model.entries.count == 1 ? "1 item" : "\(model.entries.count) items")
                .font(.system(size: 10.5))
                .foregroundStyle(model.theme.subtext)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 4) {
                    ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                        ClipboardRow(entry: entry, selected: index == model.selection,
                                     theme: model.theme, onShelf: onShelf)
                            .id(entry.id)
                            .onTapGesture { onPick(entry) }
                    }
                }
                .padding(10)
            }
            .onChange(of: model.selection) { _, _ in
                if let entry = model.selectedEntry {
                    if model.animationsEnabled {
                        withAnimation(.easeOut(duration: model.animationDuration)) {
                            proxy.scrollTo(entry.id, anchor: .center)
                        }
                    } else {
                        proxy.scrollTo(entry.id, anchor: .center)
                    }
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(model.theme.subtext)
            Text("Nothing copied yet")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(model.theme.text)
            Text("Copy some text, then press ⌥V.")
                .font(.system(size: 11))
                .foregroundStyle(model.theme.subtext)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            hint("↑↓", "select")
            hint("↩", "paste")
            hint("esc", "close")
            Spacer()
            Button("To Shelf") {
                if let entry = model.selectedEntry { onShelf(entry) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(model.selectedEntry == nil
                ? model.theme.subtext.opacity(0.4)
                : model.theme.subtext)
            .disabled(model.selectedEntry == nil)
            Text("·")
                .font(.system(size: 10))
                .foregroundStyle(model.theme.subtext.opacity(0.5))
            Button("Clear") { onClear() }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(model.entries.isEmpty
                    ? model.theme.subtext.opacity(0.4)
                    : model.theme.subtext)
                .disabled(model.entries.isEmpty)
            Text("·")
                .font(.system(size: 10))
                .foregroundStyle(model.theme.subtext.opacity(0.5))
            Text("Kept in memory only")
                .font(.system(size: 10))
                .foregroundStyle(model.theme.subtext.opacity(0.8))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(model.theme.text)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(model.theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(model.theme.border.opacity(0.7), lineWidth: 1))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(model.theme.subtext)
        }
    }
}

private struct ClipboardRow: View {
    let entry: ClipboardEntry
    let selected: Bool
    let theme: PaletteTheme
    let onShelf: (ClipboardEntry) -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            leading
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.preview)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(entry.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.subtext)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(selected ? theme.surfaceSelected : theme.surface.opacity(hovered ? 0.9 : 0.5)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(selected ? theme.accent.opacity(0.75) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Add to Shelf") { onShelf(entry) }
        }
    }

    @ViewBuilder
    private var leading: some View {
        switch entry.previewKind {
        case let .color(color):
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(red: Double(color.red) / 255,
                            green: Double(color.green) / 255,
                            blue: Double(color.blue) / 255))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(theme.border.opacity(0.9), lineWidth: 1))
                .frame(width: 16, height: 16)
                .help("Colour \(color.hex)")
                .accessibilityLabel("Colour \(color.hex)")
        case let .image(url):
            ClipboardThumbnail(url: url)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .help(url.lastPathComponent)
        case .text:
            Image(systemName: "text.alignleft")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(selected ? theme.accent : theme.subtext)
        }
    }
}

/// A small thumbnail for a copied image path, loaded off the main thread and
/// cached. A missing or unreadable file keeps the photo placeholder.
private struct ClipboardThumbnail: View {
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            image = await ClipboardThumbnailLoader.shared.thumbnail(for: url)
        }
    }
}

/// One background task per path, a bounded cache, and no disk work on the main
/// thread: the clipboard panel can list a path on a slow volume.
actor ClipboardThumbnailLoader {
    static let shared = ClipboardThumbnailLoader()

    private var cache: [String: CGImage] = [:]
    private var unavailable = Set<String>()
    private var pending: [String: Task<CGImage?, Never>] = [:]
    private let limit = 32

    func thumbnail(for url: URL) async -> CGImage? {
        let key = url.standardizedFileURL.path
        if let cached = cache[key] { return cached }
        if unavailable.contains(key) { return nil }
        if let pending = pending[key] { return await pending.value }
        let task = Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 48,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary)
        }
        pending[key] = task
        let image = await task.value
        pending[key] = nil
        if let image {
            if cache.count >= limit { cache.removeAll(keepingCapacity: true) }
            cache[key] = image
        } else {
            unavailable.insert(key)
        }
        return image
    }
}
