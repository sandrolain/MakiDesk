import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Catalogue

struct ShortcutItem: Identifiable {
    let title: String
    let keys: String
    var note: String?
    /// Stable id for generated global rows (T53); local rows fall back to the
    /// title and key text.
    var identifier: String? = nil
    /// A global row can be recorded, turned off and restored (T53).
    var isRemappable: Bool = false
    var isModified: Bool = false
    var isDisabled: Bool = false
    var isBlocked: Bool = false

    var id: String { identifier ?? "\(title)|\(keys)" }
}

struct ShortcutSection: Identifiable {
    let title: String
    let scope: String
    let items: [ShortcutItem]
    var note: String?

    var id: String { title }
}

/// Every key the app answers to, grouped by where it works. Kept as plain
/// data so the list can be searched and checked without touching the views.
enum ShortcutCatalog {
    /// The global sections are generated from `ShortcutDefinitions` and the
    /// table in force; only the in-panel rows are written here, because they
    /// are not Carbon hot keys (T53).
    static func sections(bindings: ShortcutBindings = .defaults,
                         blocked: Set<String> = []) -> [ShortcutSection] {
        var result: [ShortcutSection] = []
        for section in ShortcutDefinitions.sections {
            let items = section.definitions.map { definition -> ShortcutItem in
                let global = definition.isGlobal
                let disabled = global && bindings.isDisabled(definition.id)
                let isBlocked = global && blocked.contains(definition.id)
                var note = definition.note
                if isBlocked { note = inUseNote(note) }
                if disabled { note = offNote(note) }
                return ShortcutItem(
                    title: definition.title,
                    keys: disabled ? "Off" : (bindings.display(for: definition.id) ?? definition.display),
                    note: note,
                    identifier: definition.id,
                    isRemappable: global,
                    isModified: global && bindings.isModified(definition.id),
                    isDisabled: disabled,
                    isBlocked: isBlocked
                )
            }
            result.append(ShortcutSection(title: section.title, scope: "Global",
                                          items: items, note: section.note))
        }
        result.append(contentsOf: localSections)
        return result
    }

    private static func inUseNote(_ note: String?) -> String {
        let base = "In use by another app: use the menu instead."
        return note.map { "\(base) \($0)" } ?? base
    }

    private static func offNote(_ note: String?) -> String {
        let base = "Turned off: record a combination to turn it back on."
        return note.map { "\(base) \($0)" } ?? base
    }

    private static let localSections: [ShortcutSection] = [
        ShortcutSection(title: "Window switcher and search", scope: "Palette open", items: [
            .init(title: "Move the highlight", keys: "↑ ↓ ← →"),
            .init(title: "Open the highlighted window", keys: "↩",
                  note: "Releasing ⌥ opens it too. With a group selected in the column, Return recalls it (⌘↩ while searching)."),
            .init(title: "Turn the switcher into a search", keys: "Space"),
            .init(title: "Step into / out of the applications shelf", keys: "↑ ↓",
                  note: "While searching: ↑ from the first window row enters the shelf, ↓ returns to the windows; ←/→ choose an application."),
            .init(title: "Launch the highlighted application", keys: "↩",
                  note: "While the applications shelf has the highlight."),
            .init(title: "Close the palette", keys: "Esc",
                  note: "In the group column, Esc leaves the group first."),
            .init(title: "Pick a group from the column", keys: "⌘1…9"),
            .init(title: "Add / remove the highlighted card", keys: "⌥1…9",
                  note: "Builds the group being edited, while browsing."),
            .init(title: "Close the highlighted window", keys: "⌥Q"),
            .init(title: "Quit the highlighted app", keys: "⌥⇧Q"),
            .init(title: "Minimize the highlighted window", keys: "⌥M"),
            .init(title: "Reset the selected group", keys: "⌫"),
        ], note: "While searching, typing filters and the group keys need ⌘."),

        ShortcutSection(title: "Notes", scope: "Panel focused", items: [
            .init(title: "Save the note", keys: "⌘S"),
            .init(title: "Save As…", keys: "⇧⌘S"),
            .init(title: "Close the note", keys: "⌘W",
                  note: "The draft goes to the Trash; an external file is untouched."),
            .init(title: "New note", keys: "⌘T"),
            .init(title: "Find in the note", keys: "⌘F"),
            .init(title: "Open a file as a note", keys: "⌘O"),
            .init(title: "Switch to note 1…9", keys: "⌘1…9"),
            .init(title: "Larger / smaller text", keys: "⌘+ / ⌘−"),
            .init(title: "Close the panel", keys: "Esc"),
        ], note: "⌥N opens the panel from anywhere."),

        ShortcutSection(title: "Clipboard", scope: "Panel focused", items: [
            .init(title: "Move the selection", keys: "↑ ↓",
                  note: "Page ↑/↓, Home and End work too."),
            .init(title: "Paste the selected text", keys: "↩"),
            .init(title: "Paste a row", keys: "Click"),
            .init(title: "Close the panel", keys: "Esc"),
        ], note: "⌥V opens it from anywhere; nothing is written to disk."),

        ShortcutSection(title: "Shelf", scope: "Shelf open", items: [
            .init(title: "Quick Look the selected item", keys: "Space"),
            .init(title: "Remove the selected items", keys: "⌫"),
            .init(title: "Close the shelf", keys: "Esc",
                  note: "The shelf empties when it closes."),
            .init(title: "Select every item", keys: "⌘A",
                  note: "Then drag any row to take them all, or use “Drag all out”."),
        ], note: "⌃⌥D opens it from anywhere; shaking during a drag does too."),

        ShortcutSection(title: "Dropzones", scope: "Shelf open", items: [
            .init(title: "Show the dropzone strip for the selection", keys: "⌘D",
                  note: "The menu bar has the same zones under Dropzones; each one runs on the selected items."),
            .init(title: "Choose between dropzone tiles", keys: "← →",
                  note: "The highlighted tile is the one Return runs."),
            .init(title: "Run the highlighted dropzone", keys: "↩",
                  note: "Same confirmation and payload as dropping on the tile."),
            .init(title: "Back to the shelf list", keys: "↑"),
        ], note: "Or drag items onto a tile while the strip is visible."),
    ]
}

// MARK: - Window

@MainActor
final class ShortcutsWindowController {
    static let shared = ShortcutsWindowController()

    private var window: NSWindow?
    private var themeObserver: NSObjectProtocol?

    private init() {
        themeObserver = NotificationCenter.default.addObserver(
            forName: .makiDeskThemeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyWindowTheme() }
        }
    }

    func show() {
        if window == nil { build() }
        applyWindowTheme()
        if let window, window.isVisible == false {
            UtilityWindowPlacement.placeOnFocusedScreen(window)
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let theme = WorkspaceStore.shared.theme
        let hosting = NSHostingController(rootView: ShortcutsView(store: WorkspaceStore.shared))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Keyboard Shortcuts"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(theme.background)
        window.isOpaque = true
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 720, height: 780))
        window.minSize = NSSize(width: 560, height: 480)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        if window.setFrameAutosaveName("MakiDeskKeyboardShortcuts") == false {
            window.center()
        }
        self.window = window
    }

    private func applyWindowTheme() {
        window?.backgroundColor = NSColor(WorkspaceStore.shared.theme.background)
    }
}

// MARK: - View

struct ShortcutsView: View {
    @Bindable var store: WorkspaceStore
    @State private var query = ""
    @State private var recordingID: String?
    @State private var recordingTitle: String?
    @State private var message: String?
    @State private var keyMonitor: Any?
    @FocusState private var searchFocused: Bool

    private var theme: PaletteTheme { store.theme }

    private var catalogSections: [ShortcutSection] {
        ShortcutCatalog.sections(bindings: store.shortcutBindings,
                                 blocked: store.blockedShortcutIDs)
    }

    private var total: Int {
        catalogSections.reduce(0) { $0 + $1.items.count }
    }

    private var filtered: [ShortcutSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.isEmpty == false else { return catalogSections }
        return catalogSections.compactMap { section in
            let items = section.items.filter { item in
                item.title.localizedCaseInsensitiveContains(needle)
                    || item.keys.localizedCaseInsensitiveContains(needle)
                    || spaced(item.keys).localizedCaseInsensitiveContains(needle)
                    || (item.note?.localizedCaseInsensitiveContains(needle) ?? false)
            }
            guard items.isEmpty == false else { return nil }
            return ShortcutSection(title: section.title, scope: section.scope,
                                   items: items, note: section.note)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(theme.border.opacity(0.7))
                .frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(filtered) { section in
                        sectionView(section)
                    }
                    if filtered.isEmpty {
                        empty
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(theme.background)
        .onAppear { searchFocused = true }
        .onDisappear { stopRecording() }
        // A recorder left running while the window is in the background would
        // swallow the next keys typed elsewhere.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            stopRecording()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.accent)
                Text("Keyboard Shortcuts")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.text)
                Spacer()
                if store.shortcutBindings.modifiedCount > 0 {
                    Button("Restore all") {
                        apply(store.restoreAllShortcuts())
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .help("Put every shortcut back to its default")
                }
                Text("\(total) commands")
                    .font(.caption)
                    .foregroundStyle(theme.subtext)
            }
            Text("⌥ opens a panel · ⌃⌥ acts on windows and the desktop · click a key to change it")
                .font(.caption)
                .foregroundStyle(theme.subtext)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.subtext)
                TextField("", text: $query,
                          prompt: Text("Search by command or key").foregroundColor(theme.subtext))
                    .textFieldStyle(.plain)
                    .foregroundStyle(theme.text)
                    .tint(theme.accent)
                    .focused($searchFocused)
                    .disabled(recordingID != nil)
                if query.isEmpty == false {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(theme.subtext)
                    }
                    .buttonStyle(.plain)
                    .help("Clear the search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(searchFocused ? theme.accent.opacity(0.8) : theme.border, lineWidth: 1))

            if let recordingTitle {
                Text("Press the new combination for “\(recordingTitle)” · Esc cancels · ⌫ turns it off")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Global shortcuts work from any app. The other sections work while that panel has the keyboard.")
                    .font(.caption)
                    .foregroundStyle(theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let warning = fileWarning {
                Text(warning)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 44)
        .padding(.bottom, 14)
    }

    private var fileWarning: String? {
        switch store.shortcutFileState {
        case .missing, .loaded:
            return nil
        case .corrupt:
            return "The shortcuts file could not be read; it was set aside and the defaults are in use."
        case let .futureVersion(version):
            return "The shortcuts file was written by a newer MakiDesk (version \(version)); it is read-only and the defaults are in use."
        }
    }

    private func sectionView(_ section: ShortcutSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(section.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text(section.scope)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(theme.subtext)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.surface))
                Spacer()
            }

            VStack(spacing: 0) {
                ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                    row(item)
                    if index < section.items.count - 1 {
                        Rectangle()
                            .fill(theme.border.opacity(0.45))
                            .frame(height: 1)
                            .padding(.leading, 12)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.surface.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(theme.border.opacity(0.6), lineWidth: 1))

            if let note = section.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ item: ShortcutItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.text)
                if let note = item.note {
                    Text(note)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 20)
            if item.isRemappable, let identifier = item.identifier {
                if item.isModified {
                    Button {
                        apply(store.restoreShortcut(identifier))
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(theme.subtext)
                    }
                    .buttonStyle(.plain)
                    .help("Restore the default shortcut")
                    .accessibilityLabel("Restore the default shortcut for \(item.title)")
                }
                keyButton(item)
                menuButton(item)
            } else {
                keyLabel(item.keys)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func keyButton(_ item: ShortcutItem) -> some View {
        let recording = recordingID != nil && recordingID == item.identifier
        let tint = item.isBlocked ? Color.orange
            : item.isDisabled ? theme.subtext
            : recording ? theme.accent : theme.text
        return Button {
            recording ? stopRecording() : startRecording(item)
        } label: {
            Text(recording ? "Press keys…" : spaced(item.keys))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(recording ? theme.accent : theme.border, lineWidth: 1))
                .fixedSize()
        }
        .buttonStyle(.plain)
        .help("Click, then press the new combination")
        .accessibilityLabel("\(item.title), \(item.keys). Change shortcut")
    }

    private func menuButton(_ item: ShortcutItem) -> some View {
        Menu {
            Button("Record new shortcut…") { startRecording(item) }
            if item.isDisabled {
                Button("Turn on (default)") {
                    if let id = item.identifier { apply(store.restoreShortcut(id)) }
                }
            } else {
                Button("Turn off") {
                    if let id = item.identifier { apply(store.disableShortcut(id)) }
                }
            }
            Button("Restore default") {
                if let id = item.identifier { apply(store.restoreShortcut(id)) }
            }
            .disabled(item.isModified == false)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 11))
                .foregroundStyle(theme.subtext)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More options for \(item.title)")
    }

    private func keyLabel(_ keys: String) -> some View {
        Text(spaced(keys))
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(theme.text)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(theme.border, lineWidth: 1))
            .textSelection(.enabled)
    }

    // MARK: - Recording (T53)

    private func startRecording(_ item: ShortcutItem) {
        guard let id = item.identifier else { return }
        stopRecording()
        message = nil
        recordingID = id
        recordingTitle = item.title
        searchFocused = false
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            MainActor.assumeIsolated {
                handle(event, id: id)
            }
            // Swallow the keys while recording: they are a combination, not
            // text for the search field or a command.
            return nil
        }
    }

    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recordingID = nil
        recordingTitle = nil
    }

    private func handle(_ event: NSEvent, id: String) {
        let modifiers = ShortcutBinding.carbonModifiers(from: event.modifierFlags)
        if event.keyCode == UInt16(kVK_Escape), modifiers == 0 {
            stopRecording()
            return
        }
        if event.keyCode == UInt16(kVK_Delete), modifiers == 0 {
            apply(store.disableShortcut(id))
            stopRecording()
            return
        }
        let binding = ShortcutBinding(keyCode: Int(event.keyCode), modifiers: modifiers)
        let result = store.setShortcut(binding, for: id)
        if result.error == nil {
            stopRecording()
        } else {
            apply(result)
        }
    }

    private func apply(_ result: ShortcutEditResult) {
        if let error = result.error {
            message = error.message
        } else {
            message = nil
        }
    }

    /// `⌃⌥←` reads as `⌃ ⌥ ←`: the glyphs have almost no side bearing and
    /// would otherwise sit on top of each other.
    private func spaced(_ keys: String) -> String {
        var result = ""
        for character in keys {
            result.append(character)
            if "⌃⌥⌘⇧".contains(character) { result.append(" ") }
        }
        return result
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "keyboard")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(theme.subtext)
            Text("No shortcut matches “\(query)”")
                .font(.system(size: 12.5))
                .foregroundStyle(theme.text)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}
