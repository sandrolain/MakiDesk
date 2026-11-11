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
        case .down: return "Delete project"
        case .downVolumes: return "Down and remove volumes"
        }
    }

    public var isDestructive: Bool {
        self == .down || self == .downVolumes
    }

    public func arguments(compose: ComposeReference,
                          services: [String] = []) -> [String] {
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
            let selectedServices = Array(Set(services)).sorted()
            if selectedServices.isEmpty {
                // The group is built from existing containers. This fallback
                // starts them without asking Compose to select profile services.
                arguments.append("start")
            } else {
                // Explicit service names select profile-gated services and
                // allow Compose to recreate missing containers when needed.
                arguments.append(contentsOf: ["up", "--detach"])
                arguments.append(contentsOf: selectedServices)
            }
        case .stop:
            arguments.append("stop")
        case .restart:
            arguments.append(contentsOf: ["restart", "--timeout", "10"])
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

    public func explanation(all: Bool) -> String {
        switch self {
        case .basic: return explanation
        case .all: return explanation
        case .containers:
            return "Removes every stopped container (created, exited or dead). Docker has no narrower container-prune mode, so Prune and Prune all have the same scope. Running containers are kept."
        case .images:
            return all
                ? "Removes every image not used by a container, including tagged images. Images used by any container are kept. This may require downloading or rebuilding images later."
                : "Removes dangling images only. Tagged images and images used by a container are kept."
        case .volumes:
            return all
                ? "Removes every unused volume, including named volumes. Volumes attached to a container are kept. Data in removed volumes cannot be recovered."
                : "Removes unused anonymous volumes only. Named volumes and volumes attached to a container are kept."
        case .networks:
            return "Removes every unused user-defined network. Built-in networks and networks used by a container are kept. Docker has no separate all-networks prune mode, so both actions have the same scope."
        case .buildCache:
            return all
                ? "Removes all unused build cache, including non-dangling cache records. Future builds may take longer."
                : "Removes dangling build cache only. Other reusable cache records are kept."
        }
    }

    public func arguments(all: Bool) -> [String] {
        switch self {
        case .basic, .all:
            return arguments
        case .containers:
            return ["container", "prune", "--force"]
        case .images:
            return all
                ? ["image", "prune", "--all", "--force"]
                : ["image", "prune", "--force"]
        case .volumes:
            return all
                ? ["volume", "prune", "--all", "--force"]
                : ["volume", "prune", "--force"]
        case .networks:
            return ["network", "prune", "--force"]
        case .buildCache:
            return all
                ? ["builder", "prune", "--all", "--force"]
                : ["builder", "prune", "--force"]
        }
    }

    public func actionTitle(all: Bool) -> String {
        all ? "Prune all" : "Prune"
    }

    public var resourceTitle: String {
        switch self {
        case .containers: return "containers"
        case .images: return "images"
        case .volumes: return "volumes"
        case .networks: return "networks"
        case .buildCache: return "build cache"
        case .basic: return "resources"
        case .all: return "all resources"
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

    public static func stats() -> [String] {
        ["stats", "--no-stream", "--format", "{{json .}}"]
    }

    public static func logs(id: String, tail: Int, follow: Bool, timestamps: Bool) -> [String] {
        var arguments = ["logs", "--tail", "\(max(1, tail))"]
        if follow { arguments.append("--follow") }
        if timestamps { arguments.append("--timestamps") }
        arguments.append(id)
        return arguments
    }

    public static func imagePull(_ reference: String) -> [String] {
        ["image", "pull", reference]
    }

    public static func imageTag(_ source: String, as destination: String) -> [String] {
        ["image", "tag", source, destination]
    }

    public static func imagePush(_ reference: String) -> [String] {
        ["image", "push", reference]
    }

    public static func imageBuild(tag: String, context: String) -> [String] {
        ["build", "--tag", tag, context]
    }

    public static func imageSave(id: String, to path: String) -> [String] {
        ["image", "save", "--output", path, id]
    }

    public static func volumeCreate(_ name: String) -> [String] {
        ["volume", "create", name]
    }

    public static func networkCreate(_ name: String) -> [String] {
        ["network", "create", name]
    }

    public static func networkConnect(_ network: String, container: String) -> [String] {
        ["network", "connect", network, container]
    }

    public static func networkDisconnect(_ network: String, container: String) -> [String] {
        ["network", "disconnect", network, container]
    }

    public static func copyFile(from source: String, to destination: String) -> [String] {
        ["cp", source, destination]
    }
}

public enum DockerRunCommand {
    /// Recreates the inspectable container settings in a shell-safe CLI form.
    /// This deliberately omits daemon-managed identifiers and transient state.
    public static func make(container: DockerContainer,
                            inspect: DockerInspectSummary) -> String {
        var arguments = ["docker", "run", "--name", quote(container.name)]
        if inspect.restartPolicy.isEmpty == false && inspect.restartPolicy != "no" {
            arguments += ["--restart", quote(inspect.restartPolicy)]
        }
        for port in container.ports {
            guard let hostPort = port.hostPort else { continue }
            let hostIP = port.hostIP.map { $0.contains(":") && $0.hasPrefix("[") == false
                ? "[\($0)]" : $0 }
            let host = hostIP.map { "\($0):" } ?? ""
            arguments += ["-p", quote("\(host)\(hostPort):\(port.containerPort)/\(port.proto)")]
        }
        for mount in inspect.mountArguments {
            arguments += ["--mount", quote(mount)]
        }
        for entry in inspect.environment {
            arguments += ["-e", quote(entry)]
        }
        if let entrypoint = inspect.entrypoint.first {
            arguments += ["--entrypoint", quote(entrypoint)]
        }
        arguments.append(quote(container.image))
        arguments += inspect.entrypoint.dropFirst().map(quote)
        arguments += inspect.command.map(quote)
        return arguments.joined(separator: " ")
    }

    private static func quote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
