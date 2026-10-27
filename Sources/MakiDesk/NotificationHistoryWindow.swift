import AppKit
import SwiftUI

/// The in-memory notification history (T52): search, copy, clear. Like the
/// keyboard-shortcuts window, it is a small themed utility window.
@MainActor
final class NotificationHistoryController {
    static let shared = NotificationHistoryController()

    private var window: NSWindow?
    private var themeObserver: NSObjectProtocol?

    private init() {
        themeObserver = NotificationCenter.default.addObserver(
            forName: .makiDeskThemeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.window?.backgroundColor = NSColor(WorkspaceStore.shared.theme.background)
            }
        }
    }

    func show() {
        if window == nil { build() }
        if let window, window.isVisible == false {
            UtilityWindowPlacement.placeOnFocusedScreen(window)
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let theme = WorkspaceStore.shared.theme
        let hosting = NSHostingController(rootView: NotificationHistoryView(
            hud: HUDController.shared,
            store: WorkspaceStore.shared,
            onClose: { [weak self] in self?.window?.close() }
        ))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Notifications"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(theme.background)
        window.isOpaque = true
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 640, height: 560))
        window.minSize = NSSize(width: 480, height: 360)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        if window.setFrameAutosaveName("MakiDeskNotificationHistory") == false {
            window.center()
        }
        self.window = window
    }
}

// MARK: - View

struct NotificationHistoryView: View {
    @Bindable var hud: HUDController
    @Bindable var store: WorkspaceStore
    let onClose: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var searchFocused: Bool
    @State private var selectedID: UUID?

    private var theme: PaletteTheme { store.theme }

    private var filtered: [HUDNotice] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.isEmpty == false else { return hud.history }
        return hud.history.filter { notice in
            notice.text.localizedCaseInsensitiveContains(needle)
                || (notice.detail?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    private var current: HUDNotice? {
        if let selectedID, let match = filtered.first(where: { $0.id == selectedID }) {
            return match
        }
        return filtered.indices.contains(selection) ? filtered[selection] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(theme.border.opacity(0.7))
                .frame(height: 1)
            if filtered.isEmpty {
                empty
            } else {
                list
            }
            Rectangle()
                .fill(theme.border.opacity(0.7))
                .frame(height: 1)
            footer
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(theme.background)
        .onAppear { searchFocused = true }
        .onChange(of: hud.history) { _, _ in clampSelection() }
        .onChange(of: query) { _, _ in clampSelection() }
        .onMoveCommand { direction in
            switch direction {
            case .up: move(by: -1)
            case .down: move(by: 1)
            default: break
            }
        }
        .onKeyPress(.return) {
            // The search field submits on its own; this covers the list focus.
            guard searchFocused == false else { return .ignored }
            copyCurrent()
            return .handled
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bell")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.accent)
                Text("Notifications")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.text)
                Spacer()
                Text(hud.history.count == 1 ? "1 item" : "\(hud.history.count) items")
                    .font(.caption)
                    .foregroundStyle(theme.subtext)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.subtext)
                TextField("Search notifications", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                    .onSubmit { copyCurrent() }
                if query.isEmpty == false {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.subtext)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(theme.border.opacity(0.7), lineWidth: 1))
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, notice in
                        NotificationHistoryRow(notice: notice,
                                               selected: isSelected(notice, index: index),
                                               theme: theme)
                            .id(notice.id)
                            .onTapGesture {
                                selection = index
                                selectedID = notice.id
                            }
                            .onTapGesture(count: 2) {
                                selectedID = notice.id
                                copy(notice)
                            }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell.slash")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(theme.subtext)
            Text(query.isEmpty ? "No notifications yet" : "No matching notifications")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.text)
            Text(query.isEmpty
                 ? "Notices appear here while MakiDesk is open; nothing is saved to disk."
                 : "Try another word or clear the search.")
                .font(.system(size: 11))
                .foregroundStyle(theme.subtext)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            hint("↩", "copy")
            hint("↑↓", "move")
            hint("esc", "close")
            Spacer()
            Text("In memory only")
                .font(.system(size: 10))
                .foregroundStyle(theme.subtext.opacity(0.8))
            Button("Clear") { hud.clearHistory() }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(hud.history.isEmpty ? theme.subtext.opacity(0.4) : theme.subtext)
                .disabled(hud.history.isEmpty)
            Button("Copy") { copyCurrent() }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(current == nil ? theme.subtext.opacity(0.4) : theme.text)
                .disabled(current == nil)
            Button("Close") { onClose() }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.subtext)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(theme.border.opacity(0.7), lineWidth: 1))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(theme.subtext)
        }
    }

    private func isSelected(_ notice: HUDNotice, index: Int) -> Bool {
        if let selectedID { return notice.id == selectedID }
        return index == selection
    }

    private func move(by delta: Int) {
        guard filtered.isEmpty == false else { return }
        let index: Int
        if let id = current?.id,
           let found = filtered.firstIndex(where: { $0.id == id }) {
            index = found
        } else {
            index = 0
        }
        let next = min(max(0, index + delta), filtered.count - 1)
        selection = next
        selectedID = filtered[next].id
    }

    private func clampSelection() {
        if let selectedID, filtered.contains(where: { $0.id == selectedID }) { return }
        selectedID = nil
        selection = min(max(0, selection), max(0, filtered.count - 1))
    }

    private func copyCurrent() {
        guard let current else { return }
        copy(current)
    }

    private func copy(_ notice: HUDNotice) {
        let text = [notice.text, notice.detail].compactMap { $0 }
            .filter { $0.isEmpty == false }
            .joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return }
        hud.show("Notification copied", symbol: "doc.on.clipboard")
    }
}

private struct NotificationHistoryRow: View {
    let notice: HUDNotice
    let selected: Bool
    let theme: PaletteTheme

    private var tint: Color {
        switch notice.kind {
        case .confirmation, .progress: return theme.accent
        case .warning: return .orange
        case .error: return .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.text)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                if let detail = notice.detail, detail.isEmpty == false {
                    Text(detail)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.subtext)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                Text(notice.date.formatted(date: .abbreviated, time: .standard))
                    .font(.system(size: 9.5))
                    .foregroundStyle(theme.subtext.opacity(0.8))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(selected ? theme.surfaceSelected : theme.surface.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(selected ? theme.accent.opacity(0.75) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(notice.kind.label)
        .accessibilityValue([notice.text, notice.detail].compactMap { $0 }.joined(separator: ". "))
    }
}
