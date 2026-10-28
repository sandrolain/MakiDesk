import Foundation

/// Reads and writes `~/Library/Application Support/MakiDesk/shortcuts.json`
/// (T53 phase 2).
///
/// Same guarantees as the other stores: one atomically written file, a file
/// that cannot be decoded is set aside instead of overwritten, and a file from
/// a newer version is read-only. A missing or bad file means the defaults, so
/// the app always starts with working shortcuts.
struct ShortcutStore {
    enum State: Equatable, Sendable {
        case missing
        case loaded
        /// The file could not be decoded; it was moved aside.
        case corrupt
        /// Written by a newer version of the app: never touched.
        case futureVersion(Int)
    }

    struct Snapshot: Equatable, Sendable {
        var bindings: ShortcutBindings
        var version: Int
        var state: State

        var canSave: Bool {
            if case .futureVersion = state { return false }
            return true
        }
    }

    enum StoreError: Error, LocalizedError {
        case futureVersion(Int)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case let .futureVersion(version):
                return "This file was written by a newer MakiDesk (version \(version)); it is read-only."
            case let .writeFailed(message):
                return "Could not save the shortcuts: \(message)"
            }
        }
    }

    static let currentVersion = 1
    static let filePermissions: NSNumber = 0o600

    let fileURL: URL

    init(fileURL: URL = ShortcutStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/MakiDesk/shortcuts.json`.
    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("MakiDesk", isDirectory: true)
            .appendingPathComponent("shortcuts.json")
    }

    // MARK: - Reading

    /// Never throws: a bad file must not keep the shortcuts from working.
    func load() -> Snapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Snapshot(bindings: .defaults, version: Self.currentVersion, state: .missing)
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return Snapshot(bindings: .defaults, version: Self.currentVersion, state: .corrupt)
        }

        if let header = try? Self.makeDecoder().decode(VersionHeader.self, from: data),
           header.version > Self.currentVersion {
            return Snapshot(bindings: .defaults, version: header.version,
                            state: .futureVersion(header.version))
        }

        guard let payload = try? Self.makeDecoder().decode(Payload.self, from: data) else {
            backUpCorruptFile()
            makiLog.error("shortcuts: unreadable file set aside")
            return Snapshot(bindings: .defaults, version: Self.currentVersion, state: .corrupt)
        }

        let bindings = ShortcutBindings(overrides: ShortcutBindings.sanitized(payload.bindings ?? [:]))
        return Snapshot(bindings: bindings,
                        version: payload.version,
                        state: .loaded)
    }

    // MARK: - Writing

    func save(_ bindings: ShortcutBindings) -> Result<Void, StoreError> {
        if let header = currentVersionOnDisk(), header > Self.currentVersion {
            return .failure(.futureVersion(header))
        }
        let payload = Payload(bindings: ShortcutBindings.sanitized(bindings.overrides))
        guard let data = try? Self.makeEncoder().encode(payload) else {
            return .failure(.writeFailed("the shortcuts could not be encoded"))
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            // Combinations are configuration: keep the file private even under a
            // permissive umask.
            try? FileManager.default.setAttributes([.posixPermissions: Self.filePermissions],
                                                   ofItemAtPath: fileURL.path)
            return .success(())
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
    }

    /// Deletes the overrides for a factory reset; a newer file is left alone.
    @discardableResult
    func remove() -> Bool {
        guard load().canSave else { return false }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            return (error as NSError).code == CocoaError.fileNoSuchFile.rawValue
        }
    }

    // MARK: - Pieces

    private struct VersionHeader: Decodable {
        let version: Int
    }

    private struct Payload: Codable {
        var version: Int
        var bindings: [String: ShortcutOverride]?

        init(version: Int = ShortcutStore.currentVersion,
             bindings: [String: ShortcutOverride]?) {
            self.version = version
            self.bindings = bindings
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version)
                ?? ShortcutStore.currentVersion
            bindings = try container.decodeIfPresent([String: ShortcutOverride].self,
                                                     forKey: .bindings)
        }
    }

    /// A fresh coder per call: the store is a value type and `JSONDecoder` is
    /// not documented as reentrant.
    private static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func currentVersionOnDisk() -> Int? {
        guard let data = try? Data(contentsOf: fileURL),
              let header = try? Self.makeDecoder().decode(VersionHeader.self, from: data) else {
            return nil
        }
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
