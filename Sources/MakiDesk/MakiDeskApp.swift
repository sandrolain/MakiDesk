import AppKit
import SwiftUI

@main
struct MakiDeskApp: App {
    /// The migration from the app's previous name runs before the store reads
    /// its settings and its groups file.
    @State private var store: WorkspaceStore = {
        LegacyMigration.runIfNeeded()
        return WorkspaceStore.shared
    }()

    @NSApplicationDelegateAdaptor(MakiDeskAppDelegate.self) private var appDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        WorkspaceStore.shared.start()
        WindowDrag.shared.start()
        ClipboardHistory.shared.start()
        ShelfController.shared.start()

    }

    /// A menu item whose shortcut text sits after the title. The menu has no
    /// key equivalents of its own: the global Carbon hot key is the trigger,
    /// so the text is a reminder, not a second handler.
    private func menuAction(
        _ title: String,
        _ keys: String,
        _ action: WindowController.ShortcutAction,
        icon: String? = nil
    ) -> some View {
        Button {
            store.applyShortcut(action)
        } label: {
            if let icon {
                Label("\(title)    \(keys)", systemImage: icon)
            } else {
                Text("\(title)    \(keys)")
            }
        }
    }

    private func menuButton(
        _ title: String,
        keys: String? = nil,
        icon: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if let icon {
                if let keys {
                    Label("\(title)    \(keys)", systemImage: icon)
                } else {
                    Label(title, systemImage: icon)
                }
            } else if let keys {
                Text("\(title)    \(keys)")
            } else {
                Text(title)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Text(store.status)
                .font(.caption)
            Divider()

            // The four panels are one click away; everything else lives in a
            // menu with a single level of nesting.
            menuButton("Search Windows", keys: "⌥Space", icon: "magnifyingglass") {
                store.applyShortcut(.searchWindows)
            }
            menuButton("Notes", keys: "⌥N", icon: "note.text") {
                NotesController.shared.show()
            }
            menuButton("Clipboard History", keys: "⌥V", icon: "doc.on.clipboard") {
                ClipboardController.shared.toggle()
            }
            menuButton("Shelf", keys: "⌃⌥D", icon: "tray.and.arrow.down") {
                ShelfController.shared.toggle()
            }

            Divider()

            Menu {
                menuAction("Left column", "⌃⌥←", .leftHalf, icon: "rectangle.lefthalf.inset.filled")
                menuAction("Right column", "⌃⌥→", .rightHalf, icon: "rectangle.righthalf.inset.filled")
                menuAction("Top row", "⌃⌥↑", .topHalf, icon: "rectangle.tophalf.inset.filled")
                menuAction("Bottom row", "⌃⌥↓", .bottomHalf, icon: "rectangle.bottomhalf.inset.filled")
                Divider()
                menuAction("Top Left", "⌃⌥U", .topLeft)
                menuAction("Top Right", "⌃⌥I", .topRight)
                menuAction("Bottom Left", "⌃⌥J", .bottomLeft)
                menuAction("Bottom Right", "⌃⌥K", .bottomRight)
                Divider()
                menuAction("Center / Full / Golden", "⌃⌥↩", .centerCycle)
                menuAction("Center", "⌃⌥C", .center)
                menuAction("Golden Ratio (Phi)", "⌃⌥P", .phi)
                menuAction("Toggle Full Screen", "⌃⌥F", .toggleFullScreen)
                menuAction("Minimize", "⌃⌥M", .minimize)
            } label: {
                Label("Window", systemImage: "macwindow")
            }

            Menu {
                menuAction("Grid — every window in view", "⌃⌥G", .gridLayout)
                menuAction("Golden spiral — every window in view", "⌃⌥S", .spiralLayout)
                menuAction("Suggested layout", "⌃⌥A", .suggestLayout)
                menuAction("Content-weighted", "⌃⌥W", .contentLayout,
                           icon: "rectangle.3.group")
                Divider()
                menuButton("Grid — selected windows") {
                    store.tileOnScreen(gap: store.gap, selection: store.lastLayoutSelection)
                }
                .disabled(store.lastLayoutSelection.isEmpty)
                menuButton("Golden spiral — selected windows") {
                    store.autoLayout(selection: store.lastLayoutSelection)
                }
                .disabled(store.lastLayoutSelection.isEmpty)
                menuButton("Suggested layout — selected windows") {
                    store.suggestLayout(selection: store.lastLayoutSelection)
                }
                .disabled(store.lastLayoutSelection.isEmpty)
                menuButton("Content — selected windows") {
                    store.contentLayout(selection: store.lastLayoutSelection)
                }
                .disabled(store.lastLayoutSelection.count < 3)
                if let advice = store.pendingLayout {
                    Divider()
                    menuButton("Apply Suggested Layout (\(advice.layout.label))") {
                        store.acceptPendingLayout()
                    }
                    menuButton("Dismiss Suggested Layout") {
                        store.dismissPendingLayout()
                    }
                }
            } label: {
                Label("Layout", systemImage: "square.grid.2x2")
            }

            Menu {
                if let scene = store.sceneTitle {
                    Text("In use: \(scene)")
                    if store.activeGroupSlot != nil {
                        menuButton("Leave Group") { store.leaveGroup() }
                    }
                    Divider()
                }
                // One flat list to recall a group; three management submenus
                // replace the nine nested ones.
                ForEach(1...9, id: \.self) { slot in
                    menuButton(store.groupMenuLabel(slot), keys: "⌃⌥\(slot)") {
                        store.recallGroup(slot: slot)
                    }
                    .disabled(store.groupIsEmpty(slot))
                }
                Divider()
                Menu("Add Front Window to Group") {
                    ForEach(1...9, id: \.self) { slot in
                        menuButton(store.groupMenuLabel(slot), keys: "⌃⌥⌘\(slot)") {
                            store.toggleGroupMembership(slot: slot)
                        }
                    }
                }
                Menu("Rename Group…") {
                    ForEach(1...9, id: \.self) { slot in
                        menuButton(store.groupMenuLabel(slot)) {
                            GroupRenamePrompt.present(slot: slot, store: store)
                        }
                    }
                }
                Menu("Empty Group") {
                    ForEach(1...9, id: \.self) { slot in
                        menuButton(store.groupMenuLabel(slot)) {
                            store.clearGroup(slot: slot)
                        }
                        .disabled(store.groupIsEmpty(slot))
                    }
                }
            } label: {
                Label("Groups", systemImage: "rectangle.3.group")
            }

            Menu {
                Text(store.sceneTitle.map { "In use: \($0)" } ?? "Nothing in use")
                Divider()
                menuButton("Focus Selected Windows") {
                    store.focus(on: store.lastLayoutSelection)
                }
                .disabled(store.lastLayoutSelection.isEmpty)
                menuAction("Send Front Window Away", "⌃⌥V", .putAwayFront)
                Divider()
                menuAction("Everything Back", "⌃⌥⇧A", .showEverything)
                menuAction("Undo One Step", "⌃⌥Z", .undoStep)
            } label: {
                Label("Focus", systemImage: "scope")
            }

            Menu {
                menuButton("Designate Front Window", keys: "⌃⌥⌘P") {
                    store.togglePeekDesignation()
                }
                menuButton("Clear Peek (bring the window back)") {
                    store.clearPeek()
                }
                .disabled(store.peekName == nil)
                Divider()
                Text(store.peekName.map { "\($0) is put away · hold ⌃⌥H to peek at it" }
                     ?? "Hold ⌃⌥H to peek · nothing designated")
            } label: {
                Label("Peek", systemImage: "eye")
            }

            Divider()

            menuButton("Keyboard Shortcuts…", icon: "keyboard") {
                ShortcutsWindowController.shared.show()
            }
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            Divider()
            menuButton("Quit MakiDesk", icon: "power") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Image(nsImage: MenuBarIcon.image())
                .accessibilityLabel("MakiDesk")
                .modifier(SettingsOpenerBridge())
        }
        Settings {
            SettingsView(store: store)
        }
    }
}

/// Opens the Settings window on first launch and on demand. The status-item
/// label is the only SwiftUI view that is alive before the menu is opened, so it
/// is used to reach the `openSettings` environment action. The legacy
/// `sendAction(Selector(("showSettingsWindow:")))` does not work for an
/// accessory app without a main menu (it silently reaches no responder).
private struct SettingsOpenerBridge: ViewModifier {
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !SettingsOpenerBridge.didAttemptFirstRun else { return }
                guard !UserDefaults.standard.bool(forKey: "setupCompleted") else { return }
                SettingsOpenerBridge.didAttemptFirstRun = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    makiLog.notice("FirstRun: opening setup window")
                    openSettings()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .makiDeskOpenSettings)) { _ in
                openSettings()
            }
    }

    private static var didAttemptFirstRun = false
}

extension Notification.Name {
    /// Requests that the Settings window be opened (see `SettingsOpenerBridge`).
    static let makiDeskOpenSettings = Notification.Name("makiDeskOpenSettings")
}

/// Notes are written while the user types, but the session (tabs, cursors,
/// window frame) and the clean-close marker are flushed here, together with
/// any debounce still in flight (T20).
final class MakiDeskAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            NotesStore.shared.flushIfNeeded(cleanClose: true)
            ShelfController.shared.shutdown()
        }
    }
}
