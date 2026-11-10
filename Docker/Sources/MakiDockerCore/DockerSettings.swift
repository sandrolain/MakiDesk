import Foundation
import MakiShared

/// The Docker helper's local preferences. The helper is the only writer; the
/// theme file is written by MakiDesk.
public struct DockerSettingsDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var refreshInterval: Double
    public var statsInterval: Double
    public var defaultShell: String
    public var confirmDestructiveActions: Bool
    public var showStoppedContainers: Bool
    public var dockerPath: String?
    public var contextName: String?
    public var logTail: Int
    public var logBufferLines: Int

    public init(version: Int = DockerSettingsDocument.currentVersion,
                refreshInterval: Double = 5,
                statsInterval: Double = 2,
                defaultShell: String = "sh",
                confirmDestructiveActions: Bool = true,
                showStoppedContainers: Bool = true,
                dockerPath: String? = nil,
                contextName: String? = nil,
                logTail: Int = 500,
                logBufferLines: Int = 20_000) {
        self.version = version
        self.refreshInterval = refreshInterval
        self.statsInterval = statsInterval
        self.defaultShell = defaultShell
        self.confirmDestructiveActions = confirmDestructiveActions
        self.showStoppedContainers = showStoppedContainers
        self.dockerPath = dockerPath
        self.contextName = contextName
        self.logTail = logTail
        self.logBufferLines = logBufferLines
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
            ?? Self.currentVersion
        refreshInterval = try container.decodeIfPresent(Double.self, forKey: .refreshInterval) ?? 5
        statsInterval = try container.decodeIfPresent(Double.self, forKey: .statsInterval) ?? 2
        defaultShell = try container.decodeIfPresent(String.self, forKey: .defaultShell) ?? "sh"
        confirmDestructiveActions = try container.decodeIfPresent(Bool.self,
                                                                  forKey: .confirmDestructiveActions) ?? true
        showStoppedContainers = try container.decodeIfPresent(Bool.self,
                                                              forKey: .showStoppedContainers) ?? true
        dockerPath = try container.decodeIfPresent(String.self, forKey: .dockerPath)
        contextName = try container.decodeIfPresent(String.self, forKey: .contextName)
        logTail = try container.decodeIfPresent(Int.self, forKey: .logTail) ?? 500
        logBufferLines = try container.decodeIfPresent(Int.self, forKey: .logBufferLines) ?? 20_000
    }

    public static let defaults = DockerSettingsDocument()

    public func normalized() -> DockerSettingsDocument {
        var copy = self
        copy.version = Self.currentVersion
        copy.refreshInterval = min(max(refreshInterval, 2), 60)
        copy.statsInterval = min(max(statsInterval, 1), 10)
        if DockerExecValidation.isValidShell(defaultShell) == false {
            copy.defaultShell = "sh"
        }
        copy.logTail = min(max(logTail, 50), 5_000)
        copy.logBufferLines = min(max(logBufferLines, 1_000), 100_000)
        if let dockerPath, dockerPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.dockerPath = nil
        }
        if let contextName, contextName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.contextName = nil
        }
        return copy
    }
}
