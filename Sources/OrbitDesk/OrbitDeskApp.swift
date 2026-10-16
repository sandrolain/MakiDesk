import AppKit
import SwiftUI

@main
struct OrbitDeskApp: App {
    @State private var store = WorkspaceStore.shared

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        WorkspaceStore.shared.start()
        WindowDrag.shared.start()
        if !UserDefaults.standard.bool(forKey: "setupCompleted") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.sendAction(
                    Selector(("showSettingsWindow:")),
                    to: nil,
                    from: nil
                )
            }
        }
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
        MenuBarExtra("OrbitDesk", systemImage: "square.3.layers.3d") {
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
            Menu("Layout") {
                Button("Tile Windows") { store.tileOnScreen(gap: store.gap) }
                Button("Auto Layout (Golden Spiral)") { store.autoLayout() }
            }
            Divider()
            SettingsLink {
                Text("Settings")
            }
            Divider()
            Button("Quit OrbitDesk") {
                NSApplication.shared.terminate(nil)
            }
        }
        Settings {
            SettingsView(store: store)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .saveItem) {
                Button("Save Workspace") { store.save() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Reload Workspace") { store.load() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
