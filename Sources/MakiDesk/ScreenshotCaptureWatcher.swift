import AppKit
import Carbon.HIToolbox
import Foundation

/// Announces a screenshot macOS has just saved (T48).
///
/// One FSEvents stream, alive only while the option is on. The first scan is a
/// baseline, so the captures already in the folder are never announced, and a
/// file older than a few seconds is left alone too: what is announced is the
/// capture that just landed, addressed by name.
///
/// The notice is opt-in and stays silent while secure input has the keyboard:
/// a password being typed is not the moment for a banner.
@MainActor
final class ScreenshotCaptureWatcher {
    static let shared = ScreenshotCaptureWatcher()

    /// The rule, kept apart from the stream so it can be checked without one.
    enum Policy {
        /// How old a file may be and still count as "just saved".
        static let maximumAge: TimeInterval = 8

        static func shouldAnnounce(enabled: Bool, secureInput: Bool, isImage: Bool,
                                   age: TimeInterval) -> Bool {
            enabled && secureInput == false && isImage && age >= 0 && age <= maximumAge
        }
    }

    private var watcher: ScreenshotFolderWatcher?
    private var folder: URL?
    /// The captures that were there at the baseline and on the last scan.
    private var known: Set<String> = []
    private var work: DispatchWorkItem?
    private let queue = DispatchQueue(label: "MakiDesk.capture-watch", qos: .utility)
    private var scanning = false
    private var pending = false
    private var secureInput: () -> Bool = { IsSecureEventInputEnabled() }

    private init() {}

    /// Follows the setting: a watcher exists only while notices are wanted.
    func applySettings() {
        guard WorkspaceStore.shared.screenshotSavedNotice else {
            stop()
            return
        }
        start()
    }

    func start() {
        let target = folderToWatch()
        if watcher != nil, folder?.path == target.path { return }
        stop()
        folder = target
        known.removeAll()
        // Baseline: what is already there is not news.
        scan(announce: false)
        let watcher = ScreenshotFolderWatcher { [weak self] flags in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                    // The folder was replaced: reopen the stream and forget the
                    // baseline, since the new one may hold anything.
                    self.restart()
                    return
                }
                self.scheduleScan()
            }
        }
        watcher.start(folder: target)
        self.watcher = watcher
        makiLog.notice("capture watcher started folder=\(target.lastPathComponent, privacy: .public)")
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        folder = nil
        known.removeAll()
        work?.cancel()
        work = nil
    }

    private func restart() {
        stop()
        guard WorkspaceStore.shared.screenshotSavedNotice else { return }
        start()
    }

    /// The folder the library shows: the one chosen in Settings, else the system
    /// one, so the notice follows `com.apple.screencapture` too.
    private func folderToWatch() -> URL {
        if let stored = UserDefaults.standard.string(forKey: "screenshotLibraryFolderPath"),
           stored.isEmpty == false {
            return URL(fileURLWithPath: stored, isDirectory: true).standardizedFileURL
        }
        return SystemScreenshotFolder.folderURL()
    }

    private func scheduleScan() {
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.scan(announce: true) }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// Lists the folder on a worker and hands the new captures back on the main
    /// actor: a slow Desktop (network, iCloud) must not hold up a keystroke.
    private func scan(announce: Bool) {
        guard let folder else { return }
        if scanning {
            pending = true
            return
        }
        scanning = true
        pending = false
        let path = folder.path
        let previous = known

        queue.async { [weak self] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            let paths = Set(names.filter { ScreenshotNames.isCapture($0) }
                .map { path + "/" + $0 })
            var fresh: [(url: URL, age: TimeInterval)] = []
            if announce {
                for candidate in paths.subtracting(previous) {
                    let url = URL(fileURLWithPath: candidate)
                    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    let age = Date().timeIntervalSince(values?.contentModificationDate ?? .distantPast)
                    fresh.append((url, age))
                }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scanning = false
                guard self.folder?.path == path else { return }
                // The whole listing is the new baseline, not just the additions:
                // a file that went away must not be announced twice.
                self.known = paths
                for item in fresh.sorted(by: { $0.age < $1.age }) {
                    self.announce(item.url, age: item.age)
                }
                if self.pending { self.scan(announce: true) }
            }
        }
    }

    private func announce(_ url: URL, age: TimeInterval) {
        let enabled = WorkspaceStore.shared.screenshotSavedNotice
        let secure = secureInput()
        let allowed = Policy.shouldAnnounce(enabled: enabled, secureInput: secure,
                                            isImage: true, age: age)
        // One line per capture that landed, with the decision and no path: it
        // is what tells "the notice was off" from "the file was not seen".
        makiLog.notice("capture notice enabled=\(enabled, privacy: .public) secure=\(secure, privacy: .public) age=\(Int(age), privacy: .public) shown=\(allowed, privacy: .public)")
        guard allowed else { return }
        HUDController.shared.show(
            "Screenshot saved",
            symbol: "camera.viewfinder",
            detail: url.lastPathComponent,
            kind: .info,
            actions: [
                HUDAction(title: "Shelf") { ShelfController.shared.add(file: url) },
                // Reading it is the other thing a capture is usually for (T41).
                HUDAction(title: "Copy text") {
                    guard let image = NSImage(contentsOf: url),
                          let cgImage = image.cgImage(forProposedRect: nil, context: nil,
                                                      hints: nil) else { return }
                    TextRecognitionController.shared.recognize(image: cgImage)
                }
            ]
        )
    }
}
