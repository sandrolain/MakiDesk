import AppKit

@MainActor
final class BrowserActivationObserver {
    static let shared = BrowserActivationObserver()

    private var activationObserver: NSObjectProtocol?
    private var isBrowserFrontmost = false

    private init() {}

    func start() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.updateFrontmost(app)
            }
        }
        updateFrontmost(NSWorkspace.shared.frontmostApplication)
    }

    private func updateFrontmost(_ app: NSRunningApplication?) {
        let isBrowser = app?.bundleIdentifier == "com.makidesk.app.browser"
            || app?.executableURL?.lastPathComponent == "MakiDeskBrowser"
        guard isBrowser != isBrowserFrontmost else { return }
        isBrowserFrontmost = isBrowser
        WorkspaceStore.shared.setBrowserFrontmost(isBrowser)
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }
}
