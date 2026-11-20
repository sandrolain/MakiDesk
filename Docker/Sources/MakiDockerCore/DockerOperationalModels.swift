import Foundation

/// Coalesces any number of user-requested refreshes during one active read
/// into exactly one follow-up request.
public struct DockerRefreshCoalescer: Sendable {
    private var hasPendingRequest = false

    public init() {}

    public mutating func request() {
        hasPendingRequest = true
    }

    public mutating func takePendingRequest() -> Bool {
        defer { hasPendingRequest = false }
        return hasPendingRequest
    }
}

public struct DockerProcess: Identifiable, Equatable, Sendable {
    public let pid: String
    public let parentPID: String
    public let user: String
    public let state: String
    public let cpuPercent: String
    public let memoryPercent: String
    public let elapsed: String
    public let command: String

    public var id: String { pid }

    public init(pid: String, parentPID: String, user: String, state: String,
                cpuPercent: String, memoryPercent: String, elapsed: String,
                command: String) {
        self.pid = pid
        self.parentPID = parentPID
        self.user = user
        self.state = state
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
        self.elapsed = elapsed
        self.command = command
    }
}

public enum DockerProcessParsing {
    /// Parses the fixed column order requested by DockerCommands.processes.
    /// The final command field is allowed to contain spaces.
    public static func parse(_ output: String) -> [DockerProcess] {
        let lines = output.split(whereSeparator: { $0.isNewline })
        guard lines.count > 1 else { return [] }

        return lines.dropFirst().compactMap { line in
            let columns = line.split(maxSplits: 7, omittingEmptySubsequences: true) {
                $0.isWhitespace
            }
            guard columns.count == 8 else { return nil }
            return DockerProcess(
                pid: String(columns[0]),
                parentPID: String(columns[1]),
                user: String(columns[2]),
                state: String(columns[3]),
                cpuPercent: String(columns[4]),
                memoryPercent: String(columns[5]),
                elapsed: String(columns[6]),
                command: String(columns[7])
            )
        }
    }
}

public struct DockerRegistryPage: Equatable, Sendable {
    public let url: URL
    public let registryName: String

    public init?(imageReference: String) {
        let reference = imageReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reference.isEmpty == false,
              reference.hasPrefix("sha256:") == false else { return nil }

        let withoutDigest = reference.split(separator: "@", maxSplits: 1,
                                            omittingEmptySubsequences: false).first.map(String.init) ?? reference
        var components = withoutDigest.split(separator: "/").map(String.init)
        guard components.isEmpty == false else { return nil }

        let first = components[0].lowercased()
        let hasExplicitRegistry = components.count > 1
            && (first.contains(".") || first.contains(":") || first == "localhost")
        let registry = hasExplicitRegistry ? components.removeFirst().lowercased() : "docker.io"
        guard components.isEmpty == false else { return nil }

        if let last = components.last,
           let colon = last.lastIndex(of: ":") {
            components[components.count - 1] = String(last[..<colon])
        }
        guard components.allSatisfy({ $0.isEmpty == false && $0 != "." && $0 != ".." }) else {
            return nil
        }

        if registry == "localhost" || registry.hasPrefix("localhost:")
            || registry.hasSuffix(".amazonaws.com") {
            return nil
        }

        let path: String
        let displayName: String
        var pageHost = registry
        switch registry {
        case "docker.io", "index.docker.io":
            pageHost = "hub.docker.com"
            let repository = components.count == 1
                ? ["library", components[0]] : components
            if repository.count == 2, repository[0] == "library" {
                path = "/_/\(repository[1])"
            } else {
                path = "/r/\(repository.joined(separator: "/"))"
            }
            displayName = "Docker Hub"
        case "ghcr.io":
            guard components.count >= 2 else { return nil }
            pageHost = "github.com"
            let owner = components[0]
            let package = components.dropFirst().joined(separator: "/")
            path = "/\(owner)/packages/container/package/\(package)"
            displayName = "GitHub Container Registry"
        case "quay.io":
            guard components.count >= 2 else { return nil }
            path = "/repository/\(components.joined(separator: "/"))"
            displayName = "Quay.io"
        default:
            // Registry hosts vary in whether they provide a browser UI. This
            // best-effort URL is useful for registries that serve repository
            // pages at the same host and path as their image reference.
            path = "/\(components.joined(separator: "/"))"
            displayName = registry
        }

        var urlComponents = URLComponents()
        urlComponents.scheme = "https"
        if let colon = pageHost.lastIndex(of: ":"),
           let port = Int(pageHost[pageHost.index(after: colon)...]),
           (1...65_535).contains(port) {
            urlComponents.host = String(pageHost[..<colon])
            urlComponents.port = port
        } else {
            urlComponents.host = pageHost
        }
        urlComponents.path = path
        guard let url = urlComponents.url else { return nil }
        self.url = url
        self.registryName = displayName
    }
}

public enum DockerAttentionReason: String, Equatable, Sendable {
    case unhealthy
    case restarting
    case dead
    case unknown

    public var title: String {
        switch self {
        case .unhealthy: return "Unhealthy"
        case .restarting: return "Restarting"
        case .dead: return "Dead"
        case .unknown: return "Unknown state"
        }
    }
}

public struct DockerAttentionItem: Identifiable, Equatable, Sendable {
    public let container: DockerContainer
    public let reason: DockerAttentionReason

    public var id: String { "\(container.id):\(reason.rawValue)" }

    public init?(container: DockerContainer) {
        self.container = container
        if container.health == .unhealthy {
            reason = .unhealthy
        } else {
            switch container.state {
            case .restarting: reason = .restarting
            case .dead: reason = .dead
            case .unknown: reason = .unknown
            default: return nil
            }
        }
    }
}

public enum DockerAttention {
    public static func items(for containers: [DockerContainer]) -> [DockerAttentionItem] {
        let fullyStoppedComposeGroups = Set(
            DockerGrouping.groups(containers)
                .filter { $0.isStandalone == false && $0.stoppedCount == $0.totalCount }
                .map(\.id)
        )
        return containers.compactMap { container in
            if container.health == .unhealthy,
               fullyStoppedComposeGroups.contains(container.groupKey) {
                return nil
            }
            return DockerAttentionItem(container: container)
        }
            .sorted { lhs, rhs in
                let nameOrder = lhs.container.name.localizedStandardCompare(rhs.container.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.id < rhs.id
            }
    }
}
