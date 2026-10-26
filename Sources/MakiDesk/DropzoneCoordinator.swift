import Foundation
import UniformTypeIdentifiers

/// What one drop contains, already read from the pasteboard. Images travel as
/// data so the coordinator can materialize them off the main thread.
struct DropzoneDrop: Equatable, Sendable {
    struct Image: Equatable, Sendable {
        var data: Data
        var name: String
        var uti: String?

        init(data: Data, name: String, uti: String? = nil) {
            self.data = data
            self.name = name
            self.uti = uti
        }
    }

    var files: [URL]
    var text: String?
    var urls: [URL]
    var images: [Image]
    var sourceApp: String?

    init(files: [URL] = [], text: String? = nil, urls: [URL] = [],
         images: [Image] = [], sourceApp: String? = nil) {
        self.files = files
        self.text = text
        self.urls = urls
        self.images = images
        self.sourceApp = sourceApp
    }

    var isEmpty: Bool {
        files.isEmpty && images.isEmpty && urls.isEmpty && (text?.isEmpty ?? true)
    }
}

/// A command prepared for one run: executable, arguments, environment and the
/// run directory that holds the materialized payload.
struct DropzonePrepared: Equatable, Sendable {
    let command: ResolvedCommand
    let itemCount: Int
    let manifestFile: URL
    /// The absolute path of the zone's declared output, expanded with this
    /// drop's placeholders. `nil` means the zone does not check for conflicts.
    let expectedOutput: String?
}

/// Turns a drop into files and a command. All the file-system work happens off
/// the main actor: the coordinator awaits these functions.
enum DropzonePreparer {
    /// Item descriptors for matching. Reading the UTI touches the disk, which
    /// is why this is `async` and not a computed property on the drop.
    static func itemInfos(for drop: DropzoneDrop) async -> [DropItemInfo] {
        var items: [DropItemInfo] = []
        var index = 0
        for url in drop.files {
            items.append(DropItemInfo(kind: .file, uti: fileUTI(for: url),
                                      name: url.lastPathComponent, index: index))
            index += 1
        }
        for image in drop.images {
            items.append(DropItemInfo(kind: .image,
                                      uti: image.uti ?? "public.image",
                                      name: image.name, index: index))
            index += 1
        }
        for url in drop.urls {
            items.append(DropItemInfo(kind: .url, name: url.host ?? url.absoluteString,
                                      index: index))
            index += 1
        }
        if let text = drop.text, text.isEmpty == false {
            items.append(DropItemInfo(kind: .text, name: "Text", index: index))
        }
        return items
    }

    /// The UTI of a dropped file, with folders mapped to `public.folder`.
    static func fileUTI(for url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey])
        if values?.isDirectory == true { return "public.folder" }
        if let type = values?.contentType?.identifier { return type }
        guard url.pathExtension.isEmpty == false else { return nil }
        return UTType(filenameExtension: url.pathExtension)?.identifier
    }

    /// Writes text, links, images and the manifest into `workDirectory`, then
    /// resolves the command against them. Throws before anything runs.
    static func prepare(zone: DropzoneConfig,
                        drop: DropzoneDrop,
                        items: [DropItemInfo],
                        workDirectory: URL,
                        resolver: CommandResolver = CommandResolver()) async throws -> DropzonePrepared {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let output = workDirectory.appendingPathComponent("output", isDirectory: true)
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)

        // With `match: any` only the accepted sources are passed: filter the
        // drop by the indices the matcher kept.
        let accepted = Set(items.map(\.index))
        var index = 0
        var files: [URL] = []
        for url in drop.files {
            if accepted.contains(index) { files.append(url) }
            index += 1
        }
        var images: [DropzoneDrop.Image] = []
        for image in drop.images {
            if accepted.contains(index) { images.append(image) }
            index += 1
        }
        var urls: [URL] = []
        for url in drop.urls {
            if accepted.contains(index) { urls.append(url) }
            index += 1
        }
        var text: String?
        if let dropped = drop.text, dropped.isEmpty == false {
            if accepted.contains(index) { text = dropped }
        }

        var payload = CommandPayload(workDirectory: workDirectory.path)
        payload.count = items.count
        payload.name = items.first?.name
        payload.sourceApp = drop.sourceApp
        payload.context = [
            "MAKIDESK_ZONE": zone.id.uuidString,
            "MAKIDESK_ZONE_NAME": zone.name
        ]
        payload.kinds = kinds(in: items)

        var manifestItems: [Manifest.Item] = []
        var paths: [String] = []
        for url in files {
            paths.append(url.path)
            manifestItems.append(Manifest.Item(kind: "file", name: url.lastPathComponent,
                                               path: url.path, uti: fileUTI(for: url),
                                               text: nil, url: nil))
        }

        for (position, image) in images.enumerated() {
            let file = workDirectory.appendingPathComponent("image-\(position + 1).png")
            try image.data.write(to: file, options: .atomic)
            paths.append(file.path)
            manifestItems.append(Manifest.Item(kind: "image",
                                               name: image.name,
                                               path: file.path,
                                               uti: image.uti ?? "public.image",
                                               text: nil,
                                               url: nil))
        }
        payload.paths = paths

        if let text {
            let file = workDirectory.appendingPathComponent("text.txt")
            try text.write(to: file, atomically: true, encoding: .utf8)
            payload.text = text
            payload.textFile = file.path
            manifestItems.append(Manifest.Item(kind: "text", name: "Text", path: nil, uti: nil,
                                               text: text.utf8.count <= 64 * 1024 ? text : nil,
                                               url: nil))
        }

        if urls.isEmpty == false {
            let file = workDirectory.appendingPathComponent("urls.txt")
            try urls.map(\.absoluteString).joined(separator: "\n")
                .write(to: file, atomically: true, encoding: .utf8)
            payload.urls = urls.map(\.absoluteString)
            payload.urlsFile = file.path
            manifestItems.append(contentsOf: urls.map {
                Manifest.Item(kind: "url", name: $0.host ?? $0.absoluteString, path: nil,
                              uti: nil, text: nil, url: $0.absoluteString)
            })
        }

        let manifest = Manifest(zone: .init(id: zone.id.uuidString, name: zone.name),
                                sourceApp: drop.sourceApp,
                                workdir: workDirectory.path,
                                items: manifestItems)
        let manifestFile = workDirectory.appendingPathComponent("manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestFile, options: .atomic)
        payload.manifestFile = manifestFile.path

        let command = try resolver.resolve(zone.command, payload: payload)

        let expectedOutput: String?
        if let template = zone.expectedOutput?.trimmingCharacters(in: .whitespacesAndNewlines),
           template.isEmpty == false {
            if let expanded = try? resolver.resolvePathTemplate(template, payload: payload) {
                let path = (expanded as NSString).expandingTildeInPath
                expectedOutput = path.hasPrefix("/")
                    ? path
                    : command.workingDirectory.appendingPathComponent(path).path
            } else {
                expectedOutput = nil
            }
        } else {
            expectedOutput = nil
        }

        return DropzonePrepared(command: command, itemCount: items.count,
                                manifestFile: manifestFile, expectedOutput: expectedOutput)
    }

    private static func kinds(in items: [DropItemInfo]) -> [String] {
        var seen = Set<String>()
        for item in items {
            switch item.kind {
            case .file: seen.insert("files")
            case .image: seen.insert("images")
            case .url: seen.insert("urls")
            case .text: seen.insert("text")
            }
        }
        return ["files", "images", "urls", "text"].filter { seen.contains($0) }
    }
}

/// The manifest a command finds at `{manifest}`. Paths are included because the
/// user asked for that payload; nothing else is written.
private struct Manifest: Codable {
    struct Zone: Codable {
        var id: String
        var name: String
    }

    struct Item: Codable {
        var kind: String
        var name: String
        var path: String?
        var uti: String?
        var text: String?
        var url: String?
    }

    var zone: Zone
    var sourceApp: String?
    var workdir: String
    var items: [Item]
}

/// Owns the dropzone list and runs a command for one drop.
///
/// The coordinator is the only place that knows both the configuration and the
/// executor: it reloads the file before a run, validates the payload with the
/// same matcher used during the drag, prepares the run directory off the main
/// thread and reports the result. It has no UI and no pasteboard code.
@MainActor
final class DropzoneCoordinator {
    enum Outcome: Equatable {
        case rejected(DropzoneRejection)
        /// The command changed since the last confirmation: ask the user, then
        /// call `confirm` and run again.
        case needsConfirmation(DropzoneConfig)
        /// The declared output path already exists: ask before running a
        /// command that may replace it.
        case needsOverwriteConfirmation(DropzoneConfig, path: String)
        case finished(CommandResult)
        case failed(String)
    }

    static let shared = DropzoneCoordinator()

    private(set) var snapshot: DropzoneStore.Snapshot
    private(set) var runningZones: Set<UUID> = []

    private let store: DropzoneStore
    private let runner: CommandRunning
    private let runRoot: URL
    private let fileManager: FileManager
    private let preparePayload: (DropzoneConfig, DropzoneDrop, [DropItemInfo], URL) async throws -> DropzonePrepared
    private var runIdentifiers: [UUID: UUID] = [:]
    private var runCancellations: [UUID: CommandCancellation] = [:]
    private var lastModification: Date?

    init(store: DropzoneStore = DropzoneStore(),
         runner: CommandRunning = CommandRunner.shared,
         runRoot: URL = DropzoneCoordinator.defaultRunRoot,
         fileManager: FileManager = .default,
         preparePayload: @escaping (DropzoneConfig, DropzoneDrop, [DropItemInfo], URL) async throws -> DropzonePrepared = {
             zone, drop, items, directory in
             try await DropzonePreparer.prepare(zone: zone, drop: drop, items: items,
                                                workDirectory: directory)
         }) {
        self.store = store
        self.runner = runner
        self.runRoot = runRoot
        self.fileManager = fileManager
        self.preparePayload = preparePayload
        self.snapshot = store.load()
        self.lastModification = store.modificationDate()
    }

    /// `~/Library/Caches/MakiDesk/DropzoneRuns`.
    nonisolated static var defaultRunRoot: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("MakiDesk", isDirectory: true)
            .appendingPathComponent("DropzoneRuns", isDirectory: true)
    }

    var zones: [DropzoneConfig] { snapshot.zones }

    func zone(id: UUID) -> DropzoneConfig? {
        snapshot.zones.first { $0.id == id }
    }

    /// Hand edits are picked up before a run, without a file watcher.
    func reloadIfNeeded() {
        let modification = store.modificationDate()
        guard modification != lastModification else { return }
        reload()
    }

    /// Reads the file again unconditionally, for a factory reset or an explicit
    /// edit. Safe to call when the file is missing.
    func reload() {
        snapshot = store.load()
        lastModification = store.modificationDate()
    }

    func match(_ items: [DropItemInfo], zoneID: UUID) -> DropzoneMatch? {
        guard let zone = zone(id: zoneID) else { return nil }
        return DropzoneMatcher.match(items, zone: zone)
    }

    /// Stores the confirmation only if the command still matches what was shown.
    @discardableResult
    func confirm(zoneID: UUID, approvedCommandHash: String) -> Bool {
        snapshot = store.load()
        lastModification = store.modificationDate()
        guard snapshot.isRunnable else { return false }
        guard let index = snapshot.zones.firstIndex(where: { $0.id == zoneID }) else { return false }
        guard DropzoneConfig.confirmationHash(for: snapshot.zones[index].command) == approvedCommandHash else {
            reload()
            return false
        }
        snapshot.zones[index].markConfirmed()
        if case let .failure(error) = store.save(snapshot.zones) {
            makiLog.error("dropzones: could not store the confirmation: \(error.localizedDescription, privacy: .public)")
            return false
        } else {
            NotificationCenter.default.post(name: .makiDeskDropzonesChanged, object: nil)
        }
        lastModification = store.modificationDate()
        return true
    }

    func cancel(zoneID: UUID) async {
        guard let runID = runIdentifiers[zoneID] else { return }
        runCancellations[zoneID]?.cancel()
        await runner.cancel(runID)
    }

    /// Validates, prepares and runs one zone. Returns as soon as the command
    /// ends; a rejected drop never starts a process.
    func run(zoneID: UUID,
             drop: DropzoneDrop,
             confirmedOverwritePath: String? = nil) async -> Outcome {
        // Read the file again at drop time: permissions and contents may have
        // changed since the last edit, and a trust decision must be current.
        snapshot = store.load()
        lastModification = store.modificationDate()

        guard snapshot.isRunnable else {
            return .failed("The dropzone file is not trusted; open Settings to fix it.")
        }
        guard let zone = zone(id: zoneID) else {
            return .failed("This dropzone no longer exists.")
        }
        guard runningZones.contains(zoneID) == false else {
            return .failed("This dropzone is already running.")
        }
        let runID = UUID()
        let cancellation = CommandCancellation()
        runningZones.insert(zoneID)
        runIdentifiers[zoneID] = runID
        runCancellations[zoneID] = cancellation
        defer {
            runningZones.remove(zoneID)
            runIdentifiers[zoneID] = nil
            runCancellations[zoneID] = nil
        }

        let items = await DropzonePreparer.itemInfos(for: drop)
        guard !cancellation.isCancelled else { return .failed("The dropzone run was cancelled.") }
        switch DropzoneMatcher.match(items, zone: zone) {
        case let .rejected(reason):
            return .rejected(reason)
        case let .accepted(accepted):
            guard zone.requiresConfirmation == false else {
                return .needsConfirmation(zone)
            }

            let workDirectory = runRoot.appendingPathComponent(runID.uuidString, isDirectory: true)

            do {
                let prepared = try await preparePayload(zone, drop, accepted, workDirectory)
                guard !cancellation.isCancelled else {
                    try? fileManager.removeItem(at: workDirectory)
                    return .failed("The dropzone run was cancelled.")
                }
                if let expected = prepared.expectedOutput,
                   confirmedOverwritePath != expected,
                   fileManager.fileExists(atPath: expected) {
                    // Nothing ran: discard the prepared payload and ask again
                    // with `confirmedOverwrite` when the user accepts.
                    try? fileManager.removeItem(at: workDirectory)
                    return .needsOverwriteConfirmation(zone, path: expected)
                }
                let result = try await runner.run(prepared.command, id: runID,
                                                  includeStdout: zone.feedback.showOutput == .stdout,
                                                  cancellation: cancellation)
                if shouldKeep(prepared, zone: zone) == false {
                    try? fileManager.removeItem(at: workDirectory)
                }
                return .finished(result)
            } catch {
                try? fileManager.removeItem(at: workDirectory)
                return .failed(error.localizedDescription)
            }
        }
    }

    /// `reveal` keeps the run directory only when the command actually wrote
    /// something into `{outdir}`; an empty folder is not worth keeping.
    private func shouldKeep(_ prepared: DropzonePrepared, zone: DropzoneConfig) -> Bool {
        if prepared.command.keepWorkdir { return true }
        guard zone.feedback.revealOutput else { return false }
        let contents = try? fileManager.contentsOfDirectory(atPath: prepared.command.outputDirectory.path)
        return contents?.isEmpty == false
    }
}
