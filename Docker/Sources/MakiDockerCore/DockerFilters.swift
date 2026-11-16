public enum DockerContainerStateFilter: String, CaseIterable, Sendable {
    case defaultVisibility
    case all
    case running
    case stopped
    case paused
    case restarting
    case created
    case dead
    case removing
    case unknown

    public func includes(_ container: DockerContainer, showStopped: Bool) -> Bool {
        switch self {
        case .defaultVisibility:
            return showStopped || container.isRunning || container.isPaused
        case .all:
            return true
        case .running:
            return container.state == .running
        case .stopped:
            return container.isStopped
        case .paused:
            return container.state == .paused
        case .restarting:
            return container.state == .restarting
        case .created:
            return container.state == .created
        case .dead:
            return container.state == .dead
        case .removing:
            return container.state == .removing
        case .unknown:
            return container.state == .unknown
        }
    }

    public func title(showStopped: Bool) -> String {
        switch self {
        case .defaultVisibility:
            return showStopped ? "Default (all states)" : "Default (active only)"
        case .all: return "All states"
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .paused: return "Paused"
        case .restarting: return "Restarting"
        case .created: return "Created"
        case .dead: return "Dead"
        case .removing: return "Removing"
        case .unknown: return "Unknown"
        }
    }
}

public enum DockerContainerHealthFilter: String, CaseIterable, Sendable {
    case all
    case healthy
    case unhealthy
    case starting
    case noHealthcheck
    case unknown

    public func includes(_ health: DockerHealth) -> Bool {
        switch self {
        case .all: return true
        case .healthy: return health == .healthy
        case .unhealthy: return health == .unhealthy
        case .starting: return health == .starting
        case .noHealthcheck: return health == .none
        case .unknown: return health == .unknown
        }
    }
}

public enum DockerContainerSourceFilter: String, CaseIterable, Sendable {
    case all
    case compose
    case standalone

    public func includes(_ container: DockerContainer) -> Bool {
        switch self {
        case .all: return true
        case .compose: return container.compose != nil
        case .standalone: return container.compose == nil
        }
    }
}

public enum DockerImageFilter: String, CaseIterable, Sendable {
    case all
    case inUse
    case unused
    case dangling

    public func includes(_ image: DockerImage) -> Bool {
        switch self {
        case .all: return true
        case .inUse: return image.isUsed
        case .unused: return image.isUsed == false
        case .dangling: return image.isDangling
        }
    }
}

public enum DockerVolumeFilter: String, CaseIterable, Sendable {
    case all
    case inUse
    case unused
    case anonymous
    case named

    public func includes(_ volume: DockerVolume) -> Bool {
        switch self {
        case .all: return true
        case .inUse: return volume.isUsed
        case .unused: return volume.isUsed == false
        case .anonymous: return volume.isAnonymous
        case .named: return volume.isAnonymous == false
        }
    }
}

public enum DockerNetworkFilter: String, CaseIterable, Sendable {
    case all
    case inUse
    case unused
    case builtIn
    case userDefined

    public func includes(_ network: DockerNetwork) -> Bool {
        switch self {
        case .all: return true
        case .inUse: return network.isUsed
        case .unused: return network.isUsed == false && network.isBuiltIn == false
        case .builtIn: return network.isBuiltIn
        case .userDefined: return network.isBuiltIn == false
        }
    }
}
