import Foundation

public enum DockerContainerAction: String, CaseIterable, Sendable {
    case start
    case stop
    case restart
    case pause
    case unpause
    case kill
    case remove

    public var title: String {
        switch self {
        case .start: return "Start"
        case .stop: return "Stop"
        case .restart: return "Restart"
        case .pause: return "Pause"
        case .unpause: return "Resume"
        case .kill: return "Kill"
        case .remove: return "Delete"
        }
    }

    public var isDestructive: Bool {
        self == .kill || self == .remove
    }

    public func arguments(containerID: String) -> [[String]] {
        switch self {
        case .start:
            return [["start", containerID]]
        case .stop:
            return [["stop", "--time", "10", containerID]]
        case .restart:
            return [["restart", "--time", "10", containerID]]
        case .pause:
            return [["pause", containerID]]
        case .unpause:
            return [["unpause", containerID]]
        case .kill:
            return [["kill", containerID]]
        case .remove:
            return [["stop", "--time", "10", containerID], ["rm", containerID]]
        }
    }
}

public enum DockerComposeAction: String, CaseIterable, Sendable {
    case start
    case stop
    case restart
    case down
    case downVolumes

    public var title: String {
        switch self {
        case .start: return "Start project"
        case .stop: return "Stop project"
        case .restart: return "Restart project"
        case .down: return "Down"
        case .downVolumes: return "Down and remove volumes"
        }
    }

    public var isDestructive: Bool {
        self == .down || self == .downVolumes
    }

    public func arguments(compose: ComposeReference) -> [String] {
        var arguments = ["compose"]
        if let workingDirectory = compose.workingDirectory {
            arguments.append(contentsOf: ["--project-directory", workingDirectory])
        }
        arguments.append(contentsOf: ["-p", compose.project])
        for file in compose.configFiles {
            arguments.append(contentsOf: ["-f", file])
        }
        switch self {
        case .start:
            arguments.append("start")
        case .stop:
            arguments.append("stop")
        case .restart:
            arguments.append(contentsOf: ["restart", "--time", "10"])
        case .down:
            arguments.append("down")
        case .downVolumes:
            arguments.append(contentsOf: ["down", "--volumes"])
        }
        return arguments
    }
}

public enum DockerPruneMode: String, CaseIterable, Sendable {
    case basic
    case all
    case containers
    case images
    case volumes
    case networks
    case buildCache

    public var title: String {
        switch self {
        case .basic: return "Prune"
        case .all: return "Prune all"
        case .containers: return "Prune containers"
        case .images: return "Prune images"
        case .volumes: return "Prune volumes"
        case .networks: return "Prune networks"
        case .buildCache: return "Prune build cache"
        }
    }

    public var explanation: String {
        switch self {
        case .basic:
            return "Removes stopped containers, dangling images, unused networks and build cache. Tagged images and volumes are kept."
        case .all:
            return "Removes stopped containers, all unused images, unused networks, build cache and all unused volumes, including named volumes. This cannot be undone."
        case .containers:
            return "Removes stopped containers."
        case .images:
            return "Removes images not used by any container."
        case .volumes:
            return "Removes volumes not used by any container."
        case .networks:
            return "Removes user-defined networks not used by any container."
        case .buildCache:
            return "Removes unused build cache."
        }
    }

    public var arguments: [String] {
        switch self {
        case .basic: return ["system", "prune", "--force"]
        case .all: return ["system", "prune", "--all", "--force", "--volumes"]
        case .containers: return ["container", "prune", "--force"]
        case .images: return ["image", "prune", "--all", "--force"]
        case .volumes: return ["volume", "prune", "--force"]
        case .networks: return ["network", "prune", "--force"]
        case .buildCache: return ["builder", "prune", "--all", "--force"]
        }
    }

    public var timeout: TimeInterval {
        self == .all || self == .images || self == .buildCache ? 600 : 120
    }
}

public enum DockerCommands {
    public static let containerFormat = [
        "{{json .}}",
        "{{.Label \"com.docker.compose.project\"}}",
        "{{.Label \"com.docker.compose.project.working_dir\"}}",
        "{{.Label \"com.docker.compose.project.config_files\"}}",
        "{{.Label \"com.docker.compose.service\"}}",
        "{{.Label \"com.docker.compose.oneoff\"}}",
    ].joined(separator: "\t")

    public static let volumeFormat = [
        "{{json .}}",
        "{{.Label \"com.docker.compose.project\"}}",
    ].joined(separator: "\t")

    public static let networkFormat = [
        "{{json .}}",
        "{{.Label \"com.docker.compose.project\"}}",
    ].joined(separator: "\t")

    public static func containers() -> [String] {
        ["ps", "-a", "--no-trunc", "--size", "--format", containerFormat]
    }

    public static func images() -> [String] {
        ["images", "--no-trunc", "--format", "{{json .}}"]
    }

    public static func volumes() -> [String] {
        ["volume", "ls", "--format", volumeFormat]
    }

    public static func networks() -> [String] {
        ["network", "ls", "--format", networkFormat]
    }

    public static func networkInspect(ids: [String]) -> [String] {
        ["network", "inspect"] + ids
    }

    public static func diskUsage() -> [String] {
        ["system", "df", "-v", "--format", "{{json .}}"]
    }

    public static func contexts() -> [String] {
        ["context", "ls", "--format", "{{json .}}"]
    }

    public static func daemonVersion() -> [String] {
        ["version", "--format", "{{.Server.Version}}"]
    }

    public static func inspect(id: String) -> [String] {
        ["inspect", id]
    }

    public static func stats(id: String) -> [String] {
        ["stats", "--no-stream", "--format", "{{json .}}", id]
    }

    public static func logs(id: String, tail: Int, follow: Bool, timestamps: Bool) -> [String] {
        var arguments = ["logs", "--tail", "\(max(1, tail))"]
        if follow { arguments.append("--follow") }
        if timestamps { arguments.append("--timestamps") }
        arguments.append(id)
        return arguments
    }
}
