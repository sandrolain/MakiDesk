import Foundation

/// The utility bar's buttons as the user arranged them (F1).
///
/// The catalog still owns behaviour: the file names ids that already exist and
/// carries only presentation — whether a button is shown, its order inside a
/// zone, and an optional title and symbol. An id the catalog no longer knows is
/// dropped on read, and a catalog button the file does not mention is appended
/// in catalog order, so an update that adds a button never needs a migration.
struct BarConfiguration: Codable, Equatable, Sendable {
    /// v1 is the first file. A missing version reads as the current one, as the
    /// other stores do; a newer version is shown read-only.
    static let currentVersion = 1

    struct Item: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var visible: Bool
        /// Optional overrides; absent or blank keeps the catalog's words and
        /// symbol, which is also what the settings checkboxes rely on.
        var title: String?
        var symbol: String?

        init(id: String, visible: Bool = true, title: String? = nil, symbol: String? = nil) {
            self.id = id
            self.visible = visible
            self.title = title
            self.symbol = symbol
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            visible = try container.decodeIfPresent(Bool.self, forKey: .visible) ?? true
            title = try container.decodeIfPresent(String.self, forKey: .title)
            symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        }
    }

    var version: Int
    var items: [Item]

    init(version: Int = BarConfiguration.currentVersion, items: [Item]) {
        self.version = version
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        items = try container.decodeIfPresent([Item].self, forKey: .items) ?? []
    }

    /// Every catalog button, visible and in catalog order: what a bar that was
    /// never configured shows, and what a reset restores.
    static var defaults: BarConfiguration {
        BarConfiguration(items: BarItemCatalog.planned.map { Item(id: $0.id) })
    }

    /// The old preference was a comma-separated list of hidden ids. It is read
    /// once, the first time the file is missing, and then dropped so deleting
    /// the file cannot resurrect a choice the user has since changed.
    static func migrated(fromLegacyHidden stored: String?) -> BarConfiguration? {
        guard let stored,
              stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        let known = Set(BarItemCatalog.hideable.map(\.id))
        let hidden = Set(stored.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter(known.contains))
        var configuration = defaults
        for index in configuration.items.indices {
            configuration.items[index].visible = !hidden.contains(configuration.items[index].id)
        }
        return configuration
    }

    /// The catalog with the file applied, in display order.
    ///
    /// The zones keep their fixed left-to-right order; the file decides the
    /// order inside each one. Ids the catalog does not know are dropped, and
    /// catalog ids the file omits are appended visible, so a new button from a
    /// later version still appears.
    func resolvedItems(_ catalog: [BarItem] = BarItemCatalog.planned,
                       includingHidden: Bool = false) -> [BarItem] {
        let known = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var entries: [String: Item] = [:]
        var order: [String] = []
        for entry in items where known[entry.id] != nil && entries[entry.id] == nil {
            entries[entry.id] = entry
            order.append(entry.id)
        }
        for item in catalog where entries[item.id] == nil {
            entries[item.id] = Item(id: item.id)
            order.append(item.id)
        }
        let ranked = order.enumerated().sorted { left, right in
            let leftRank = Self.rank(of: known[left.element]?.zone)
            let rightRank = Self.rank(of: known[right.element]?.zone)
            return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
        }
        return ranked.compactMap { position in
            guard let entry = entries[position.element],
                  let item = known[position.element] else { return nil }
            guard includingHidden || entry.visible else { return nil }
            return Self.applying(entry, to: item)
        }
    }

    /// A button the file does not mention stays visible: an absent entry must
    /// not hide something the catalog offers.
    func isVisible(_ id: String) -> Bool {
        items.first { $0.id == id }?.visible ?? true
    }

    mutating func setVisible(_ visible: Bool, for id: String) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].visible = visible
        } else {
            items.append(Item(id: id, visible: visible))
        }
    }

    private static func rank(of zone: BarItem.Zone?) -> Int {
        switch zone {
        case .utility?: return 0
        case .toggle?: return 1
        case .info?: return 2
        case .right?: return 3
        case nil: return 4
        }
    }

    private static func applying(_ entry: Item, to item: BarItem) -> BarItem {
        let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let symbol = entry.symbol?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard title.isEmpty == false || symbol.isEmpty == false else { return item }
        return BarItem(id: item.id,
                       title: title.isEmpty ? item.title : title,
                       symbol: symbol.isEmpty ? item.symbol : symbol,
                       zone: item.zone,
                       kind: item.kind,
                       priority: item.priority)
    }
}

/// Reads and writes `~/Library/Application Support/MakiDesk/utility-bar.json`.
///
/// Same guarantees as the other stores (R07): one atomically written file, a
/// corrupt one set aside instead of overwritten, and a newer version shown but
/// never rewritten. The path is injectable so the tests use a temporary file.
struct BarConfigurationStore {
    enum State: Equatable, Sendable {
        case missing
        case loaded
        /// The file could not be decoded; it was moved aside.
        case corrupt
        /// Written by a newer version of the app: read-only, never touched.
        case futureVersion(Int)

        var isWritable: Bool {
            if case .futureVersion = self { return false }
            return true
        }
    }

    struct Snapshot: Equatable, Sendable {
        var configuration: BarConfiguration
        var state: State

        var canSave: Bool { state.isWritable }
    }

    static let currentVersion = BarConfiguration.currentVersion

    let fileURL: URL

    init(fileURL: URL = BarConfigurationStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/MakiDesk/utility-bar.json`.
    static var defaultFileURL: URL { StoredJSONFile.defaultURL(named: "utility-bar.json") }

    /// Never throws: the bar must work even with a bad file. The state says
    /// what happened so Settings can explain it.
    func load() -> Snapshot {
        guard let data = try? Data(contentsOf: fileURL) else {
            return Snapshot(configuration: .defaults, state: .missing)
        }
        let decoder = StoredJSONFile.decoder()
        if let version = (try? decoder.decode(VersionHeader.self, from: data))?.version,
           version > Self.currentVersion {
            let configuration = (try? decoder.decode(BarConfiguration.self, from: data))
                ?? .defaults
            return Snapshot(configuration: configuration, state: .futureVersion(version))
        }
        guard let configuration = try? decoder.decode(BarConfiguration.self, from: data) else {
            StoredJSONFile.quarantine(fileURL, label: "utility bar")
            MakiLog.store.error("utility bar: unreadable buttons file set aside")
            return Snapshot(configuration: .defaults, state: .corrupt)
        }
        return Snapshot(configuration: configuration, state: .loaded)
    }

    /// Used when the bar appears, to notice a hand edit without a file watcher.
    func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate])
            as? Date
    }

    /// Writes atomically. A file from a newer version is left in place, which
    /// is why the return value matters: the caller keeps the old choice.
    @discardableResult
    func save(_ configuration: BarConfiguration) -> Bool {
        if let version = versionOnDisk(), version > Self.currentVersion {
            MakiLog.store.error("utility bar: left a newer buttons file in place")
            return false
        }
        let payload = BarConfiguration(version: Self.currentVersion, items: configuration.items)
        guard let data = try? StoredJSONFile.encoder().encode(payload) else { return false }
        do {
            try StoredJSONFile.write(data, to: fileURL)
            return true
        } catch {
            MakiLog.store.error(
                "utility bar: could not save the buttons file -> \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Deletes the file for a factory reset. A file written by a newer version
    /// is left in place; a missing file is already the goal.
    @discardableResult
    func remove() -> Bool {
        if let version = versionOnDisk(), version > Self.currentVersion { return false }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            let code = (error as NSError).code
            if code == CocoaError.fileNoSuchFile.rawValue { return true }
            MakiLog.store.error("utility bar: could not remove the buttons file")
            return false
        }
    }

    private func versionOnDisk() -> Int? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return (try? StoredJSONFile.decoder().decode(VersionHeader.self, from: data))?.version
    }

    private struct VersionHeader: Decodable {
        var version: Int

        private enum CodingKeys: String, CodingKey {
            case version
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version)
                ?? BarConfigurationStore.currentVersion
        }
    }
}
