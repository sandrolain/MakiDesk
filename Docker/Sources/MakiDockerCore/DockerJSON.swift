import Foundation

/// Tolerant parsers for the CLI's JSON. Docker's output is line-delimited in
/// some commands and a single array in others; both shapes are accepted, and
/// unknown fields are ignored.
public enum DockerJSON {
    // MARK: - Containers

    public static func containers(from output: String) -> [DockerContainer] {
        var result: [DockerContainer] = []
        for line in output.split(whereSeparator: { $0.isNewline }) {
            let text = String(line)
            guard text.trimmingCharacters(in: .whitespaces).isEmpty == false else { continue }
            let parts = text.split(separator: "\t", omittingEmptySubsequences: false)
            guard let first = parts.first,
                  let data = String(first).data(using: .utf8),
                  let raw = try? JSONDecoder().decode(RawContainer.self, from: data) else {
                continue
            }
            let labels = parts.dropFirst().map(String.init)
            result.append(container(from: raw, labels: labels))
        }
        return result
    }

    private static func container(from raw: RawContainer, labels: [String]) -> DockerContainer {
        let name = (raw.Names ?? "")
            .split(separator: ",", maxSplits: 1)
            .first.map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            ?? (raw.ID ?? "container")
        let project = labels.indices.contains(0) ? cleaned(labels[0]) : nil
        let workingDirectory = labels.indices.contains(1) ? cleaned(labels[1]) : nil
        let configFiles = labels.indices.contains(2)
            ? cleaned(labels[2])?.split(separator: ",").map(String.init) ?? []
            : []
        let service = labels.indices.contains(3) ? cleaned(labels[3]) : nil
        let oneOff = labels.indices.contains(4)
            ? labels[4].trimmingCharacters(in: .whitespaces).lowercased() == "true"
            : false
        let compose: ComposeReference? = project.map {
            ComposeReference(project: $0,
                             service: service,
                             workingDirectory: workingDirectory,
                             configFiles: configFiles,
                             oneOff: oneOff)
        }
        let state = DockerContainerState(raw: raw.State ?? "")
        return DockerContainer(
            id: raw.ID ?? "",
            name: name,
            image: raw.Image ?? "",
            state: state,
            status: raw.Status ?? "",
            health: DockerHealth(raw: raw.HealthStatus ?? "none"),
            createdAt: raw.CreatedAt ?? "",
            runningFor: raw.RunningFor ?? "",
            ports: DockerFormatting.ports(from: raw.Ports ?? ""),
            networks: (raw.Networks ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.isEmpty == false },
            mounts: raw.Mounts ?? "",
            compose: compose,
            size: cleaned(raw.Size)
        )
    }

    // MARK: - Images

    public static func images(from output: String) -> [DockerImage] {
        var byID: [String: DockerImage] = [:]
        var order: [String] = []
        for line in output.split(whereSeparator: { $0.isNewline }) {
            guard let data = String(line).data(using: .utf8),
                  let raw = try? JSONDecoder().decode(RawImage.self, from: data) else {
                continue
            }
            let id = raw.ID ?? UUID().uuidString
            let tag = imageTag(repository: raw.Repository, tag: raw.Tag)
            let containers = Int(raw.Containers ?? "") ?? 0
            let digest = cleaned(raw.Digest)
            if var existing = byID[id] {
                if let tag, existing.repoTags.contains(tag) == false {
                    existing = DockerImage(id: existing.id,
                                           repoTags: existing.repoTags + [tag],
                                           size: existing.size,
                                           uniqueSize: existing.uniqueSize,
                                           createdAt: existing.createdAt,
                                           containers: max(existing.containers, containers),
                                           digest: existing.digest ?? digest)
                }
                byID[id] = existing
            } else {
                order.append(id)
                byID[id] = DockerImage(
                    id: id,
                    repoTags: tag.map { [$0] } ?? [],
                    size: raw.Size ?? "—",
                    uniqueSize: cleaned(raw.UniqueSize),
                    createdAt: raw.CreatedAt ?? "",
                    containers: containers,
                    digest: digest
                )
            }
        }
        return order.compactMap { byID[$0] }
    }

    private static func imageTag(repository: String?, tag: String?) -> String? {
        guard let repository, repository != "<none>" else { return nil }
        guard let tag, tag != "<none>", tag.isEmpty == false else { return repository }
        return "\(repository):\(tag)"
    }

    public static func mergingDiskUsage(_ images: [DockerImage],
                                        with disk: DockerDiskUsage) -> [DockerImage] {
        let usage = disk.images.items
        return images.map { image in
            guard let match = usage.first(where: {
                image.id == $0.id || image.id.hasPrefix($0.id) || $0.id.hasPrefix(image.id)
            }) else { return image }
            return DockerImage(id: image.id,
                               repoTags: image.repoTags,
                               size: match.size,
                               uniqueSize: image.uniqueSize,
                               createdAt: image.createdAt,
                               containers: match.inUse ? max(1, image.containers) : 0,
                               digest: image.digest)
        }
    }

    // MARK: - Volumes

    public static func volumes(from output: String) -> [DockerVolume] {
        var result: [DockerVolume] = []
        for line in output.split(whereSeparator: { $0.isNewline }) {
            let parts = String(line).split(separator: "\t", omittingEmptySubsequences: false)
            guard let first = parts.first,
                  let data = String(first).data(using: .utf8),
                  let raw = try? JSONDecoder().decode(RawVolume.self, from: data) else {
                continue
            }
            let project = parts.count > 1 ? cleaned(String(parts[1])) : nil
            result.append(DockerVolume(
                name: raw.Name ?? "",
                driver: raw.Driver ?? "",
                scope: raw.Scope ?? "",
                mountpoint: raw.Mountpoint ?? "",
                composeProject: project
            ))
        }
        return result
    }

    public static func mergingDiskUsage(_ volumes: [DockerVolume],
                                        with disk: DockerDiskUsage) -> [DockerVolume] {
        let usage = disk.volumes.items
        return volumes.map { volume in
            guard let match = usage.first(where: { $0.name == volume.name }) else { return volume }
            return DockerVolume(name: volume.name,
                                driver: volume.driver,
                                scope: volume.scope,
                                mountpoint: volume.mountpoint,
                                composeProject: volume.composeProject,
                                size: match.size,
                                links: match.inUse ? max(1, volume.links) : 0)
        }
    }

    // MARK: - Networks

    public static func networks(from output: String) -> [DockerNetwork] {
        var result: [DockerNetwork] = []
        for line in output.split(whereSeparator: { $0.isNewline }) {
            let parts = String(line).split(separator: "\t", omittingEmptySubsequences: false)
            guard let first = parts.first,
                  let data = String(first).data(using: .utf8),
                  let raw = try? JSONDecoder().decode(RawNetwork.self, from: data) else {
                continue
            }
            let project = parts.count > 1 ? cleaned(String(parts[1])) : nil
            result.append(DockerNetwork(
                id: raw.ID ?? raw.Name ?? "",
                name: raw.Name ?? "",
                driver: raw.Driver ?? "",
                scope: raw.Scope ?? "",
                createdAt: raw.CreatedAt ?? "",
                ipv4: raw.IPv4?.lowercased() != "false",
                ipv6: raw.IPv6?.lowercased() == "true",
                internalNetwork: raw.Internal?.lowercased() == "true",
                composeProject: project
            ))
        }
        return result
    }

    public static func mergingNetworkDetails(_ networks: [DockerNetwork],
                                             details: [NetworkDetail]) -> [DockerNetwork] {
        networks.map { network in
            guard let detail = details.first(where: {
                $0.id == network.id || $0.name == network.name
            }) else { return network }
            return DockerNetwork(
                id: network.id,
                name: network.name,
                driver: network.driver,
                scope: network.scope,
                createdAt: network.createdAt,
                ipv4: network.ipv4,
                ipv6: network.ipv6,
                internalNetwork: network.internalNetwork,
                composeProject: network.composeProject,
                subnet: detail.subnet,
                gateway: detail.gateway,
                containers: detail.containers
            )
        }
    }

    public struct NetworkDetail: Equatable, Sendable {
        public let id: String
        public let name: String
        public let subnet: String?
        public let gateway: String?
        public let containers: [DockerNetworkContainer]

        public init(id: String,
                    name: String,
                    subnet: String? = nil,
                    gateway: String? = nil,
                    containers: [DockerNetworkContainer] = []) {
            self.id = id
            self.name = name
            self.subnet = subnet
            self.gateway = gateway
            self.containers = containers
        }
    }

    public static func networkDetails(from output: String) -> [NetworkDetail] {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        let array: [[String: Any]]
        if let list = json as? [[String: Any]] {
            array = list
        } else if let one = json as? [String: Any] {
            array = [one]
        } else {
            return []
        }
        return array.compactMap { object in
            guard let name = object["Name"] as? String else { return nil }
            let id = object["Id"] as? String ?? name
            let ipam = object["IPAM"] as? [String: Any]
            let config = (ipam?["Config"] as? [[String: Any]])?.first
            let containersObject = object["Containers"] as? [String: Any] ?? [:]
            let containers = containersObject.keys.sorted().compactMap { key -> DockerNetworkContainer? in
                guard let entry = containersObject[key] as? [String: Any] else { return nil }
                return DockerNetworkContainer(
                    id: key,
                    name: entry["Name"] as? String ?? key,
                    ipv4: entry["IPv4Address"] as? String,
                    ipv6: entry["IPv6Address"] as? String
                )
            }
            return NetworkDetail(
                id: id,
                name: name,
                subnet: config?["Subnet"] as? String,
                gateway: config?["Gateway"] as? String,
                containers: containers
            )
        }
    }

    // MARK: - Contexts

    public static func contexts(from output: String) -> [DockerContext] {
        var result: [DockerContext] = []
        for line in output.split(whereSeparator: { $0.isNewline }) {
            guard let data = String(line).data(using: .utf8),
                  let raw = try? JSONDecoder().decode(RawContext.self, from: data) else {
                continue
            }
            result.append(DockerContext(
                name: raw.Name ?? "",
                endpoint: raw.DockerEndpoint ?? "",
                isCurrent: raw.Current ?? false,
                description: raw.Description ?? "",
                error: cleaned(raw.Error)
            ))
        }
        return result
    }

    // MARK: - Disk usage

    public static func diskUsage(from output: String) -> DockerDiskUsage {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }

        let images = diskCategory(
            title: "Images",
            array: object["Images"] as? [[String: Any]] ?? [],
            id: { $0["ID"] as? String ?? UUID().uuidString },
            name: { dictionary in
                let repository = dictionary["Repository"] as? String ?? "<none>"
                let tag = dictionary["Tag"] as? String ?? "<none>"
                return tag == "<none>" ? repository : "\(repository):\(tag)"
            },
            size: { dictionary in
                sizeBytes(dictionary["UniqueSize"] as? String)
                    ?? sizeBytes(dictionary["Size"] as? String)
            },
            inUse: { dictionary in
                (Int(dictionary["Containers"] as? String ?? "") ?? 0) > 0
            }
        )

        let containers = diskCategory(
            title: "Containers",
            array: object["Containers"] as? [[String: Any]] ?? [],
            id: { $0["ID"] as? String ?? UUID().uuidString },
            name: { $0["Names"] as? String ?? "container" },
            size: { sizeBytes($0["Size"] as? String) },
            inUse: { dictionary in
                (dictionary["State"] as? String) == "running"
            }
        )

        let volumes = diskCategory(
            title: "Volumes",
            array: object["Volumes"] as? [[String: Any]] ?? [],
            id: { $0["Name"] as? String ?? UUID().uuidString },
            name: { $0["Name"] as? String ?? "volume" },
            size: { sizeBytes($0["Size"] as? String) },
            inUse: { dictionary in
                (Int(dictionary["Links"] as? String ?? "") ?? 0) > 0
            }
        )

        let buildCache = diskCategory(
            title: "Build cache",
            array: object["BuildCache"] as? [[String: Any]] ?? [],
            id: { $0["ID"] as? String ?? UUID().uuidString },
            name: { dictionary in
                let description = dictionary["Description"] as? String ?? ""
                return description.isEmpty ? "Cache entry" : description
            },
            size: { sizeBytes($0["Size"] as? String) },
            inUse: { dictionary in
                ((dictionary["InUse"] as? String) ?? "").lowercased() == "true"
            }
        )

        return DockerDiskUsage(images: images, containers: containers,
                               volumes: volumes, buildCache: buildCache)
    }

    private static func diskCategory(
        title: String,
        array: [[String: Any]],
        id: (([String: Any]) -> String),
        name: (([String: Any]) -> String),
        size: (([String: Any]) -> Int64?),
        inUse: (([String: Any]) -> Bool)
    ) -> DockerDiskUsageCategory {
        let items = array.map { dictionary -> DockerDiskUsageItem in
            let bytes = size(dictionary)
            return DockerDiskUsageItem(
                id: id(dictionary),
                name: name(dictionary),
                size: DockerFormatting.size(bytes),
                bytes: bytes,
                inUse: inUse(dictionary)
            )
        }
        let totalBytes = items.compactMap(\.bytes).reduce(0, +)
        let reclaimable = items.filter { $0.inUse == false }.compactMap(\.bytes).reduce(0, +)
        return DockerDiskUsageCategory(
            title: title,
            total: items.count,
            active: items.filter(\.inUse).count,
            size: DockerFormatting.size(totalBytes),
            bytes: totalBytes,
            reclaimable: DockerFormatting.size(reclaimable),
            reclaimableBytes: reclaimable,
            items: items.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        )
    }

    private static func sizeBytes(_ text: String?) -> Int64? {
        guard let cleaned = text.flatMap(cleanSize) else { return nil }
        return DockerFormatting.bytes(from: cleaned)
    }

    /// `docker system df -v` can print `0B (virtual 311MB)`; the first token is
    /// the writable size, the parenthesised one is informational.
    private static func cleanSize(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed.uppercased() != "N/A" else { return nil }
        return trimmed.split(separator: " ").first.map(String.init) ?? trimmed
    }

    // MARK: - Stats / inspect

    public static func stats(from output: String) -> DockerContainerStats {
        guard let data = output.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawStats.self, from: data) else {
            return .empty
        }
        return DockerContainerStats(
            cpuPercent: raw.CPUPerc ?? "—",
            memoryUsage: raw.MemUsage ?? "—",
            memoryPercent: raw.MemPerc ?? "—",
            networkIO: raw.NetIO ?? "—",
            blockIO: raw.BlockIO ?? "—",
            pids: raw.PIDs ?? "—",
            name: raw.Name ?? ""
        )
    }

    public static func inspect(from output: String) -> DockerInspectSummary {
        let pretty = redactedPrettyPrinted(output) ?? prettyPrinted(output) ?? output
        guard let data = output.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let object = array.first else {
            return DockerInspectSummary(rawJSON: pretty)
        }
        let config = object["Config"] as? [String: Any]
        let host = object["HostConfig"] as? [String: Any]
        let env = config?["Env"] as? [String] ?? []
        let labels = config?["Labels"] as? [String: String] ?? [:]
        let mounts = (object["Mounts"] as? [[String: Any]] ?? []).compactMap { mount -> String? in
            guard let destination = mount["Destination"] as? String else { return nil }
            let source = mount["Source"] as? String ?? ""
            let type = mount["Type"] as? String ?? "mount"
            let readOnly = (mount["RW"] as? Bool) == false ? " (ro)" : ""
            return "\(type): \(source) → \(destination)\(readOnly)"
        }
        let restart = (host?["RestartPolicy"] as? [String: Any])?["Name"] as? String ?? ""
        let logDriver = (host?["LogConfig"] as? [String: Any])?["Type"] as? String ?? ""
        return DockerInspectSummary(rawJSON: pretty,
                                    environment: env,
                                    labels: labels,
                                    mounts: mounts,
                                    restartPolicy: restart,
                                    logDriver: logDriver)
    }

    /// Inspect JSON can carry secrets in `Config.Env`; the raw view hides the
    /// values while the dedicated environment section can reveal them.
    private static func redactedPrettyPrinted(_ output: String) -> String? {
        guard let data = output.data(using: .utf8),
              var array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              var object = array.first,
              var config = object["Config"] as? [String: Any],
              let environment = config["Env"] as? [String] else {
            return prettyPrinted(output)
        }
        config["Env"] = environment.map { entry in
            guard let equals = entry.firstIndex(of: "=") else { return entry }
            return String(entry[..<equals]) + "=••••"
        }
        object["Config"] = config
        array[0] = object
        guard let data = try? JSONSerialization.data(withJSONObject: array,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    public static func prettyPrinted(_ output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Raw records

private struct RawContainer: Decodable {
    let ID: String?
    let Names: String?
    let Image: String?
    let State: String?
    let Status: String?
    let HealthStatus: String?
    let Ports: String?
    let Mounts: String?
    let Networks: String?
    let CreatedAt: String?
    let RunningFor: String?
    let Size: String?
}

private struct RawImage: Decodable {
    let ID: String?
    let Repository: String?
    let Tag: String?
    let Size: String?
    let UniqueSize: String?
    let CreatedAt: String?
    let Containers: String?
    let Digest: String?
}

private struct RawVolume: Decodable {
    let Name: String?
    let Driver: String?
    let Scope: String?
    let Mountpoint: String?
}

private struct RawNetwork: Decodable {
    let ID: String?
    let Name: String?
    let Driver: String?
    let Scope: String?
    let CreatedAt: String?
    let IPv4: String?
    let IPv6: String?
    let Internal: String?
}

private struct RawContext: Decodable {
    let Name: String?
    let DockerEndpoint: String?
    let Current: Bool?
    let Description: String?
    let Error: String?
}

private struct RawStats: Decodable {
    let CPUPerc: String?
    let MemUsage: String?
    let MemPerc: String?
    let NetIO: String?
    let BlockIO: String?
    let PIDs: String?
    let Name: String?
}
