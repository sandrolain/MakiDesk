import Foundation
import MakiShared

struct BrowserHistoryEntry: Codable, Equatable, Identifiable {
    var url: URL
    var title: String
    var lastVisited: Date

    var id: String { url.absoluteString }
}

/// A small, local address-bar memory. It is not a browsing-history UI: entries
/// exist so typing in the address field can suggest a page already visited.
struct BrowserHistoryStore {
    let fileURL: URL

    init(fileURL: URL = StoredJSONFile.defaultURL(named: "browser-history.json")) {
        self.fileURL = fileURL
    }

    func load() -> [BrowserHistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try StoredJSONFile.decoder().decode([BrowserHistoryEntry].self, from: data)
        } catch {
            _ = StoredJSONFile.quarantine(fileURL, label: "browser-history")
            return []
        }
    }

    @discardableResult
    func save(_ entries: [BrowserHistoryEntry]) -> Bool {
        guard let data = try? StoredJSONFile.encoder().encode(entries) else { return false }
        do {
            try StoredJSONFile.write(data, to: fileURL)
            return true
        } catch {
            BrowserLog.store.error("browser-history: could not save -> \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
