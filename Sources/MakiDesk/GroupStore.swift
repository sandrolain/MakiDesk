import Foundation
import MakiShared

/// Persists the numbered window groups to a small JSON file in Application
/// Support.
///
/// One file, written atomically (`Data.write(.atomic)` writes a temporary file
/// and renames it over the target), so a crash mid-write can never leave a
/// truncated file behind. A file that cannot be decoded is set aside as `.bak`
/// and the app starts clean: a bad write must never cost the user their groups
/// for good, and must never stop the app from running.
///
/// The file URL is injectable so the store can be unit-tested on a temporary
/// directory, without touching the real Application Support and without needing
/// accessibility permissions.
struct GroupStore {
    /// The on-disk envelope. `version` is written so a future shape can be
    /// recognised and migrated; a file without it is read leniently as the
    /// current version.
    struct Payload: Codable, Equatable {
        var version: Int
        var groups: [WindowGroup]

        init(version: Int = GroupStore.currentVersion, groups: [WindowGroup]) {
            self.version = version
            self.groups = groups
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? GroupStore.currentVersion
            groups = try container.decode([WindowGroup].self, forKey: .groups)
        }
    }

    /// v2 added the remembered arrangement (`WindowGroup.frames`, T15); v3
    /// removed the group's own layout (T18 — a group remembers an arrangement,
    /// never a preset). The version is informational: a v1 file has no `frames`
    /// and reads as an empty arrangement, and a `layout` written by v2 is simply
    /// ignored, so nothing has to be migrated.
    static let currentVersion = 3

    let fileURL: URL

    init(fileURL: URL = GroupStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/MakiDesk/groups.json`.
    static var defaultFileURL: URL { StoredJSONFile.defaultURL(named: "groups.json") }

    /// The groups written last, or an empty collection when there is nothing to
    /// read. A corrupt file is renamed to `<name>.bak` first, so the user can
    /// still recover it by hand.
    func load() -> [WindowGroup] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode(Payload.self, from: data).groups
        } catch {
            StoredJSONFile.quarantine(fileURL, label: "groups")
            return []
        }
    }

    /// Writes the groups atomically. The caller keeps its dirty state when this
    /// returns false so a later flush can retry without another user change.
    @discardableResult
    func save(_ groups: [WindowGroup]) -> Bool {
        let payload = Payload(groups: groups)
        guard let data = try? StoredJSONFile.encoder().encode(payload) else { return false }
        do {
            try StoredJSONFile.write(data, to: fileURL)
            return true
        } catch {
            MakiLog.store.error("groups: could not save -> \(error.localizedDescription, privacy: .public)")
            return false
        }
    }


}
