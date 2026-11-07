import Foundation
import os

/// One JSON file, with the guarantees every store kept repeating (R07).
///
/// Four stores — groups, checklist, dropzones, shortcuts — each carried its own
/// copy of the same three mechanics: the path under Application Support, the
/// atomic write that creates the folder first, and the quarantine that moves an
/// unreadable file to `name.bak`, `name.bak-1`, … instead of overwriting it.
/// The copies had already drifted: one logged the recovery, another did not.
///
/// What stays in each store is what actually differs: its envelope, its
/// version, and what it returns when the file is missing or unreadable.
public enum StoredJSONFile {
    private static let log = Logger(subsystem: "com.makidesk.shared", category: "store")

    /// `~/Library/Application Support/MakiDesk/<name>`.
    public static func defaultURL(named name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("MakiDesk", isDirectory: true)
            .appendingPathComponent(name)
    }

    /// A fresh coder per call: the stores are value types and `JSONDecoder` is
    /// not documented as reentrant.
    public static func decoder() -> JSONDecoder { JSONDecoder() }

    /// Pretty-printed and key-sorted, so the file stays readable and two files
    /// differing in content differ in their diff too.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Writes atomically — a temporary file renamed over the target — so a
    /// crash mid-write cannot leave a truncated one. Creates the folder first.
    public static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Moves an unreadable file out of the way without deleting earlier
    /// recovery copies. Returns where it went, or `nil` when the move failed —
    /// in which case the source is untouched and still the only copy.
    @discardableResult
    public static func quarantine(_ url: URL, label: String) -> URL? {
        let base = url.appendingPathExtension("bak")
        var backup = base
        var suffix = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = base.deletingPathExtension().appendingPathExtension("bak-\(suffix)")
            suffix += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            log.error("\(label, privacy: .public): unreadable file set aside at \(backup.lastPathComponent, privacy: .public)")
            return backup
        } catch {
            log.error("\(label, privacy: .public): could not preserve unreadable file -> \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
