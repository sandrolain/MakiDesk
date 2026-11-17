import AppKit
import MakiShared

/// The MakiDesk side of the browser helper. The browser is a separate regular
/// app, like Terminal and Docker, so its window is a normal window in the AX
/// inventory and survives MakiDesk's own process.
@MainActor
final class BrowserLauncher {
    static let shared = BrowserLauncher()

    private let appName = "MakiDeskBrowser.app"
    private let themeQueue = DispatchQueue(label: "com.makidesk.browser.theme", qos: .utility)
    private var themeRevision: UInt64 = 0
    private var pendingThemeWrite: (revision: UInt64, document: TerminalThemeDocument)?
    private var isThemeWriteInFlight = false
    private init() {}

    func open() {
        guard let url = helperURL() else {
            Confirmation.statement(
                title: "MakiDesk Browser is not installed",
                message: "Bundle the browser helper with “task browser:bundle”."
            ).tell(asSheetFor: NSApp.keyWindow)
            return
        }

        syncTheme()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url,
                                           configuration: configuration) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                Confirmation.statement(
                    title: "Could not open MakiDesk Browser",
                    message: error.localizedDescription
                ).tell(asSheetFor: NSApp.keyWindow)
            }
        }
    }

    func themeDidChange() {
        syncTheme()
    }

    func syncTheme() {
        themeRevision &+= 1
        pendingThemeWrite = (
            revision: themeRevision,
            document: TerminalThemeDocument(palette: WorkspaceStore.shared.theme)
        )
        writeNextThemeIfNeeded()
    }

    private func writeNextThemeIfNeeded() {
        guard !isThemeWriteInFlight, let pendingThemeWrite else { return }
        self.pendingThemeWrite = nil
        isThemeWriteInFlight = true

        let document = pendingThemeWrite.document
        let fileURL = StoredJSONFile.defaultURL(named: BrowserThemeSync.fileName)
        themeQueue.async { [weak self] in
            let saved = TerminalThemeStore(fileURL: fileURL).save(document)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isThemeWriteInFlight = false
                if saved {
                    if pendingThemeWrite.revision == self.themeRevision {
                        DistributedNotificationCenter.default().post(
                            name: BrowserThemeSync.didChangeNotification,
                            object: nil
                        )
                    }
                } else {
                    MakiLog.app.error(
                        "browser theme: save failed revision=\(pendingThemeWrite.revision, privacy: .public)"
                    )
                }
                self.writeNextThemeIfNeeded()
            }
        }
    }

    private func helperURL() -> URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Applications/\(appName)")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }

        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("dist/\(appName)")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        return nil
    }

}
