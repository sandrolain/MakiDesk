import Darwin
import Foundation

/// Reads and writes `~/Library/Application Support/MakiDesk/dropzones.json`.
///
/// Same envelope and guarantees as `GroupStore`: one atomically written file,
/// a corrupt file set aside instead of overwritten, and no silent migration. On
/// top of that, a dropzone file contains commands, so it is only considered
/// runnable when it is a regular file owned by the user and not writable by
/// group or others.
struct DropzoneStore {
    enum State: Equatable, Sendable {
        /// No file yet: an empty configuration the user can fill in.
        case missing
        case loaded
        /// The file could not be decoded; it was moved aside.
        case corrupt
        /// Written by a newer version of the app: read-only, never touched.
        case futureVersion(Int)
        /// A symlink or a file someone else can modify: shown, never run.
        case untrustedPermissions
    }

    struct Snapshot: Equatable, Sendable {
        var zones: [DropzoneConfig]
        var version: Int
        var state: State

        /// A future or untrusted file must not execute anything.
        var isRunnable: Bool {
            switch state {
            case .missing, .loaded, .corrupt: return true
            case .futureVersion, .untrustedPermissions: return false
            }
        }

        var isTrusted: Bool {
            if case .untrustedPermissions = state { return false }
            return true
        }

        var canSave: Bool {
            if case .futureVersion = state { return false }
            return true
        }
    }

    enum StoreError: Error, Equatable, LocalizedError {
        case tooManyZones(Int)
        case duplicateID(UUID)
        case invalidZone(index: Int, message: String)
        case futureVersion(Int)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case let .tooManyZones(count):
                return "Too many dropzones (\(count)); the limit is \(DropzoneStore.maximumZones)."
            case let .duplicateID(id):
                return "Two dropzones share the same identifier (\(id.uuidString))."
            case let .invalidZone(index, message):
                return "Dropzone \(index + 1): \(message)"
            case let .futureVersion(version):
                return "This file was written by a newer MakiDesk (version \(version)); it is read-only."
            case let .writeFailed(message):
                return "Could not save the dropzones: \(message)"
            }
        }
    }

    static let currentVersion = 1
    static let maximumZones = 24
    static let filePermissions: NSNumber = 0o600

    let fileURL: URL

    init(fileURL: URL = DropzoneStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/MakiDesk/dropzones.json`.
    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("MakiDesk", isDirectory: true)
            .appendingPathComponent("dropzones.json")
    }

    // MARK: - Reading

    /// Never throws: the app must start even with a bad file. The state says
    /// what happened so the editor can explain it.
    func load() -> Snapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Snapshot(zones: [], version: Self.currentVersion, state: .missing)
        }

        // A symlink is not a configuration the user wrote: do not follow it.
        var info = stat()
        guard lstat(fileURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return Snapshot(zones: [], version: Self.currentVersion, state: .untrustedPermissions)
        }
        let trusted = info.st_uid == geteuid() && (info.st_mode & 0o022) == 0

        guard let data = try? Data(contentsOf: fileURL) else {
            return Snapshot(zones: [], version: Self.currentVersion, state: .corrupt)
        }

        if let header = try? Self.makeDecoder().decode(VersionHeader.self, from: data),
           header.version > Self.currentVersion {
            let zones = (try? Self.makeDecoder().decode(Payload.self, from: data))?.zones ?? []
            return Snapshot(zones: zones, version: header.version, state: .futureVersion(header.version))
        }

        guard let payload = try? Self.makeDecoder().decode(Payload.self, from: data) else {
            backUpCorruptFile()
            makiLog.error("dropzones: unreadable file set aside")
            return Snapshot(zones: [], version: Self.currentVersion, state: .corrupt)
        }

        return Snapshot(zones: payload.zones,
                        version: payload.version,
                        state: trusted ? .loaded : .untrustedPermissions)
    }

    /// Used before a run to notice a hand edit without a file watcher.
    func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
    }

    // MARK: - Writing

    func save(_ zones: [DropzoneConfig]) -> Result<Void, StoreError> {
        guard zones.count <= Self.maximumZones else { return .failure(.tooManyZones(zones.count)) }
        var identifiers = Set<UUID>()
        for (index, zone) in zones.enumerated() {
            guard identifiers.insert(zone.id).inserted else { return .failure(.duplicateID(zone.id)) }
            if let issue = zone.issues().first {
                return .failure(.invalidZone(index: index,
                                            message: issue.errorDescription ?? "Invalid dropzone."))
            }
        }
        if let header = currentVersionOnDisk(), header > Self.currentVersion {
            return .failure(.futureVersion(header))
        }

        let payload = Payload(zones: zones)
        guard let data = try? Self.makeEncoder().encode(payload) else {
            return .failure(.writeFailed("the configuration could not be encoded"))
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            // The commands live here: keep the file private even under a
            // permissive umask.
            try? FileManager.default.setAttributes([.posixPermissions: Self.filePermissions],
                                                   ofItemAtPath: fileURL.path)
            return .success(())
        } catch {
            makiLog.error("dropzones: could not save")
            return .failure(.writeFailed(error.localizedDescription))
        }
    }

    // MARK: - Helpers

    private struct VersionHeader: Codable {
        var version: Int

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? DropzoneStore.currentVersion
        }
    }

    struct Payload: Codable, Equatable {
        var version: Int
        var zones: [DropzoneConfig]

        init(version: Int = DropzoneStore.currentVersion, zones: [DropzoneConfig]) {
            self.version = version
            self.zones = zones
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? DropzoneStore.currentVersion
            zones = try container.decodeIfPresent([DropzoneConfig].self, forKey: .zones) ?? []
        }
    }

    /// ISO-8601 dates keep the hand-edited file readable. A fresh coder per
    /// call: the store is a value type and may be used from more than one
    /// queue, and `JSONDecoder`/`JSONEncoder` are not documented as reentrant.
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func currentVersionOnDisk() -> Int? {
        guard let data = try? Data(contentsOf: fileURL),
              let header = try? Self.makeDecoder().decode(VersionHeader.self, from: data) else { return nil }
        return header.version
    }

    private func backUpCorruptFile() {
        let base = fileURL.appendingPathExtension("bak")
        var backup = base
        var suffix = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = base.deletingPathExtension().appendingPathExtension("bak-\(suffix)")
            suffix += 1
        }
        try? FileManager.default.moveItem(at: fileURL, to: backup)
    }
}
