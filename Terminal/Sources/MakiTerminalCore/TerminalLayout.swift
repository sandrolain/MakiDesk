import Foundation
import MakiShared

/// The helper's persisted layout: the workspaces, their split trees and which
/// one was selected. Directories ride along per pane so a restore can start
/// each shell where it was.
public struct TerminalLayout: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var workspaces: [TerminalWorkspace]
    public var selectedIndex: Int

    public init(version: Int = TerminalLayout.currentVersion,
                workspaces: [TerminalWorkspace],
                selectedIndex: Int = 0) {
        self.version = version
        self.workspaces = workspaces
        self.selectedIndex = selectedIndex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
            ?? TerminalLayout.currentVersion
        workspaces = try container.decodeIfPresent([TerminalWorkspace].self,
                                                   forKey: .workspaces) ?? []
        selectedIndex = try container.decodeIfPresent(Int.self, forKey: .selectedIndex) ?? 0
    }

    /// Clamped to a real workspace, so a hand-edited or older file cannot
    /// select nothing.
    public var normalizedSelectedIndex: Int {
        guard workspaces.isEmpty == false else { return 0 }
        return min(max(selectedIndex, 0), workspaces.count - 1)
    }
}

/// Reads and writes `~/Library/Application Support/MakiDesk/Terminal/workspaces.json`
/// with the same guarantees as the app's stores: atomic write, corrupt file
/// quarantined, newer version read-only.
public struct TerminalLayoutStore {
    public enum State: Equatable, Sendable {
        case missing
        case loaded
        case corrupt
        case futureVersion(Int)

        public var isWritable: Bool {
            if case .futureVersion = self { return false }
            return true
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public var layout: TerminalLayout
        public var state: State

        public var canSave: Bool { state.isWritable }
    }

    public static let currentVersion = TerminalLayout.currentVersion

    public let fileURL: URL

    public init(fileURL: URL = TerminalLayoutStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        TerminalSocketLocation.directory.appendingPathComponent("workspaces.json")
    }

    public func load() -> Snapshot {
        guard let data = try? Data(contentsOf: fileURL) else {
            return Snapshot(layout: TerminalLayout(workspaces: []), state: .missing)
        }
        let decoder = StoredJSONFile.decoder()
        if let version = (try? decoder.decode(VersionHeader.self, from: data))?.version,
           version > Self.currentVersion {
            let layout = (try? decoder.decode(TerminalLayout.self, from: data))
                ?? TerminalLayout(workspaces: [])
            return Snapshot(layout: layout, state: .futureVersion(version))
        }
        guard let layout = try? decoder.decode(TerminalLayout.self, from: data) else {
            StoredJSONFile.quarantine(fileURL, label: "terminal workspaces")
            return Snapshot(layout: TerminalLayout(workspaces: []), state: .corrupt)
        }
        return Snapshot(layout: layout, state: .loaded)
    }

    @discardableResult
    public func save(_ layout: TerminalLayout) -> Bool {
        if let version = versionOnDisk(), version > Self.currentVersion { return false }
        var payload = layout
        payload.version = Self.currentVersion
        guard let data = try? StoredJSONFile.encoder().encode(payload) else { return false }
        do {
            try StoredJSONFile.write(data, to: fileURL)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func remove() -> Bool {
        if let version = versionOnDisk(), version > Self.currentVersion { return false }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            return (error as NSError).code == CocoaError.fileNoSuchFile.rawValue
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
                ?? TerminalLayoutStore.currentVersion
        }
    }
}
