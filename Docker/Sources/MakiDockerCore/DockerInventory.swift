import Foundation

/// Runs the read-only Docker commands and turns their output into values. It
/// has no UI state and no cache: callers own freshness and generations.
public struct DockerReader: Sendable {
    public let cli: DockerCLI

    public init(cli: DockerCLI) {
        self.cli = cli
    }

    /// Parsing is deliberately off the caller's executor: a list can be a few
    /// thousand lines and `system df -v` carries nested arrays. The main actor
    /// only receives the finished value.
    private func parse<T: Sendable>(_ output: String,
                                    _ transform: @escaping @Sendable (String) -> T) async -> T {
        await Task.detached(priority: .utility) { transform(output) }.value
    }

    public func containers() async throws -> [DockerContainer] {
        let output = try await cli.runChecked(DockerCommands.containers(), timeout: 20)
        return await parse(output) { DockerJSON.containers(from: $0) }
    }

    public func images() async throws -> [DockerImage] {
        let output = try await cli.runChecked(DockerCommands.images(), timeout: 20)
        return await parse(output) { DockerJSON.images(from: $0) }
    }

    public func volumes() async throws -> [DockerVolume] {
        let output = try await cli.runChecked(DockerCommands.volumes(), timeout: 20)
        return await parse(output) { DockerJSON.volumes(from: $0) }
    }

    public func networks() async throws -> [DockerNetwork] {
        let output = try await cli.runChecked(DockerCommands.networks(), timeout: 20)
        let listed = await parse(output) { DockerJSON.networks(from: $0) }
        guard listed.isEmpty == false else { return [] }
        do {
            let detailsOutput = try await cli.runChecked(
                DockerCommands.networkInspect(ids: listed.map(\.id)),
                timeout: 20
            )
            return await parse(detailsOutput) { details in
                DockerJSON.mergingNetworkDetails(
                    listed,
                    details: DockerJSON.networkDetails(from: details)
                )
            }
        } catch {
            // A network can disappear between the list and the inspect. The
            // list is still useful without the details.
            return listed
        }
    }

    public func diskUsage() async throws -> DockerDiskUsage {
        let output = try await cli.runChecked(DockerCommands.diskUsage(), timeout: 30)
        return await parse(output) { DockerJSON.diskUsage(from: $0) }
    }

    public func contexts() async throws -> [DockerContext] {
        // The context list is global: asking it with `--context` would make a
        // broken override hide the very list needed to repair it.
        let output = try await cli.withContext(nil)
            .runChecked(DockerCommands.contexts(), timeout: 15)
        return await parse(output) { DockerJSON.contexts(from: $0) }
    }

    public func daemonVersion() async throws -> String {
        let output = try await cli.runChecked(DockerCommands.daemonVersion(), timeout: 15)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func inspect(id: String) async throws -> DockerInspectSummary {
        let output = try await cli.runChecked(DockerCommands.inspect(id: id), timeout: 20)
        return await parse(output) { DockerJSON.inspect(from: $0) }
    }

    public func stats(id: String) async throws -> DockerContainerStats {
        let output = try await cli.runChecked(DockerCommands.stats(id: id), timeout: 10)
        return await parse(output) { DockerJSON.stats(from: $0) }
    }

    public func stats() async throws -> [String: DockerContainerStats] {
        let output = try await cli.runChecked(DockerCommands.stats(), timeout: 15)
        return await parse(output) { DockerJSON.statsByName(from: $0) }
    }
}

public enum DockerGrouping {
    /// Groups compose containers by project and working directory; everything
    /// else becomes one Standalone group. Order is deterministic: running
    /// projects first, then name, with Standalone last.
    public static func groups(_ containers: [DockerContainer]) -> [DockerContainerGroup] {
        var groups: [String: [DockerContainer]] = [:]
        for container in containers {
            groups[container.groupKey, default: []].append(container)
        }
        var result: [DockerContainerGroup] = []
        for (key, members) in groups {
            let compose = members.first?.compose
            let name = compose?.project ?? "Standalone"
            let sorted = members.sorted { lhs, rhs in
                let nameOrder = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                if lhs.state != rhs.state { return lhs.state.rawValue < rhs.state.rawValue }
                return lhs.id < rhs.id
            }
            result.append(DockerContainerGroup(
                id: key,
                name: name,
                compose: compose,
                containers: sorted
            ))
        }
        return result.sorted { lhs, rhs in
            if lhs.isStandalone != rhs.isStandalone { return rhs.isStandalone }
            if lhs.runningCount != rhs.runningCount { return lhs.runningCount > rhs.runningCount }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

public enum DockerContainerSortOrder: String, CaseIterable, Sendable {
    case name
    case state
    case cpu
    case memory

    public var title: String {
        switch self {
        case .name: return "Name (A–Z)"
        case .state: return "State"
        case .cpu: return "CPU (high to low)"
        case .memory: return "Memory (high to low)"
        }
    }
}

public enum DockerContainerOrdering {
    /// Sorts the rows inside a project group. Missing metric samples stay last;
    /// display name and stable ID break ties.
    public static func sort(_ containers: [DockerContainer],
                            by order: DockerContainerSortOrder,
                            stats: [String: DockerContainerStats] = [:]) -> [DockerContainer] {
        containers.sorted { lhs, rhs in
            let nameOrder = lhs.displayName.localizedStandardCompare(rhs.displayName)
            let namesBefore = nameOrder == .orderedSame ? lhs.id < rhs.id
                : nameOrder == .orderedAscending
            switch order {
            case .name:
                return namesBefore
            case .state:
                let left = stateRank(lhs.state)
                let right = stateRank(rhs.state)
                return left == right ? namesBefore : left < right
            case .cpu:
                return descending(metric: cpuValue(stats[lhs.name]),
                                  against: cpuValue(stats[rhs.name]),
                                  namesBefore: namesBefore)
            case .memory:
                return descending(metric: memoryValue(stats[lhs.name]),
                                  against: memoryValue(stats[rhs.name]),
                                  namesBefore: namesBefore)
            }
        }
    }

    private static func descending(metric lhs: Double?,
                                    against rhs: Double?,
                                    namesBefore: Bool) -> Bool {
        switch (lhs, rhs) {
        case let (left?, right?): return left == right ? namesBefore : left > right
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return namesBefore
        }
    }

    private static func cpuValue(_ stats: DockerContainerStats?) -> Double? {
        guard let value = stats?.cpuPercent, value.hasSuffix("%") else { return nil }
        return Double(value.dropLast())
    }

    private static func memoryValue(_ stats: DockerContainerStats?) -> Double? {
        guard let value = stats?.memoryUsage,
              let used = value.split(separator: "/", maxSplits: 1).first else { return nil }
        return DockerFormatting.bytes(from: String(used)).map(Double.init)
    }

    private static func stateRank(_ state: DockerContainerState) -> Int {
        switch state {
        case .running: return 0
        case .restarting: return 1
        case .paused: return 2
        case .created: return 3
        case .exited: return 4
        case .dead: return 5
        case .removing: return 6
        case .unknown: return 7
        }
    }
}

/// What a prune would remove, computed from the current inventory. It is an
/// estimate: Docker has no dry-run for `system prune`.
public struct DockerPrunePlan: Equatable, Sendable {
    public let stoppedContainers: [DockerContainer]
    public let danglingImages: [DockerImage]
    public let unusedImages: [DockerImage]
    public let unusedVolumes: [DockerVolume]
    public let unusedNetworks: [DockerNetwork]
    public let buildCache: DockerDiskUsageCategory
    public let containersReclaimableBytes: Int64

    public init(containers: [DockerContainer],
                images: [DockerImage],
                volumes: [DockerVolume],
                networks: [DockerNetwork],
                diskUsage: DockerDiskUsage) {
        stoppedContainers = containers.filter(\.isStopped)
        danglingImages = images.filter(\.isDangling)
        unusedImages = images.filter { $0.isUsed == false }
        unusedVolumes = volumes.filter { $0.isUsed == false }
        unusedNetworks = networks.filter { $0.isUsed == false && $0.isBuiltIn == false }
        buildCache = diskUsage.buildCache
        containersReclaimableBytes = diskUsage.containers.reclaimableBytes ?? 0
    }

    public var estimatedBytes: Int64 {
        imageBytes(unusedImages) + volumeBytes + containersReclaimableBytes
            + (buildCache.reclaimableBytes ?? 0)
    }

    public var estimatedSize: String {
        DockerFormatting.size(estimatedBytes)
    }

    public func estimatedBytes(for mode: DockerPruneMode) -> Int64 {
        switch mode {
        case .basic:
            return imageBytes(danglingImages) + containersReclaimableBytes
                + (buildCache.reclaimableBytes ?? 0)
        case .all:
            return estimatedBytes
        case .containers:
            return containersReclaimableBytes
        case .images:
            return imageBytes(unusedImages)
        case .volumes:
            return volumeBytes
        case .networks:
            return 0
        case .buildCache:
            return buildCache.reclaimableBytes ?? 0
        }
    }

    public func estimatedSize(for mode: DockerPruneMode) -> String {
        DockerFormatting.size(estimatedBytes(for: mode))
    }

    public func estimatedSize(for mode: DockerPruneMode, all: Bool) -> String {
        let bytes: Int64
        switch mode {
        case .images:
            bytes = all ? imageBytes(unusedImages) : imageBytes(danglingImages)
        case .volumes:
            let eligible = unusedVolumes.filter { all || $0.isAnonymous }
            bytes = eligible.compactMap { DockerFormatting.bytes(from: $0.size ?? "0B") }
                .reduce(0, +)
        default:
            bytes = estimatedBytes(for: mode)
        }
        return DockerFormatting.size(bytes)
    }

    private var volumeBytes: Int64 {
        unusedVolumes.compactMap {
            DockerFormatting.bytes(from: $0.size ?? "0B")
        }.reduce(0, +)
    }

    private func imageBytes(_ images: [DockerImage]) -> Int64 {
        images.compactMap {
            DockerFormatting.bytes(from: $0.uniqueSize ?? $0.size)
        }.reduce(0, +)
    }
}
