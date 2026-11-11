import Foundation
import MakiShared

/// The on-disk shape of the browser. Only model values are stored: no web
/// views, no page text and no summaries.
struct BrowserTabsPayload: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var tabs: [BrowserTab]
    var selectedTabID: UUID?
    var sidebarWidth: Double

    init(version: Int = BrowserTabsPayload.currentVersion,
         tabs: [BrowserTab],
         selectedTabID: UUID?,
         sidebarWidth: Double) {
        self.version = version
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.sidebarWidth = sidebarWidth
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? BrowserTabsPayload.currentVersion
        tabs = try container.decodeIfPresent([BrowserTab].self, forKey: .tabs) ?? []
        selectedTabID = try container.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        sidebarWidth = try container.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 264
    }
}

/// Atomic, versioned persistence for tabs and settings. The URLs are
/// injectable so tests never touch the user's Application Support.
struct BrowserTabStore {
    let fileURL: URL

    init(fileURL: URL = StoredJSONFile.defaultURL(named: "browser-tabs.json")) {
        self.fileURL = fileURL
    }

    /// Reads tabs, dropping old tabs that already passed 48 hours. Pinned tabs
    /// are never dropped. A corrupt file is quarantined and the browser starts
    /// clean instead of refusing to launch.
    func load(now: Date = Date()) -> BrowserTabsPayload {
        guard let data = try? Data(contentsOf: fileURL) else {
            return BrowserTabsPayload(tabs: [], selectedTabID: nil, sidebarWidth: 264)
        }
        do {
            var payload = try StoredJSONFile.decoder().decode(BrowserTabsPayload.self, from: data)
            payload.tabs.removeAll { BrowserTabLifecycle.isExpired($0, now: now) }
            if let selected = payload.selectedTabID,
               payload.tabs.contains(where: { $0.id == selected }) == false {
                payload.selectedTabID = payload.tabs.max {
                    $0.lastUsed < $1.lastUsed
                }?.id
            }
            return payload
        } catch {
            _ = StoredJSONFile.quarantine(fileURL, label: "browser-tabs")
            return BrowserTabsPayload(tabs: [], selectedTabID: nil, sidebarWidth: 264)
        }
    }

    @discardableResult
    func save(_ payload: BrowserTabsPayload) -> Bool {
        guard let data = try? StoredJSONFile.encoder().encode(payload) else { return false }
        do {
            try StoredJSONFile.write(data, to: fileURL)
            return true
        } catch {
            BrowserLog.store.error("browser-tabs: could not save -> \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

struct BrowserSettingsStore {
    let fileURL: URL

    init(fileURL: URL = StoredJSONFile.defaultURL(named: "browser-settings.json")) {
        self.fileURL = fileURL
    }

    func load() -> BrowserSettings {
        guard let data = try? Data(contentsOf: fileURL) else { return BrowserSettings() }
        do {
            return try StoredJSONFile.decoder().decode(BrowserSettings.self, from: data)
        } catch {
            _ = StoredJSONFile.quarantine(fileURL, label: "browser-settings")
            return BrowserSettings()
        }
    }

    @discardableResult
    func save(_ settings: BrowserSettings) -> Bool {
        guard let data = try? StoredJSONFile.encoder().encode(settings) else { return false }
        do {
            try StoredJSONFile.write(data, to: fileURL)
            return true
        } catch {
            BrowserLog.store.error("browser-settings: could not save -> \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
