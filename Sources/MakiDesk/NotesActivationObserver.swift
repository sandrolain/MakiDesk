import AppKit

@MainActor
final class NotesActivationObserver {
    static let shared = NotesActivationObserver()

    private var activationObserver: NSObjectProtocol?
    private var isNotesFrontmost = false

    private init() {}

    func start() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.updateFrontmost(app) }
        }
        updateFrontmost(NSWorkspace.shared.frontmostApplication)
    }

    private func updateFrontmost(_ app: NSRunningApplication?) {
        let isNotes = app?.bundleIdentifier == NotesHelperIdentity.bundleIdentifier
            || app?.executableURL?.lastPathComponent == NotesHelperIdentity.executableName
        guard isNotes != isNotesFrontmost else { return }
        isNotesFrontmost = isNotes
        WorkspaceStore.shared.setNotesFrontmost(isNotes)
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }
}
