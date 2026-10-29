import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import Observation
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

struct ScreenshotFile: Identifiable, Equatable, Sendable {
    let path: String
    let name: String
    let modified: Date
    let byteCount: Int

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var thumbnailRevision: String { "\(path)|\(modified.timeIntervalSince1970)|\(byteCount)" }

    /// Screen recordings share the folder with captures (T48). They have no
    /// still image to decode, so the card shows a film icon and a duration.
    var isVideo: Bool {
        ["mov", "mp4"].contains(url.pathExtension.lowercased())
    }
}

enum ScreenshotSortOrder: String, CaseIterable, Identifiable {
    case newestFirst
    case oldestFirst

    var id: String { rawValue }
}

enum ScreenshotGrouping: String, CaseIterable, Identifiable {
    case none
    case month
    case week

    var id: String { rawValue }
}

struct ScreenshotSection: Identifiable {
    let id: String
    let title: String?
    let files: [ScreenshotFile]
}

struct ScreenshotScan: Sendable {
    let files: [ScreenshotFile]
    let error: String?
    /// The folder could not be read for lack of permission, not for another
    /// reason: the view offers the Files and Folders pane instead of a dead end.
    var needsPermission = false
}

@Observable
@MainActor
final class ScreenshotLibraryModel {
    /// `(folder, name prefixes, image extensions, paths Spotlight indexed)` on
    /// a worker; the run parameters travel as values so the scan never touches
    /// main-actor state.
    typealias DirectoryScanner = @Sendable (String, [String], Set<String>, [String]) -> ScreenshotScan
    private(set) var folderURL: URL
    private(set) var files: [ScreenshotFile] = []
    private(set) var selectedPaths: Set<String> = []
    private(set) var isLoading = false
    private(set) var isOperating = false
    private(set) var indexState: ScreenshotIndexState = .idle
    private(set) var message: String?
    /// The scan failed because macOS has not granted access to this folder
    /// (Desktop, Documents and removable volumes go through TCC).
    private(set) var needsFileAccess = false
    /// Whether screen recordings are listed. Off by default (T48).
    var showsRecordings = false
    var searchText = ""
    var sortOrder: ScreenshotSortOrder = .newestFirst
    var grouping: ScreenshotGrouping = .month
    var thumbnailScale: Double = 1

    private var scanGeneration: UInt64 = 0
    private var scanInFlight = false
    private var refreshPending = false
    private var isPresented = false
    private let scanDirectory: DirectoryScanner
    private let defaults: UserDefaults
    private let systemFolder: () -> URL
    private let spotlight: ScreenshotIndexProvider
    private var watcher: ScreenshotFolderWatcher?
    private var refreshWork: DispatchWorkItem?

    private static let folderKey = "screenshotLibraryFolderPath"
    private static let screenshotPrefixes = [
        "screenshot", "screen shot", "schermata", "bildschirmfoto",
        "captura de pantalla", "capture d'écran", "截屏", "スクリーンショット"
    ]
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tif", "tiff", "pdf"
    ]
    /// `⌘⇧5` can also record a movie into the same folder (T48).
    private static let videoExtensions: Set<String> = ["mov", "mp4"]
    /// macOS names recordings in the system language, not "Screenshot…".
    private static let videoPrefixes = [
        "screen recording", "registrazione schermo", "bildschirmaufnahme",
        "grabación de pantalla", "enregistrement d'écran", "录屏", "画面収録"
    ]

    init(folderURL overrideFolderURL: URL? = nil,
         defaults: UserDefaults = .standard,
         systemFolder: @escaping () -> URL = { SystemScreenshotFolder.folderURL() },
         index: ScreenshotIndexProvider? = nil,
         scanner: DirectoryScanner? = nil) {
        self.defaults = defaults
        self.systemFolder = systemFolder
        spotlight = index ?? ScreenshotSpotlightIndex()
        sortOrder = ScreenshotSortOrder(rawValue: defaults.string(forKey: "screenshotLibrarySort") ?? "") ?? .newestFirst
        showsRecordings = defaults.object(forKey: "screenshotLibraryShowsRecordings") as? Bool ?? false
        grouping = ScreenshotGrouping(rawValue: defaults.string(forKey: "screenshotLibraryGrouping") ?? "") ?? .month
        thumbnailScale = min(max(defaults.object(forKey: "screenshotLibraryScale") as? Double ?? 1, 0.75), 1.6)
        if let overrideFolderURL {
            folderURL = overrideFolderURL.standardizedFileURL
        } else if let path = defaults.string(forKey: Self.folderKey),
           FileManager.default.fileExists(atPath: path) {
            folderURL = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            folderURL = systemFolder().standardizedFileURL
        }
        scanDirectory = scanner ?? { path, prefixes, extensions, indexedPaths in
            Self.scan(path: path, prefixes: prefixes, extensions: extensions, indexedPaths: indexedPaths)
        }
        spotlight.onChange = { [weak self] in
            guard let self else { return }
            self.indexState = self.spotlight.state
            self.scheduleRefresh()
        }
    }

    var systemFolderURL: URL {
        systemFolder().standardizedFileURL
    }

    /// The read-only `type` macOS was configured with, for the button's hint.
    var systemFolderType: String? {
        SystemScreenshotFolder.fileType()
    }

    var isUsingSystemFolder: Bool {
        folderURL.standardizedFileURL == systemFolderURL
    }

    var visibleFiles: [ScreenshotFile] {
        let matches = files.filter {
            searchText.isEmpty ||
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
        return matches.sorted {
            sortOrder == .newestFirst ? $0.modified > $1.modified : $0.modified < $1.modified
        }
    }

    var sections: [ScreenshotSection] {
        let visible = visibleFiles
        guard grouping != .none else {
            return visible.isEmpty ? [] : [ScreenshotSection(id: "all", title: nil, files: visible)]
        }
        let calendar = Calendar.current
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "LLLL yyyy"
        let weekFormatter = DateFormatter()
        weekFormatter.dateFormat = "MMM d"
        var buckets: [String: (date: Date, title: String, files: [ScreenshotFile])] = [:]
        for file in visible {
            let date: Date
            let key: String
            let title: String
            if grouping == .month {
                let components = calendar.dateComponents([.year, .month], from: file.modified)
                date = calendar.date(from: components) ?? file.modified
                key = "month-\(components.year ?? 0)-\(components.month ?? 0)"
                title = monthFormatter.string(from: date)
            } else {
                let interval = calendar.dateInterval(of: .weekOfYear, for: file.modified)
                date = interval?.start ?? file.modified
                key = "week-\(Int(date.timeIntervalSince1970))"
                let start = weekFormatter.string(from: date)
                let end = weekFormatter.string(from: interval?.end.addingTimeInterval(-1) ?? date)
                title = "\(start) – \(end)"
            }
            if buckets[key] == nil { buckets[key] = (date, title, []) }
            buckets[key]?.files.append(file)
        }
        return buckets.map { key, bucket in
            ScreenshotSection(id: key, title: bucket.title, files: bucket.files)
        }.sorted {
            sortOrder == .newestFirst ? $0.files[0].modified > $1.files[0].modified
                                      : $0.files[0].modified < $1.files[0].modified
        }
    }

    var selectedFiles: [ScreenshotFile] {
        files.filter { selectedPaths.contains($0.path) }
    }

    func show() {
        isPresented = true
        refresh()
        startWatching()
        startIndexing()
    }

    func hide() {
        isPresented = false
        scanGeneration &+= 1
        refreshPending = false
        isLoading = false
        refreshWork?.cancel()
        refreshWork = nil
        stopWatching()
        stopIndexing()
        // Thumbnails are derived from screen contents; release them with the
        // window instead of keeping a bounded cache alive (T48).
        ScreenshotThumbnailCache.shared.removeAll()
    }

    func select(_ file: ScreenshotFile, extending: Bool) {
        if extending {
            if selectedPaths.contains(file.path) {
                selectedPaths.remove(file.path)
            } else {
                selectedPaths.insert(file.path)
            }
        } else {
            selectedPaths = [file.path]
        }
    }

    func selectAll() {
        selectedPaths = Set(visibleFiles.map(\.path))
    }

    func setSelection(_ paths: Set<String>) {
        let visiblePaths = Set(visibleFiles.map(\.path))
        selectedPaths = paths.intersection(visiblePaths)
    }

    func clearSelection() {
        selectedPaths.removeAll()
    }

    func setSortOrder(_ order: ScreenshotSortOrder) {
        sortOrder = order
        defaults.set(order.rawValue, forKey: "screenshotLibrarySort")
    }

    func setGrouping(_ value: ScreenshotGrouping) {
        grouping = value
        defaults.set(value.rawValue, forKey: "screenshotLibraryGrouping")
    }

    func setThumbnailScale(_ value: Double) {
        thumbnailScale = value
        defaults.set(value, forKey: "screenshotLibraryScale")
    }

    /// Lists or hides screen recordings; persisted, off by default (T48).
    func setShowsRecordings(_ value: Bool) {
        guard showsRecordings != value else { return }
        showsRecordings = value
        defaults.set(value, forKey: "screenshotLibraryShowsRecordings")
        refresh()
    }

    /// Opens the pane where the user grants access to Desktop and Documents.
    func openFileAccessSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") else { return }
        NSWorkspace.shared.open(url)
    }

    func chooseFolder(_ url: URL) {
        applyFolder(url, persist: true)
    }

    /// Stops persisting a custom folder, so the next launch follows the system
    /// setting again (T48).
    func useSystemFolder() {
        applyFolder(systemFolder(), persist: false)
    }

    private func applyFolder(_ url: URL, persist: Bool) {
        folderURL = url.standardizedFileURL
        // Choosing exactly the folder macOS uses means following it, not
        // freezing today's path: a later change in System Settings must reach
        // the next launch too.
        if persist, folderURL != systemFolder().standardizedFileURL {
            defaults.set(folderURL.path, forKey: Self.folderKey)
        } else {
            defaults.removeObject(forKey: Self.folderKey)
        }
        clearSelection()
        message = nil
        restartWatching()
        startIndexing()
        refresh()
    }

    func refresh() {
        guard isPresented else { return }
        guard !scanInFlight else {
            // Many file events can arrive during a slow directory walk. Keep
            // one fresh scan for the latest folder and discard this result.
            scanGeneration &+= 1
            refreshPending = true
            isLoading = true
            return
        }
        startScan()
    }

    private func startScan() {
        guard isPresented else { return }
        scanInFlight = true
        refreshPending = false
        scanGeneration &+= 1
        let generation = scanGeneration
        let path = folderURL.path
        isLoading = true
        let prefixes = Self.screenshotPrefixes
            + (showsRecordings ? Self.videoPrefixes : [])
        let extensions = Self.imageExtensions
            .union(showsRecordings ? Self.videoExtensions : [])
        let indexedPaths = spotlight.paths
        let scanDirectory = self.scanDirectory

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = scanDirectory(path, prefixes, extensions, indexedPaths)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scanInFlight = false
                if self.isPresented, self.scanGeneration == generation,
                   self.folderURL.path == path {
                    // Only a real change is published: a watcher event that
                    // left the folder as it was must not rebuild the grid or
                    // move the scroll (T48).
                    if result.files != self.files { self.files = result.files }
                    self.selectedPaths.formIntersection(Set(result.files.map(\.path)))
                    self.isLoading = false
                    self.message = result.error
                    self.needsFileAccess = result.needsPermission
                }
                if self.isPresented, self.refreshPending { self.startScan() }
            }
        }
    }

    func trashSelected() {
        performFileOperation(title: "Moving screenshots to Trash") { files in
            var removed = Set<String>()
            var failures: [String] = []
            for file in files {
                do {
                    try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
                    removed.insert(file.path)
                } catch {
                    failures.append("\(file.name): \(error.localizedDescription)")
                }
            }
            return (removed, failures)
        }
    }

    func moveSelected(to destination: URL) {
        guard destination.standardizedFileURL != folderURL.standardizedFileURL else {
            message = "Choose a folder other than the current screenshot folder."
            return
        }
        performFileOperation(title: "Moving screenshots") { files in
            var moved = Set<String>()
            var failures: [String] = []
            for file in files {
                do {
                    let target = Self.nonCollidingURL(for: file.url, in: destination)
                    try FileManager.default.moveItem(at: file.url, to: target)
                    moved.insert(file.path)
                } catch {
                    failures.append("\(file.name): \(error.localizedDescription)")
                }
            }
            return (moved, failures)
        }
    }

    private func performFileOperation(
        title: String,
        operation: @escaping @Sendable ([ScreenshotFile]) -> (Set<String>, [String])
    ) {
        let selection = selectedFiles
        guard !selection.isEmpty, !isOperating else { return }
        isOperating = true
        message = title + "…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = operation(selection)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isOperating = false
                self.selectedPaths.subtract(result.0)
                if result.1.isEmpty {
                    self.message = "\(result.0.count) screenshot(s) processed"
                } else {
                    self.message = result.1.prefix(2).joined(separator: " · ")
                }
                self.refresh()
            }
        }
    }

    /// Lists the folder by name **and** merges the paths Spotlight indexed
    /// (`kMDItemIsScreenCapture`), so a renamed capture stays visible. The
    /// name scan runs first: it also covers files Spotlight has not indexed and
    /// keeps the list usable when indexing is off.
    nonisolated static func scan(
        path: String,
        prefixes: [String],
        extensions: Set<String>,
        indexedPaths: [String]
    ) -> ScreenshotScan {
        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            var seen = Set<String>()
            var files: [ScreenshotFile] = []
            for url in urls {
                guard extensions.contains(url.pathExtension.lowercased()),
                      prefixes.contains(where: { url.deletingPathExtension().lastPathComponent
                          .localizedLowercase.hasPrefix($0.localizedLowercase) }),
                      let file = screenshotFile(at: url),
                      seen.insert(file.path).inserted else { continue }
                files.append(file)
            }
            // A Spotlight scope is recursive; only direct children belong here.
            let directoryPath = directory.path
            for indexed in indexedPaths {
                let url = URL(fileURLWithPath: indexed)
                guard url.deletingLastPathComponent().standardizedFileURL.path == directoryPath,
                      extensions.contains(url.pathExtension.lowercased()),
                      let file = screenshotFile(at: url),
                      seen.insert(file.path).inserted else { continue }
                files.append(file)
            }
            return ScreenshotScan(
                files: files.sorted { $0.modified > $1.modified }, error: nil
            )
        } catch {
            let denied = isPermissionDenied(error)
            return ScreenshotScan(
                files: [],
                error: denied
                    ? "MakiDesk cannot read this folder. Allow it in System Settings ▸ Privacy & Security ▸ Files and Folders."
                    : error.localizedDescription,
                needsPermission: denied
            )
        }
    }

    /// A TCC refusal arrives as a Cocoa permission error or as POSIX `EPERM` /
    /// `EACCES`, depending on the volume (T48).
    nonisolated static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileReadNoPermissionError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(EPERM) || nsError.code == Int(EACCES)
        }
        return false
    }

    nonisolated private static func screenshotFile(at url: URL) -> ScreenshotFile? {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .contentModificationDateKey, .fileSizeKey
        ]), values.isRegularFile == true else { return nil }
        return ScreenshotFile(
            path: url.standardizedFileURL.path,
            name: url.lastPathComponent,
            modified: values.contentModificationDate ?? .distantPast,
            byteCount: values.fileSize ?? 0
        )
    }

    nonisolated private static func nonCollidingURL(for source: URL, in directory: URL) -> URL {
        let initial = directory.appendingPathComponent(source.lastPathComponent)
        guard FileManager.default.fileExists(atPath: initial.path) else { return initial }
        let base = source.deletingPathExtension().lastPathComponent
        let suffix = source.pathExtension
        var index = 2
        while true {
            let name = suffix.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(suffix)"
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private func restartWatching() {
        stopWatching()
        startWatching()
    }

    private func startWatching() {
        guard isPresented, watcher == nil else { return }
        let watcher = ScreenshotFolderWatcher { [weak self] flags in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A renamed, moved or replaced folder keeps the same path but
                // invalidates the watched root: reopen the stream before the
                // rescan, otherwise later changes would go unseen.
                if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                    self.restartWatching()
                }
                self.scheduleRefresh()
            }
        }
        watcher.start(folder: folderURL)
        self.watcher = watcher
    }

    private func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    private func startIndexing() {
        guard isPresented else { return }
        spotlight.start(folder: folderURL)
        indexState = spotlight.state
    }

    private func stopIndexing() {
        spotlight.stop()
        indexState = .idle
    }

    private func scheduleRefresh() {
        guard isPresented else { return }
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

@MainActor
final class ScreenshotLibraryController: NSObject, NSWindowDelegate,
                                         @preconcurrency QLPreviewPanelDataSource,
                                         QLPreviewPanelDelegate {
    static let shared = ScreenshotLibraryController()

    private let model = ScreenshotLibraryModel()
    private var window: NSWindow?
    private let focusReturn = PanelFocusReturn()
    private var keyMonitor: Any?
    private var previewURLs: [NSURL] = []

    private override init() {
        super.init()
    }

    func show() {
        if let window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        focusReturn.capture()
        let window = buildIfNeeded()
        UtilityWindowPlacement.placeOnFocusedScreen(window)
        model.show()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func shutdown() {
        model.hide()
        removeKeyMonitor()
        dismissQuickLook(returnToLibrary: false)
        window?.orderOut(nil)
    }

    private func buildIfNeeded() -> NSWindow {
        if let window { return window }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Screenshots"
        window.setAccessibilityLabel("Screenshot Library")
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 620, height: 440)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: ScreenshotLibraryView(
            model: model,
            store: WorkspaceStore.shared,
            chooseFolder: { [weak self] in self?.chooseFolder() },
            moveSelection: { [weak self] in self?.chooseMoveDestination() },
            previewSelection: { [weak self] in self?.toggleQuickLook() },
            recognizeSelection: { [weak self] in self?.recognizeSelection() },
            openFile: { NSWorkspace.shared.open($0) }
        ))
        window.center()
        self.window = window
        return window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.hide()
        removeKeyMonitor()
        dismissQuickLook(returnToLibrary: false)
        let restore = focusReturn.takeRestoreAction(ownsKeyboard: sender.isKeyWindow)
        sender.orderOut(nil)
        restore?()
        return false
    }

    private func chooseFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Screenshot Folder"
        panel.message = "Choose the folder where macOS saves screenshots."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.folderURL
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.model.chooseFolder(url)
        }
    }

    private func chooseMoveDestination() {
        guard let window, !model.selectedFiles.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Move Screenshots"
        panel.message = "Choose a destination folder."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.model.moveSelected(to: url)
        }
    }

    /// Reads the text in the selected screenshot: the picture is already on
    /// disk, so no capture and no Screen Recording is involved (T41).
    private func recognizeSelection() {
        let selected = model.selectedFiles
        guard selected.count == 1, let file = selected.first,
              let image = NSImage(contentsOf: file.url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        TextRecognitionController.shared.recognize(image: cgImage)
    }

    private func toggleQuickLook() {
        guard let preview = QLPreviewPanel.shared() else { return }
        if preview.isVisible, preview.dataSource === self {
            dismissQuickLook(returnToLibrary: true)
            return
        }
        let selected = model.selectedFiles
        guard !selected.isEmpty else { return }
        previewURLs = selected.map { $0.url as NSURL }
        preview.dataSource = self
        preview.delegate = self
        preview.reloadData()
        preview.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard previewURLs.indices.contains(index) else { return nil }
        return previewURLs[index]
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let preview = QLPreviewPanel.shared()
            let ownsPreview = preview?.dataSource === self
            let previewIsKey = ownsPreview && preview?.isKeyWindow == true
            guard self.window?.isKeyWindow == true || previewIsKey else { return event }
            if !previewIsKey,
               let editor = self.window?.firstResponder as? NSTextView,
               editor.isFieldEditor {
                return event
            }
            if event.keyCode == 49 {
                self.toggleQuickLook()
                return nil
            }
            if event.keyCode == 53, ownsPreview, preview?.isVisible == true {
                self.dismissQuickLook(returnToLibrary: true)
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func dismissQuickLook(returnToLibrary: Bool) {
        guard let preview = QLPreviewPanel.shared(), preview.dataSource === self else { return }
        preview.orderOut(nil)
        if returnToLibrary { window?.makeKeyAndOrderFront(nil) }
    }
}

private struct ScreenshotLibraryView: View {
    @Bindable var model: ScreenshotLibraryModel
    @Bindable var store: WorkspaceStore
    let chooseFolder: () -> Void
    let moveSelection: () -> Void
    let previewSelection: () -> Void
    let recognizeSelection: () -> Void
    let openFile: (URL) -> Void
    @State private var cardFrames: [String: CGRect] = [:]
    @State private var marqueeStart: CGPoint?
    @State private var marqueeRect: CGRect?

    var body: some View {
        VStack(spacing: 0) {
            header
            controls
            Divider()
            if model.visibleFiles.isEmpty {
                ContentUnavailableView {
                    Label(model.isLoading ? "Loading Screenshots…" : (model.searchText.isEmpty ? "No Screenshots Found" : "No Matching Screenshots"),
                          systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text(model.message ?? (model.searchText.isEmpty
                        ? (model.indexState == .empty || model.indexState == .unavailable
                            ? "Screenshots appear by name; Spotlight has no indexed captures in this folder, so renamed ones may be missing."
                            : "Screenshots in the selected folder will appear here.")
                        : "Try another filename or clear the search."))
                } actions: {
                    if model.needsFileAccess {
                        Button("Open Privacy Settings") { model.openFileAccessSettings() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let horizontalInset: CGFloat = 20
                    let spacing: CGFloat = 14
                    let contentWidth = max(1, geometry.size.width - horizontalInset * 2)
                    let minimumCardWidth = 210 * model.thumbnailScale
                    let fitCount = Int((contentWidth + spacing) / (minimumCardWidth + spacing))
                    let columnCount = max(1, min(5, fitCount))
                    let cardWidth = (contentWidth - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(model.sections) { section in
                                VStack(alignment: .leading, spacing: 10) {
                                    if let title = section.title {
                                        Text(title)
                                            .font(.headline)
                                            .foregroundStyle(store.theme.text)
                                            .padding(.horizontal, 2)
                                    }
                                    LazyVGrid(
                                        columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing), count: columnCount),
                                        alignment: .leading,
                                        spacing: spacing
                                    ) {
                                        ForEach(section.files) { file in
                                            ScreenshotCard(
                                                model: model,
                                                file: file,
                                                scale: model.thumbnailScale,
                                                width: cardWidth,
                                                open: { openFile(file.url) }
                                            )
                                            .background {
                                                GeometryReader { proxy in
                                                    Color.clear.preference(
                                                        key: ScreenshotCardFramesKey.self,
                                                        value: [file.path: proxy.frame(in: .named("screenshotGrid"))]
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, horizontalInset)
                        .padding(.vertical, 18)
                    }
                    .coordinateSpace(name: "screenshotGrid")
                    .onPreferenceChange(ScreenshotCardFramesKey.self) { cardFrames = $0 }
                    .simultaneousGesture(
                        SpatialTapGesture(coordinateSpace: .named("screenshotGrid"))
                            .onEnded { event in
                                if !cardFrames.values.contains(where: { $0.contains(event.location) }) {
                                    model.clearSelection()
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 4, coordinateSpace: .named("screenshotGrid"))
                            .onChanged { value in
                                if marqueeStart == nil {
                                    guard !cardFrames.values.contains(where: { $0.contains(value.startLocation) }) else { return }
                                    marqueeStart = value.startLocation
                                }
                                guard let start = marqueeStart else { return }
                                let rect = CGRect(
                                    x: min(start.x, value.location.x),
                                    y: min(start.y, value.location.y),
                                    width: abs(value.location.x - start.x),
                                    height: abs(value.location.y - start.y)
                                )
                                marqueeRect = rect
                                let selected = cardFrames.compactMap { path, frame in
                                    rect.intersects(frame) ? path : nil
                                }
                                model.setSelection(Set(selected))
                            }
                            .onEnded { _ in
                                marqueeStart = nil
                                marqueeRect = nil
                            }
                    )
                    .overlay(alignment: .topLeading) {
                        if let marqueeRect {
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.14))
                                .overlay {
                                    Rectangle().stroke(Color.accentColor, lineWidth: 1)
                                }
                                .frame(width: marqueeRect.width, height: marqueeRect.height)
                                .offset(x: marqueeRect.minX, y: marqueeRect.minY)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            Divider()
            footer
        }
        .background(store.theme.background)
        .frame(minWidth: 620, minHeight: 440)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 17, weight: .medium))
            VStack(alignment: .leading, spacing: 2) {
                Text("Screenshots").font(.headline)
                HStack(spacing: 4) {
                    Text(model.folderURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if model.indexState == .empty || model.indexState == .unavailable {
                        Image(systemName: "magnifyingglass")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Spotlight has no indexed captures here: files are matched by name, so renamed captures may be missing.")
                            .accessibilityLabel("Spotlight has no indexed captures in this folder")
                    }
                }
            }
            Spacer()
            TextField("Search screenshots", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 210)
            if !model.isUsingSystemFolder {
                Button("Use System Folder", action: model.useSystemFolder)
                    .help(model.systemFolderType.map {
                        "Follow the folder macOS saves screenshots in (\($0.uppercased()))"
                    } ?? "Follow the folder macOS saves screenshots in")
            }
            Button(action: chooseFolder) {
                Label("Folder…", systemImage: "folder")
            }
            Button(action: model.refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh screenshot list")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            Text(model.message ?? "\(model.files.count) screenshots · \(model.selectedPaths.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Select All", action: model.selectAll)
                .disabled(model.visibleFiles.isEmpty || model.isOperating)
            Button("Clear Selection", action: model.clearSelection)
                .disabled(model.selectedPaths.isEmpty || model.isOperating)
            Button(action: previewSelection) {
                Label("Preview", systemImage: "eye")
            }
            .help("Quick Look selected screenshots (Space)")
            .disabled(model.selectedPaths.isEmpty)
            Button(action: recognizeSelection) {
                Label("Recognize Text", systemImage: "text.viewfinder")
            }
            .help("Read the text in the selected screenshot, without capturing anything")
            .disabled(model.selectedFiles.count != 1 || model.isOperating)
            Button(role: .destructive, action: model.trashSelected) {
                Label("Move to Trash", systemImage: "trash")
            }
            .disabled(model.selectedPaths.isEmpty || model.isOperating)
            Button(action: moveSelection) {
                Label("Move…", systemImage: "folder.badge.arrow.right")
            }
            .disabled(model.selectedPaths.isEmpty || model.isOperating)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Order", selection: Binding(
                get: { model.sortOrder },
                set: { model.setSortOrder($0) }
            )) {
                Text("Newest").tag(ScreenshotSortOrder.newestFirst)
                Text("Oldest").tag(ScreenshotSortOrder.oldestFirst)
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
            .accessibilityLabel("Screenshot sort order")

            Picker("Group", selection: Binding(
                get: { model.grouping },
                set: { model.setGrouping($0) }
            )) {
                Text("All").tag(ScreenshotGrouping.none)
                Text("Month").tag(ScreenshotGrouping.month)
                Text("Week").tag(ScreenshotGrouping.week)
            }
            .pickerStyle(.segmented)
            .frame(width: 205)
            .accessibilityLabel("Group screenshots")

            Spacer(minLength: 2)
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { model.thumbnailScale },
                set: { model.setThumbnailScale($0) }
            ), in: 0.75...1.6, step: 0.05)
                .frame(width: 90)
                .help("Resize screenshot cards")
            Image(systemName: "photo.fill")
                .foregroundStyle(.secondary)
            Button {
                model.setShowsRecordings(!model.showsRecordings)
            } label: {
                Label("Videos", systemImage: model.showsRecordings ? "film.fill" : "film")
            }
            .buttonStyle(.borderless)
            .help(model.showsRecordings ? "Hide screen recordings" : "Show screen recordings (.mov, .mp4)")
            .accessibilityLabel("Show screen recordings")
            .accessibilityValue(model.showsRecordings ? "On" : "Off")
        }
        .font(.caption)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}

private struct ScreenshotCardFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newer in newer })
    }
}

/// Downsampled thumbnails for the cards, with an explicit memory budget (T48).
///
/// The key carries `thumbnailRevision`, so a changed file is a different entry
/// and freshness never depends on eviction order. The bound counts decoded
/// pixels, not entries: a card at 640 px costs roughly a megabyte, so 32 MiB
/// holds the visible rows plus a little scrolling either way. The cache is
/// emptied when the library closes.
final class ScreenshotThumbnailCache: @unchecked Sendable {
    static let shared = ScreenshotThumbnailCache()
    static let defaultByteLimit = 32 * 1024 * 1024

    private struct Entry {
        let image: NSImage
        let cost: Int
    }

    private let lock = NSLock()
    private let byteLimit: Int
    private var entries: [String: Entry] = [:]
    private var recency: [String] = []
    private var totalCost = 0

    init(byteLimit: Int = ScreenshotThumbnailCache.defaultByteLimit) {
        self.byteLimit = max(0, byteLimit)
    }

    var currentCost: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalCost
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    func image(forKey key: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        recency.removeAll { $0 == key }
        recency.append(key)
        return entry.image
    }

    /// Inserts a decoded image, evicting the least recently used entries until
    /// both the byte budget and the image fit. An image larger than the whole
    /// budget is not cached: it would evict everything and still not fit.
    func insert(_ image: NSImage, forKey key: String, cost: Int) {
        lock.lock()
        defer { lock.unlock() }
        let cost = max(1, cost)
        guard cost <= byteLimit else { return }
        if let old = entries.removeValue(forKey: key) {
            totalCost -= old.cost
            recency.removeAll { $0 == key }
        }
        while totalCost + cost > byteLimit {
            guard let evicted = recency.first,
                  let entry = entries.removeValue(forKey: evicted) else { break }
            recency.removeFirst()
            totalCost -= entry.cost
        }
        entries[key] = Entry(image: image, cost: cost)
        recency.append(key)
        totalCost += cost
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        recency.removeAll()
        totalCost = 0
    }
}

private enum ScreenshotThumbnailDecoder {
    private static let semaphore = DispatchSemaphore(value: 3)
    /// The long side of a card thumbnail; the cache key carries it too.
    static let maxPixelSize = 640

    static func decode(at path: String) -> CGImage? {
        semaphore.wait()
        defer { semaphore.signal() }
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary)
    }
}

/// Reads a recording's length for the card (T48). Quick Look still plays it.
private enum ScreenshotVideo {
    static func duration(at url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    static func label(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct ScreenshotCard: View {
    @Bindable var model: ScreenshotLibraryModel
    let file: ScreenshotFile
    let scale: Double
    let width: CGFloat
    let open: () -> Void
    @State private var thumbnail: NSImage?
    @State private var duration: TimeInterval?

    var body: some View {
        ScreenshotCardDragHost(
            fileURL: file.url,
            selected: model.selectedPaths.contains(file.path),
            selectedURLs: { model.selectedFiles.map(\.url) },
            select: { model.select(file, extending: $0) },
            open: open,
            didMove: { model.refresh() },
            content: cardFace
        )
        .frame(width: width, height: 190 * scale)
        .task(id: file.thumbnailRevision) {
            thumbnail = nil
            duration = nil
            if file.isVideo {
                duration = await ScreenshotVideo.duration(at: file.url)
                return
            }
            let key = "\(file.thumbnailRevision)|\(ScreenshotThumbnailDecoder.maxPixelSize)"
            if let cached = ScreenshotThumbnailCache.shared.image(forKey: key) {
                thumbnail = cached
                return
            }
            let path = file.path
            let worker = Task.detached(priority: .utility) { () -> CGImage? in
                guard !Task.isCancelled else { return nil }
                return ScreenshotThumbnailDecoder.decode(at: path)
            }
            let image = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let image else { return }
            let decoded = NSImage(cgImage: image,
                                  size: NSSize(width: image.width, height: image.height))
            ScreenshotThumbnailCache.shared.insert(decoded, forKey: key,
                                                   cost: image.bytesPerRow * image.height)
            thumbnail = decoded
        }

    }

    private var cardFace: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(nsColor: .controlBackgroundColor))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(6 * scale)
                } else if file.isVideo {
                    Image(systemName: "film")
                        .font(.system(size: 32 * scale))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 32 * scale))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 132 * scale)
            .overlay(alignment: .topTrailing) {
                if file.isVideo {
                    Label("Video", systemImage: "film.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 9 * scale, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(6 * scale)
                }
            }
            Text(file.name)
                .font(.system(size: 12 * scale, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
            HStack {
                if let duration {
                    Text(ScreenshotVideo.label(duration))
                }
                Text(file.modified, style: .date)
                Text(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
            }
            .lineLimit(1)
            .font(.system(size: 10 * scale))
            .foregroundStyle(.secondary)
        }
        .padding(8 * scale)
        .frame(width: width, height: 190 * scale, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(model.selectedPaths.contains(file.path) ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(model.selectedPaths.contains(file.path) ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: model.selectedPaths.contains(file.path) ? 2 : 1)
        }
    }

}

private struct ScreenshotCardDragHost<Content: View>: NSViewRepresentable {
    let fileURL: URL
    let selected: Bool
    let selectedURLs: () -> [URL]
    let select: (Bool) -> Void
    let open: () -> Void
    let didMove: () -> Void
    let content: Content

    func makeNSView(context: Context) -> ScreenshotCardDragView {
        ScreenshotCardDragView(rootView: AnyView(content))
    }

    func updateNSView(_ view: ScreenshotCardDragView, context: Context) {
        view.update(rootView: AnyView(content))
        view.configure(
            fileURL: fileURL,
            selected: selected,
            selectedURLs: selectedURLs,
            select: select,
            open: open,
            didMove: didMove
        )
    }
}

private final class ScreenshotCardDragView: NSView, NSDraggingSource {
    private let hostingView: NSHostingView<AnyView>
    private var fileURL: URL?
    private var isSelected = false
    private var selectedURLs: (() -> [URL])?
    private var select: ((Bool) -> Void)?
    private var open: (() -> Void)?
    private var didMove: (() -> Void)?
    private var dragStarted = false
    private var mouseDownPoint = CGPoint.zero

    init(rootView: AnyView) {
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        addSubview(hostingView)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { hostingView.intrinsicContentSize }
    override var acceptsFirstResponder: Bool { true }
    override func layout() {
        super.layout()
        hostingView.frame = bounds
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(rootView: AnyView) {
        hostingView.rootView = rootView
    }

    func configure(
        fileURL: URL,
        selected: Bool,
        selectedURLs: @escaping () -> [URL],
        select: @escaping (Bool) -> Void,
        open: @escaping () -> Void,
        didMove: @escaping () -> Void
    ) {
        self.fileURL = fileURL
        isSelected = selected
        self.selectedURLs = selectedURLs
        self.select = select
        self.open = open
        self.didMove = didMove
        setAccessibilityLabel(fileURL.lastPathComponent)
        setAccessibilityValue(selected ? "Selected" : "Not selected")
        setAccessibilityHelp("Click to select, Command-click to add or remove. Press Space to preview. Drag to move or copy.")
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        let command = event.modifierFlags.contains(.command)
        if !isSelected || command { select?(command) }
        if event.clickCount == 2 {
            open?()
        }
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted else { return }
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - mouseDownPoint.x, current.y - mouseDownPoint.y) >= 3,
              let fileURL else { return }
        dragStarted = true
        let selection = selectedURLs?() ?? []
        let urls = selection.contains(fileURL) ? selection : [fileURL]
        let point = current
        let draggingItems = urls.enumerated().map { index, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 36, height: 36)
            item.setDraggingFrame(
                NSRect(x: point.x - 18 + CGFloat(index) * 7,
                       y: point.y - 18,
                       width: 36, height: 36),
                contents: icon
            )
            return item
        }
        guard !draggingItems.isEmpty else { return }
        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move]
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        if operation.contains(.move) { didMove?() }
        dragStarted = false
    }
}
