import AppKit

/// The one place a group is renamed from the menu. A menu item cannot hold a
/// text field, so this is a small modal prompt: no extra window to keep alive and
/// no state to outlive the call. An empty field clears the custom name, which is
/// the only way back to "Group N".
enum GroupRenamePrompt {
    static func present(slot: Int, store: WorkspaceStore) {
        let alert = NSAlert()
        alert.messageText = "Rename \(store.groupName(slot))"
        alert.informativeText = "Leave the field empty to go back to “Group \(slot)”."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = store.groups[slot]?.name ?? ""
        field.placeholderString = "Group \(slot)"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        // The app has no dock icon and is usually in the background, so make sure
        // the prompt lands in front of the user rather than behind everything.
        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            store.renameGroup(slot: slot, name: field.stringValue)
        }
    }
}
