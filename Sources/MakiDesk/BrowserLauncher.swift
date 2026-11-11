import AppKit

/// The MakiDesk side of the browser helper. The browser is a separate regular
/// app, like Terminal and Docker, so its window is a normal window in the AX
/// inventory and survives MakiDesk's own process.
@MainActor
final class BrowserLauncher {
    static let shared = BrowserLauncher()

    private let appName = "MakiDeskBrowser.app"
    private init() {}

    func open() {
        guard let url = helperURL() else {
            Confirmation.statement(
                title: "MakiDesk Browser is not installed",
                message: "Bundle the browser helper with “task browser:bundle”."
            ).tell(asSheetFor: NSApp.keyWindow)
            return
        }

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
