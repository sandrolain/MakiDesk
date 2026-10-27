import AppKit
import SwiftUI

// MARK: - Catalogue

struct ShortcutItem: Identifiable {
    let title: String
    let keys: String
    var note: String?
    /// Stable id for generated global rows (T53); local rows fall back to the
    /// title and key text.
    var identifier: String? = nil

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
    /// The global sections are generated from `ShortcutDefinitions`; only the
    /// in-panel rows are written here, because they are not Carbon hot keys.
    static func sections(blocked: Set<String> = []) -> [ShortcutSection] {
        var result: [ShortcutSection] = []
        for section in ShortcutDefinitions.sections {
            let items = section.definitions.map { definition in
                ShortcutItem(
                    title: definition.title,
                    keys: definition.display,
                    note: blocked.contains(definition.id)
                        ? inUseNote(definition.note) : definition.note,
                    identifier: definition.id
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
    @FocusState private var searchFocused: Bool

    private var theme: PaletteTheme { store.theme }

    private var catalogSections: [ShortcutSection] {
        ShortcutCatalog.sections(blocked: store.blockedShortcutIDs)
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
                Text("\(total) commands")
                    .font(.caption)
                    .foregroundStyle(theme.subtext)
            }
            Text("⌥ opens a panel · ⌃⌥ acts on windows and the desktop")
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

            Text("Global shortcuts work from any app. The other sections work while that panel has the keyboard.")
                .font(.caption)
                .foregroundStyle(theme.subtext)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 44)
        .padding(.bottom, 14)
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
        HStack(alignment: .firstTextBaseline, spacing: 16) {
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
            Text(spaced(item.keys))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(theme.border, lineWidth: 1))
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
