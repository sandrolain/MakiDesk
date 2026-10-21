import Foundation

/// One-time move from the app's previous name.
///
/// The bundle identifier and the Application Support folder both changed with
/// the rename, so without this the groups file would look missing and every
/// setting would go back to its default. The old material is moved, not copied:
/// the new location is only written when it does not exist yet, and a marker key
/// makes the migration run once.
enum LegacyMigration {
    /// The bundle identifier the app used before the rename.
    static let previousBundleID = "com.orbitdesk.app"
    static let previousFolder = "OrbitDesk"
    static let currentFolder = "MakiDesk"

    private static let marker = "migratedFromPreviousName"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: marker) else { return }
        migrateSettings(from: previousBundleID, to: defaults)
        if migrateFolder(from: previousFolder, to: currentFolder) {
            defaults.set(true, forKey: marker)
        }
    }

    /// Copies the old bundle's preferences into the current domain, leaving any
    /// key that is already set alone (so a migration can never overwrite a
    /// choice made after the rename).
    private static func migrateSettings(from bundleID: String, to defaults: UserDefaults) {
        guard let previous = defaults.persistentDomain(forName: bundleID) else { return }
        for (key, value) in previous where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    /// Moves `Application Support/<old>` to `Application Support/<new>` when the
    /// new folder does not exist yet. Anything left in place is left on purpose:
    /// a half-moved folder is worse than a copy that can be re-done.
    @discardableResult
    static func migrateFolder(from oldName: String, to newName: String, in base: URL? = nil) -> Bool {
        let fileManager = FileManager.default
        let root = base ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let old = root.appendingPathComponent(oldName, isDirectory: true)
        let new = root.appendingPathComponent(newName, isDirectory: true)
        guard fileManager.fileExists(atPath: old.path),
              !fileManager.fileExists(atPath: new.path) else { return true }
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try fileManager.moveItem(at: old, to: new)
            return true
        } catch {
            makiLog.error("migration: could not move legacy folder -> \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
