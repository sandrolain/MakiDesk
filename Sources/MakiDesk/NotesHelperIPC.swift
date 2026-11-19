import AppKit
import MakiShared

enum NotesHelperIdentity {
    static let bundleIdentifier = "com.makidesk.app.notes"
    static let hostBundleIdentifier = "com.makidesk.app"
    static let executableName = "MakiDeskNotes"
    static let bundleName = "MakiDeskNotes.app"
    static let requestsDirectory = StoredJSONFile.defaultURL(named: "notes-requests").deletingLastPathComponent()
        .appendingPathComponent("notes-requests", isDirectory: true)
    static let themeURL = StoredJSONFile.defaultURL(named: "notes-theme.json")
    static let requestNotification = Notification.Name("com.makidesk.notes.requestAvailable")
    static let themeNotification = Notification.Name("com.makidesk.notes.themeChanged")
}

enum NotesPreferences {
    static let defaults = UserDefaults(suiteName: NotesHelperIdentity.hostBundleIdentifier) ?? .standard
}

fileprivate enum NotesHelperRequestKind: String, Codable {
    case show
    case insertText
    case addNote
    case deleteAllNotes
}

fileprivate struct NotesHelperRequest: Codable {
    let id: UUID
    let kind: NotesHelperRequestKind
    let text: String?
}

private struct NotesHelperTheme: Codable {
    let themeID: String
}

enum NotesHelperIPC {
    static func enqueueShow() { enqueue(kind: .show) }

    static func enqueueInsertText(_ text: String) {
        guard text.utf8.count <= 1_000_000 else { return }
        enqueue(kind: .insertText, text: text)
    }

    static func enqueueNewNote(_ text: String) {
        guard text.utf8.count <= 1_000_000 else { return }
        enqueue(kind: .addNote, text: text)
    }

    static func enqueueDeleteAllNotes() { enqueue(kind: .deleteAllNotes) }

    private static func enqueue(kind: NotesHelperRequestKind, text: String? = nil) {
        let request = NotesHelperRequest(id: UUID(), kind: kind, text: text)
        guard let data = try? StoredJSONFile.encoder().encode(request) else { return }
        do {
            try FileManager.default.createDirectory(at: NotesHelperIdentity.requestsDirectory,
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: NotesHelperIdentity.requestsDirectory.path)
            let pending = (try? FileManager.default.contentsOfDirectory(
                at: NotesHelperIdentity.requestsDirectory,
                includingPropertiesForKeys: nil
            ))?.filter { $0.pathExtension == "json" }.count ?? 0
            guard pending < 100 else { return }
            let name = String(format: "%020.0f-%@.json",
                              Date.timeIntervalSinceReferenceDate * 1_000_000,
                              request.id.uuidString)
            let requestURL = NotesHelperIdentity.requestsDirectory.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: requestURL.path, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            DistributedNotificationCenter.default().post(name: NotesHelperIdentity.requestNotification,
                                                          object: nil)
        } catch {
            MakiLog.app.error("notes helper request write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    fileprivate static func firstPendingRequest() -> (URL, NotesHelperRequest)? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: NotesHelperIdentity.requestsDirectory,
            includingPropertiesForKeys: nil
        ) else { return nil }
        for url in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: url),
                  let request = try? StoredJSONFile.decoder().decode(NotesHelperRequest.self, from: data) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            return (url, request)
        }
        return nil
    }

    static func removeRequest(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func writeTheme(id: String) {
        guard let data = try? StoredJSONFile.encoder().encode(NotesHelperTheme(themeID: id)) else { return }
        do {
            try StoredJSONFile.write(data, to: NotesHelperIdentity.themeURL)
            DistributedNotificationCenter.default().post(name: NotesHelperIdentity.themeNotification,
                                                          object: nil)
        } catch {
            MakiLog.app.error("notes helper theme write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func themeID(fallback: String? = nil) -> String? {
        guard let data = try? Data(contentsOf: NotesHelperIdentity.themeURL),
              let theme = try? StoredJSONFile.decoder().decode(NotesHelperTheme.self, from: data) else {
            return fallback
        }
        return theme.themeID
    }
}

@MainActor
final class NotesHelperLauncher {
    static let shared = NotesHelperLauncher()

    private let ioQueue = DispatchQueue(label: "com.makidesk.notes-helper-requests", qos: .utility)
    private init() {}

    var isFrontmost: Bool {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.bundleIdentifier == NotesHelperIdentity.bundleIdentifier
            || app?.executableURL?.lastPathComponent == NotesHelperIdentity.executableName
    }

    func open() {
        enqueueAndOpen { NotesHelperIPC.enqueueShow() }
    }

    func insertText(_ text: String) {
        enqueueAndOpen { NotesHelperIPC.enqueueInsertText(text) }
    }

    func addNote(text: String) {
        enqueueAndOpen { NotesHelperIPC.enqueueNewNote(text) }
    }

    func deleteAllNotes() {
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: NotesHelperIdentity.bundleIdentifier
        ).first
        if running != nil {
            ioQueue.async { NotesHelperIPC.enqueueDeleteAllNotes() }
        } else {
            NotesStore.shared.deleteAllNotes()
        }
    }

    func themeDidChange() {
        let themeID = WorkspaceStore.shared.theme.id
        ioQueue.async { NotesHelperIPC.writeTheme(id: themeID) }
    }

    private func enqueueAndOpen(_ enqueue: @escaping () -> Void) {
        guard let url = helperURL() else {
            Confirmation.statement(
                title: "MakiDesk Notes is not installed",
                message: "Bundle the Notes helper with “task notes:bundle”."
            ).tell(asSheetFor: NSApp.keyWindow)
            return
        }
        ioQueue.async { [weak self] in
            enqueue()
            DispatchQueue.main.async { [weak self] in
                self?.launch(url)
            }
        }
    }

    private func launch(_ url: URL) {
        if let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: NotesHelperIdentity.bundleIdentifier
        ).first {
            _ = running.activate(options: [.activateAllWindows])
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                Confirmation.statement(title: "Could not open MakiDesk Notes",
                                       message: error.localizedDescription)
                    .tell(asSheetFor: NSApp.keyWindow)
            }
        }
    }

    private func helperURL() -> URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Applications/\(NotesHelperIdentity.bundleName)")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }

        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("dist/\(NotesHelperIdentity.bundleName)")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        return nil
    }
}

@MainActor
final class NotesHelperRequestService {
    static let shared = NotesHelperRequestService()

    private let ioQueue = DispatchQueue(label: "com.makidesk.notes-helper-reader", qos: .userInitiated)
    private var observer: NSObjectProtocol?
    private var isReading = false
    private var shouldReadAgain = false

    private init() {}

    func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NotesHelperIdentity.requestNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.drain() }
        }
        drain()
    }

    func shutdown() {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
            self.observer = nil
        }
    }

    private func drain() {
        guard isReading == false else {
            shouldReadAgain = true
            return
        }
        isReading = true
        readNext()
    }

    private func readNext() {
        ioQueue.async { [weak self] in
            let pending = NotesHelperIPC.firstPendingRequest()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard let (url, request) = pending else {
                        self.isReading = false
                        if self.shouldReadAgain {
                            self.shouldReadAgain = false
                            self.drain()
                        }
                        return
                    }
                    self.handle(request)
                    self.ioQueue.async {
                        NotesHelperIPC.removeRequest(at: url)
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { self.readNext() }
                        }
                    }
                }
            }
        }
    }

    private func handle(_ request: NotesHelperRequest) {
        switch request.kind {
        case .show:
            NotesController.shared.show()
        case .insertText:
            if let text = request.text { NotesController.shared.insertText(text) }
        case .addNote:
            if let text = request.text { NotesController.shared.addNote(text: text) }
        case .deleteAllNotes:
            NotesController.shared.deleteAllNotes()
        }
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }
}
