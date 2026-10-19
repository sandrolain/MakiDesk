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

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        WorkspaceStore.shared.start()
        WindowDrag.shared.start()
    }

    private func actionButton(
        _ title: String,
        _ keys: String,
        _ action: WindowController.ShortcutAction
    ) -> some View {
        Button("\(title)    \(keys)") {
            store.applyShortcut(action)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Text(store.status)
                .font(.caption)
            Divider()
            Menu("Resize (φ · ½ · φ⁻¹)") {
                actionButton("Left column", "⌃⌥←", .leftHalf)
                actionButton("Right column", "⌃⌥→", .rightHalf)
                actionButton("Top row", "⌃⌥↑", .topHalf)
                actionButton("Bottom row", "⌃⌥↓", .bottomHalf)
            }
            Menu("Quarters") {
                actionButton("Top Left", "⌃⌥U", .topLeft)
                actionButton("Top Right", "⌃⌥I", .topRight)
                actionButton("Bottom Left", "⌃⌥J", .bottomLeft)
                actionButton("Bottom Right", "⌃⌥K", .bottomRight)
            }
            Menu("Other") {
                actionButton("Center / Full / Golden", "⌃⌥↩", .centerCycle)
                actionButton("Center", "⌃⌥C", .center)
                actionButton("Golden Ratio (Phi)", "⌃⌥P", .phi)
                actionButton("Toggle Full Screen", "⌃⌥F", .toggleFullScreen)
                actionButton("Minimize", "⌃⌥M", .minimize)
            }
            Menu("Windows") {
                actionButton("Window Switcher", "⌥⇥", .switchWindows)
                actionButton("Search Windows", "⌥Space", .searchWindows)
            }
            Menu("Peek") {
                Button("Designate Front Window    ⌃⌥⌘P") {
                    store.togglePeekDesignation()
                }
                Button("Clear Peek (bring the window back)") {
                    store.clearPeek()
                }
                .disabled(store.peekName == nil)
                Divider()
                // The peek itself is a hold, not a menu action: this line only
                // says what the keys do and to which window (T16). Designating
                // puts the window away; the hold is the only way to see it.
                Text(store.peekName.map { "\($0) is put away · hold ⌃⌥H to peek at it" }
                     ?? "Hold ⌃⌥H to peek · nothing designated")
            }
            Menu("Groups") {
                ForEach(1...9, id: \.self) { slot in
                    Menu(store.groupMenuLabel(slot)) {
                        Button("Recall    ⌃⌥\(slot)") {
                            store.recallGroup(slot: slot)
                        }
                        .disabled(store.groupIsEmpty(slot))
                        // The moment the windows this group put away come back
                        // (T15); only offered for the group that is on screen.
                        Button("Leave group") {
                            store.leaveGroup()
                        }
                        .disabled(store.activeGroupSlot != slot)
                        Button("Add / Remove Front Window    ⌃⌥⌘\(slot)") {
                            store.toggleGroupMembership(slot: slot)
                        }
                        Divider()
                        Button("Rename…") {
                            GroupRenamePrompt.present(slot: slot, store: store)
                        }
                        Button("Empty Group") {
                            store.clearGroup(slot: slot)
                        }
                        .disabled(store.groupIsEmpty(slot))
                    }
                }
            }
            Menu("Focus") {
                // What is in use now, whatever put it there (T17): a group, or
                // a set assembled from the switcher.
                Text(store.sceneTitle.map { "In use: \($0)" } ?? "Nothing in use")
                Divider()
                Button("Focus Selected Windows") {
                    store.focus(on: store.lastLayoutSelection)
                }
                .disabled(store.lastLayoutSelection.isEmpty)
                Button("Send Front Window Away    ⌃⌥V") {
                    store.putAwayFrontWindow()
                }
                .disabled(store.sceneTitle == nil)
                Divider()
                Button("Everything Back    ⌃⌥⇧A") {
                    store.showEverything()
                }
                .disabled(store.sceneTitle == nil)
                Button("Undo One Step    ⌃⌥Z") {
                    store.undoScene()
                }
            }
            Menu("Layout") {
                Button("Grid — every window in view    ⌃⌥G") { store.tileOnScreen(gap: store.gap) }
                Button("Golden spiral — every window in view    ⌃⌥S") { store.autoLayout() }
                Button("Suggested layout    ⌃⌥A") { store.suggestLayout() }
                Divider()
                Button("Grid — selected windows") {
                    store.tileOnScreen(gap: store.gap, selection: store.lastLayoutSelection)
                }
                .disabled(store.lastLayoutSelection.isEmpty)
                Button("Golden spiral — selected windows") {
                    store.autoLayout(selection: store.lastLayoutSelection)
                }
                .disabled(store.lastLayoutSelection.isEmpty)
                Button("Suggested layout — selected windows") {
                    store.suggestLayout(selection: store.lastLayoutSelection)
                }
                .disabled(store.lastLayoutSelection.isEmpty)
                if let advice = store.pendingLayout {
                    Divider()
                    Button("Apply Suggested Layout (\(advice.layout.label))") {
                        store.acceptPendingLayout()
                    }
                    Button("Dismiss Suggested Layout") {
                        store.dismissPendingLayout()
                    }
                }
            }
            Divider()
            SettingsLink {
                Text("Settings")
            }
            Divider()
            Button("Quit MakiDesk") {
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
