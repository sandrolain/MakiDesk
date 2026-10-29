import AppKit
import CoreServices
import Foundation

/// Where macOS writes screenshots, read without writing its preferences.
///
/// The screenshot library keeps its own folder only when the user chose one:
/// otherwise it follows `com.apple.screencapture` so a change in System
/// Settings reaches the next launch (T48).
enum SystemScreenshotFolder {
    typealias PreferencesReader = (String) -> Any?

    static let domain = "com.apple.screencapture"

    /// The folder the next screenshot will be saved to. A missing or empty
    /// `location` means the Desktop, as macOS documents.
    static func folderURL(read: PreferencesReader = readPreference) -> URL {
        guard let raw = read("location") as? String else { return desktopURL }
        let expanded = (raw as NSString).expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expanded.isEmpty else { return desktopURL }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    /// `png`, `jpg`, `pdf` or `tiff` when System Settings picks one of them.
    /// `nil` means the key is absent or unknown; the library keeps listing
    /// every format it supports either way.
    static func fileType(read: PreferencesReader = readPreference) -> String? {
        guard let raw = read("type") as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["png", "jpg", "jpeg", "pdf", "tiff"].contains(value) ? value : nil
    }

    static var desktopURL: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Reads another application's preference; `CFPreferences` needs only read
    /// access and cannot change the value.
    static func readPreference(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    }
}

/// What macOS calls its captures and what the library lists (T40B, T48).
///
/// One place for the names, because two watchers now look at the same folder:
/// the library window and the notice for a capture that has just been saved.
enum ScreenshotNames {
    /// The localised prefixes macOS gives its captures.
    static let prefixes = [
        "screenshot", "screen shot", "schermata", "bildschirmfoto",
        "captura de pantalla", "capture d'écran", "截屏", "スクリーンショット"
    ]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "pdf"]
    /// `⌘⇧5` can also record a movie into the same folder (T48).
    static let videoExtensions: Set<String> = ["mov", "mp4"]
    /// macOS names recordings in the system language, not "Screenshot…".
    static let videoPrefixes = [
        "screen recording", "registrazione schermo", "bildschirmaufnahme",
        "grabación de pantalla", "enregistrement d'écran", "录屏", "画面収録"
    ]

    /// Whether a file name is a capture the library lists.
    static func isCapture(_ name: String, recordings: Bool = false) -> Bool {
        let lower = name.lowercased()
        let prefixes = Self.prefixes + (recordings ? videoPrefixes : [])
        guard prefixes.contains(where: lower.hasPrefix) else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        let extensions = imageExtensions.union(recordings ? videoExtensions : [])
        return extensions.contains(ext)
    }
}

/// Spotlight's list of screen captures in one folder.
enum ScreenshotIndexState: Equatable, Sendable {
    /// Not running: the library is closed.
    case idle
    /// The query started and has not delivered its first batch.
    case gathering
    /// Spotlight answered with at least one capture.
    case indexed
    /// Spotlight answered with none: either the folder holds no captures or
    /// its index is off. The name-based scan still lists what it can.
    case empty
    /// The query could not start (missing folder, unreadable volume).
    case unavailable
}

@MainActor
protocol ScreenshotIndexProvider: AnyObject {
    var state: ScreenshotIndexState { get }
    var paths: [String] { get }
    var onChange: (() -> Void)? { get set }
    func start(folder: URL)
    func stop()
}

/// Uses `kMDItemIsScreenCapture` so captures stay listed after being renamed.
///
/// macOS sets that attribute on the files `screencapture` produced, whatever
/// their name; it is not declared in the public SDK headers, so the query uses
/// the literal key. The query delivers on the main run loop: only the paths are
/// read there, while stat and diffing happen on the scan worker.
@MainActor
final class ScreenshotSpotlightIndex: ScreenshotIndexProvider {
    private(set) var state: ScreenshotIndexState = .idle
    private(set) var paths: [String] = []
    var onChange: (() -> Void)?

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var folder: URL?

    func start(folder: URL) {
        stop()
        let folder = folder.standardizedFileURL
        self.folder = folder
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
        query.searchScopes = [folder]
        query.notificationBatchingInterval = 0.5
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                               object: query, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.collect() }
            },
            center.addObserver(forName: .NSMetadataQueryDidUpdate,
                               object: query, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.collect() }
            }
        ]
        self.query = query
        state = .gathering
        guard query.start() else {
            stop()
            state = .unavailable
            return
        }
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        query?.stop()
        query = nil
        folder = nil
        paths = []
        state = .idle
    }

    private func collect() {
        guard let query, let folder else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }
        // A directory scope searches recursively; the library lists the folder
        // itself, so only direct children are kept.
        let directoryPath = folder.path
        var found: [String] = []
        let count = query.resultCount
        for index in 0..<count {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  URL(fileURLWithPath: path).deletingLastPathComponent()
                    .standardizedFileURL.path == directoryPath else { continue }
            found.append(path)
        }
        let unique = Array(Set(found)).sorted()
        let changed = unique != paths
        paths = unique
        state = unique.isEmpty ? .empty : .indexed
        if changed { onChange?() }
    }
}

/// One FSEvents stream for the screenshot folder.
///
/// It replaces the per-window `DispatchSource`: no file descriptor to leak, it
/// survives the folder being renamed or replaced, and reports a root change
/// instead of dying silently. `start`/`stop` are main-thread operations; the
/// stream delivers batches on its own queue and only calls the handler.
final class ScreenshotFolderWatcher {
    private let queue = DispatchQueue(label: "com.makidesk.screenshot-folder", qos: .utility)
    private let events: EventHandler
    private var stream: FSEventStreamRef?

    init(handler: @escaping @Sendable (FSEventStreamEventFlags) -> Void) {
        events = EventHandler(handler: handler)
    }

    deinit { stop() }

    /// One batch can hold several events; a root change or rescan request in
    /// any of them must reach the handler, not only the first one's flags.
    static func combine(_ flags: [FSEventStreamEventFlags]) -> FSEventStreamEventFlags {
        flags.reduce(0, |)
    }

    func start(folder: URL) {
        stop()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(events).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            nil,
            { _, info, count, _, flags, _ in
                guard let info else { return }
                let combined = ScreenshotFolderWatcher.combine(Array(UnsafeBufferPointer(start: flags, count: count)))
                Unmanaged<EventHandler>.fromOpaque(info).takeUnretainedValue().call(combined)
            },
            &context,
            [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            // Keep the system coalescing short: the model applies its own
            // debounce, so the end-to-end delay stays around half a second.
            0.2,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Keeps the C callback independent from the watcher's lifetime: the block
    /// is immutable and the box outlives the stream, which is invalidated in
    /// `stop` before the box can be released.
    private final class EventHandler: @unchecked Sendable {
        private let handler: @Sendable (FSEventStreamEventFlags) -> Void

        init(handler: @escaping @Sendable (FSEventStreamEventFlags) -> Void) {
            self.handler = handler
        }

        func call(_ flags: FSEventStreamEventFlags) {
            handler(flags)
        }
    }
}
