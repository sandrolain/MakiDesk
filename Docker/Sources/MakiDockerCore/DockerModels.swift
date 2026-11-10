import Foundation

public enum DockerContainerState: String, Codable, Sendable, CaseIterable {
    case running
    case exited
    case paused
    case restarting
    case created
    case dead
    case removing
    case unknown

    public init(raw: String) {
        self = DockerContainerState(rawValue: raw.lowercased()) ?? .unknown
    }

    public var label: String {
        switch self {
        case .running: return "Running"
        case .exited: return "Stopped"
        case .paused: return "Paused"
        case .restarting: return "Restarting"
        case .created: return "Created"
        case .dead: return "Dead"
        case .removing: return "Removing"
        case .unknown: return "Unknown"
        }
    }

    public var isRunning: Bool { self == .running || self == .restarting }
    public var isStopped: Bool { self == .exited || self == .created || self == .dead }
}

public enum DockerHealth: String, Codable, Sendable {
    case none
    case starting
    case healthy
    case unhealthy
    case unknown

    public init(raw: String) {
        self = DockerHealth(rawValue: raw.lowercased()) ?? .unknown
    }

    public var label: String {
        switch self {
        case .none: return "No healthcheck"
        case .starting: return "Starting"
        case .healthy: return "Healthy"
        case .unhealthy: return "Unhealthy"
        case .unknown: return "Unknown"
        }
    }
}

public struct DockerPortMapping: Identifiable, Equatable, Sendable {
    public let id: String
    public let hostIP: String?
    public let hostPort: Int?
    public let containerPort: Int
    public let proto: String

    public init(hostIP: String?, hostPort: Int?, containerPort: Int, proto: String) {
        self.hostIP = hostIP
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
        let host = hostPort.map(String.init) ?? "—"
        id = "\(hostIP ?? "*"):\(host)->\(containerPort)/\(proto)"
    }

    public var display: String {
        if let hostPort {
            return "\(hostPort) → \(containerPort)/\(proto)"
        }
        return "\(containerPort)/\(proto)"
    }

    public var openURL: URL? {
        guard proto == "tcp", let hostPort else { return nil }
        if let hostIP, hostIP != "0.0.0.0", hostIP != "::", hostIP != "[::]" {
            if hostIP.hasPrefix("127.") || hostIP == "::1" || hostIP == "[::1]" {
                return URL(string: "http://localhost:\(hostPort)")
            }
            return nil
        }
        return URL(string: "http://localhost:\(hostPort)")
    }
}

public struct ComposeReference: Equatable, Sendable {
    public let project: String
    public let service: String?
    public let workingDirectory: String?
    public let configFiles: [String]
    public let oneOff: Bool

    public init(project: String,
                service: String? = nil,
                workingDirectory: String? = nil,
                configFiles: [String] = [],
                oneOff: Bool = false) {
        self.project = project
        self.service = service
        self.workingDirectory = workingDirectory
        self.configFiles = configFiles
        self.oneOff = oneOff
    }

    public var groupKey: String {
        project + "|" + (workingDirectory ?? "")
    }

    public var filesExist: Bool {
        configFiles.isEmpty == false && configFiles.allSatisfy {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    public var workingDirectoryExists: Bool {
        guard let workingDirectory else { return false }
        return FileManager.default.fileExists(atPath: workingDirectory)
    }

    public var canRunCompose: Bool {
        filesExist && workingDirectoryExists
    }
}

public struct DockerContainer: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let image: String
    public let state: DockerContainerState
    public let status: String
    public let health: DockerHealth
    public let createdAt: String
    public let runningFor: String
    public let ports: [DockerPortMapping]
    public let networks: [String]
    public let mounts: String
    public let compose: ComposeReference?
    public let size: String?

    public init(id: String,
                name: String,
                image: String,
                state: DockerContainerState,
                status: String,
                health: DockerHealth,
                createdAt: String = "",
                runningFor: String = "",
                ports: [DockerPortMapping] = [],
                networks: [String] = [],
                mounts: String = "",
                compose: ComposeReference? = nil,
                size: String? = nil) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.health = health
        self.createdAt = createdAt
        self.runningFor = runningFor
        self.ports = ports
        self.networks = networks
        self.mounts = mounts
        self.compose = compose
        self.size = size
    }

    public var shortID: String { String(id.prefix(12)) }
    public var isRunning: Bool { state.isRunning }
    public var isPaused: Bool { state == .paused }
    public var isStopped: Bool { state.isStopped }

    public var groupKey: String {
        compose?.groupKey ?? "standalone"
    }

    public var displayPorts: String {
        ports.isEmpty ? "—" : ports.map(\.display).joined(separator: ", ")
    }

    public var matches: String {
        [name, image, status, compose?.project ?? "", compose?.service ?? ""]
            .joined(separator: " ")
            .lowercased()
    }
}

public struct DockerContainerGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let compose: ComposeReference?
    public let containers: [DockerContainer]

    public init(id: String,
                name: String,
                compose: ComposeReference?,
                containers: [DockerContainer]) {
        self.id = id
        self.name = name
        self.compose = compose
        self.containers = containers
    }

    public var runningCount: Int { containers.filter(\.isRunning).count }
    public var pausedCount: Int { containers.filter(\.isPaused).count }
    public var stoppedCount: Int { containers.filter(\.isStopped).count }
    public var totalCount: Int { containers.count }
    public var isStandalone: Bool { compose == nil }
    public var canRunCompose: Bool { compose?.canRunCompose ?? false }

    public var statusSummary: String {
        if runningCount > 0 { return "\(runningCount)/\(totalCount) running" }
        if pausedCount > 0 { return "\(pausedCount)/\(totalCount) paused" }
        return "\(totalCount) stopped"
    }
}

public struct DockerImage: Identifiable, Equatable, Sendable {
    public let id: String
    public let repoTags: [String]
    public let size: String
    public let uniqueSize: String?
    public let createdAt: String
    public let containers: Int
    public let digest: String?

    public init(id: String,
                repoTags: [String],
                size: String,
                uniqueSize: String? = nil,
                createdAt: String = "",
                containers: Int = 0,
                digest: String? = nil) {
        self.id = id
        self.repoTags = repoTags
        self.size = size
        self.uniqueSize = uniqueSize
        self.createdAt = createdAt
        self.containers = containers
        self.digest = digest
    }

    public var shortID: String { String(id.replacingOccurrences(of: "sha256:", with: "").prefix(12)) }
    public var primaryTag: String { repoTags.first ?? "<none>:<none>" }
    public var isDangling: Bool {
        repoTags.isEmpty || repoTags.allSatisfy { $0.contains("<none>") }
    }
    public var isUsed: Bool { containers > 0 }
    public var matches: String {
        ([primaryTag, shortID] + repoTags).joined(separator: " ").lowercased()
    }
}

public struct DockerVolume: Identifiable, Equatable, Sendable {
    public let name: String
    public let driver: String
    public let scope: String
    public let mountpoint: String
    public let composeProject: String?
    public let size: String?
    public let links: Int

    public init(name: String,
                driver: String,
                scope: String,
                mountpoint: String,
                composeProject: String? = nil,
                size: String? = nil,
                links: Int = 0) {
        self.name = name
        self.driver = driver
        self.scope = scope
        self.mountpoint = mountpoint
        self.composeProject = composeProject
        self.size = size
        self.links = links
    }

    public var id: String { name }
    public var isUsed: Bool { links > 0 }
    public var isAnonymous: Bool {
        name.count == 64 && name.allSatisfy(\.isHexDigit)
    }
    public var matches: String {
        [name, driver, composeProject ?? ""].joined(separator: " ").lowercased()
    }
}

public struct DockerNetworkContainer: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let ipv4: String?
    public let ipv6: String?

    public init(id: String, name: String, ipv4: String? = nil, ipv6: String? = nil) {
        self.id = id
        self.name = name
        self.ipv4 = ipv4
        self.ipv6 = ipv6
    }
}

public struct DockerNetwork: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let driver: String
    public let scope: String
    public let createdAt: String
    public let ipv4: Bool
    public let ipv6: Bool
    public let internalNetwork: Bool
    public let composeProject: String?
    public let subnet: String?
    public let gateway: String?
    public let containers: [DockerNetworkContainer]

    public init(id: String,
                name: String,
                driver: String,
                scope: String,
                createdAt: String = "",
                ipv4: Bool = true,
                ipv6: Bool = false,
                internalNetwork: Bool = false,
                composeProject: String? = nil,
                subnet: String? = nil,
                gateway: String? = nil,
                containers: [DockerNetworkContainer] = []) {
        self.id = id
        self.name = name
        self.driver = driver
        self.scope = scope
        self.createdAt = createdAt
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.internalNetwork = internalNetwork
        self.composeProject = composeProject
        self.subnet = subnet
        self.gateway = gateway
        self.containers = containers
    }

    public var isBuiltIn: Bool {
        ["bridge", "host", "none"].contains(name) && composeProject == nil
    }
    public var isUsed: Bool { containers.isEmpty == false }
    public var matches: String {
        [name, driver, composeProject ?? "", subnet ?? ""]
            .joined(separator: " ").lowercased()
    }
}

public struct DockerContext: Identifiable, Equatable, Sendable {
    public let name: String
    public let endpoint: String
    public let isCurrent: Bool
    public let description: String
    public let error: String?

    public init(name: String,
                endpoint: String,
                isCurrent: Bool,
                description: String = "",
                error: String? = nil) {
        self.name = name
        self.endpoint = endpoint
        self.isCurrent = isCurrent
        self.description = description
        self.error = error
    }

    public var id: String { name }
    public var isRemote: Bool {
        endpoint.hasPrefix("unix://") == false
    }
}

public struct DockerDiskUsageItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let size: String
    public let bytes: Int64?
    public let inUse: Bool

    public init(id: String,
                name: String,
                size: String,
                bytes: Int64?,
                inUse: Bool) {
        self.id = id
        self.name = name
        self.size = size
        self.bytes = bytes
        self.inUse = inUse
    }
}

public struct DockerDiskUsageCategory: Equatable, Sendable {
    public let title: String
    public let total: Int
    public let active: Int
    public let size: String
    public let bytes: Int64?
    public let reclaimable: String
    public let reclaimableBytes: Int64?
    public let items: [DockerDiskUsageItem]

    public init(title: String,
                total: Int,
                active: Int,
                size: String,
                bytes: Int64?,
                reclaimable: String,
                reclaimableBytes: Int64?,
                items: [DockerDiskUsageItem] = []) {
        self.title = title
        self.total = total
        self.active = active
        self.size = size
        self.bytes = bytes
        self.reclaimable = reclaimable
        self.reclaimableBytes = reclaimableBytes
        self.items = items
    }

    public static let empty = DockerDiskUsageCategory(
        title: "", total: 0, active: 0, size: "0 B",
        bytes: 0, reclaimable: "0 B", reclaimableBytes: 0
    )
}

public struct DockerDiskUsage: Equatable, Sendable {
    public let images: DockerDiskUsageCategory
    public let containers: DockerDiskUsageCategory
    public let volumes: DockerDiskUsageCategory
    public let buildCache: DockerDiskUsageCategory

    public init(images: DockerDiskUsageCategory,
                containers: DockerDiskUsageCategory,
                volumes: DockerDiskUsageCategory,
                buildCache: DockerDiskUsageCategory) {
        self.images = images
        self.containers = containers
        self.volumes = volumes
        self.buildCache = buildCache
    }

    public static let empty = DockerDiskUsage(
        images: .empty, containers: .empty, volumes: .empty, buildCache: .empty
    )

    public var totalBytes: Int64 {
        [images.bytes, containers.bytes, volumes.bytes, buildCache.bytes]
            .compactMap { $0 }.reduce(0, +)
    }

    public var reclaimableBytes: Int64 {
        [images.reclaimableBytes, containers.reclaimableBytes,
         volumes.reclaimableBytes, buildCache.reclaimableBytes]
            .compactMap { $0 }.reduce(0, +)
    }

    public var categories: [(key: String, category: DockerDiskUsageCategory)] {
        [("images", images), ("containers", containers),
         ("volumes", volumes), ("buildCache", buildCache)]
    }
}

public struct DockerContainerStats: Equatable, Sendable {
    public let cpuPercent: String
    public let memoryUsage: String
    public let memoryPercent: String
    public let networkIO: String
    public let blockIO: String
    public let pids: String
    public let name: String

    public init(cpuPercent: String,
                memoryUsage: String,
                memoryPercent: String,
                networkIO: String,
                blockIO: String,
                pids: String,
                name: String) {
        self.cpuPercent = cpuPercent
        self.memoryUsage = memoryUsage
        self.memoryPercent = memoryPercent
        self.networkIO = networkIO
        self.blockIO = blockIO
        self.pids = pids
        self.name = name
    }

    public static let empty = DockerContainerStats(
        cpuPercent: "—", memoryUsage: "—", memoryPercent: "—",
        networkIO: "—", blockIO: "—", pids: "—", name: ""
    )
}

public struct DockerInspectSummary: Equatable, Sendable {
    public let rawJSON: String
    public let environment: [String]
    public let labels: [String: String]
    public let mounts: [String]
    public let restartPolicy: String
    public let logDriver: String

    public init(rawJSON: String,
                environment: [String] = [],
                labels: [String: String] = [:],
                mounts: [String] = [],
                restartPolicy: String = "",
                logDriver: String = "") {
        self.rawJSON = rawJSON
        self.environment = environment
        self.labels = labels
        self.mounts = mounts
        self.restartPolicy = restartPolicy
        self.logDriver = logDriver
    }
}
