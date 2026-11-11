import XCTest
import MakiShared
@testable import MakiDockerCore

final class DockerParsingTests: XCTestCase {
    func testContainersUseIsolatedComposeLabels() {
        let line = """
        {"ID":"97bd1f5bc3f409649759e62e8af7992bae7cf7d12115a6f9d2a70cb3761ee4d1","Names":"/dsearch-searxng","Image":"searxng/searxng:latest","State":"running","Status":"Up 2 days","HealthStatus":"healthy","Ports":"127.0.0.1:8888->8080/tcp, [::]:8888->8080/tcp","Mounts":"vol:/etc/searxng","Networks":"searxng_default","CreatedAt":"2026-10-21 21:40:42 +0200 CEST","RunningFor":"2 weeks ago","Size":"475kB (virtual 261MB)"}\tsearxng\t/Users/me/deploy/searxng\t/Users/me/deploy/searxng/docker-compose.yml\tsearxng\tFalse
        """
        let containers = DockerJSON.containers(from: line)
        XCTAssertEqual(containers.count, 1)
        let container = containers[0]
        XCTAssertEqual(container.name, "dsearch-searxng")
        XCTAssertEqual(container.state, .running)
        XCTAssertEqual(container.health, .healthy)
        XCTAssertEqual(container.compose?.project, "searxng")
        XCTAssertEqual(container.compose?.service, "searxng")
        XCTAssertEqual(container.compose?.configFiles,
                       ["/Users/me/deploy/searxng/docker-compose.yml"])
        XCTAssertEqual(container.ports.count, 2)
        XCTAssertEqual(container.ports[0].hostPort, 8888)
        XCTAssertEqual(container.ports[1].hostIP, "[::]")
    }

    func testGroupsPutRunningProjectsFirstAndStandaloneLast() {
        let compose = ComposeReference(project: "shop", workingDirectory: "/shop",
                                       configFiles: ["/shop/compose.yml"])
        let running = DockerContainer(id: "1", name: "web", image: "nginx",
                                      state: .running, status: "", health: .none,
                                      compose: compose)
        let stopped = DockerContainer(id: "2", name: "worker", image: "worker",
                                      state: .exited, status: "", health: .none,
                                      compose: compose)
        let standalone = DockerContainer(id: "3", name: "scratch", image: "alpine",
                                         state: .running, status: "", health: .none)
        let groups = DockerGrouping.groups([stopped, standalone, running])
        XCTAssertEqual(groups.map(\.name), ["shop", "Standalone"])
        XCTAssertEqual(groups[0].containers.map(\.name), ["web", "worker"])
    }

    func testComposeContainerNamesDropProjectPrefixAndSortByDisplayName() {
        let compose = ComposeReference(project: "shop", workingDirectory: "/shop",
                                       configFiles: ["/shop/compose.yml"])
        let worker = DockerContainer(id: "2", name: "shop-worker-1", image: "worker",
                                     state: .exited, status: "", health: .none,
                                     compose: compose)
        let api = DockerContainer(id: "1", name: "shop-api-1", image: "api",
                                  state: .exited, status: "", health: .none,
                                  compose: compose)
        let custom = DockerContainer(id: "3", name: "custom-name", image: "custom",
                                     state: .exited, status: "", health: .none,
                                     compose: compose)

        let group = DockerGrouping.groups([worker, custom, api]).first
        XCTAssertEqual(api.displayName, "api-1")
        XCTAssertEqual(custom.displayName, "custom-name")
        XCTAssertEqual(group?.containers.map(\.displayName),
                       ["api-1", "custom-name", "worker-1"])
    }

    func testContainerOrderingUsesMetricsAndLeavesMissingSamplesLast() {
        func container(_ name: String) -> DockerContainer {
            DockerContainer(id: name, name: name, image: "image", state: .running,
                            status: "", health: .none)
        }
        func stats(_ name: String, cpu: String, memory: String) -> DockerContainerStats {
            DockerContainerStats(cpuPercent: cpu, memoryUsage: memory,
                                 memoryPercent: "", networkIO: "", blockIO: "",
                                 pids: "", name: name)
        }
        let containers = [container("slow"), container("fast"), container("unknown")]
        let metrics = [
            "slow": stats("slow", cpu: "2.00%", memory: "512MiB / 1GiB"),
            "fast": stats("fast", cpu: "18.00%", memory: "128MiB / 1GiB"),
        ]

        XCTAssertEqual(DockerContainerOrdering.sort(containers, by: .cpu, stats: metrics)
            .map(\.name), ["fast", "slow", "unknown"])
        XCTAssertEqual(DockerContainerOrdering.sort(containers, by: .memory, stats: metrics)
            .map(\.name), ["slow", "fast", "unknown"])
    }

    func testDiskUsageParsesVolumesAndReclaimable() {
        let json = """
        {
          "Images": [
            {"ID":"sha256:aaa","Repository":"app","Tag":"latest","Size":"100MB","UniqueSize":"90MB","Containers":"1"},
            {"ID":"sha256:bbb","Repository":"old","Tag":"latest","Size":"50MB","UniqueSize":"50MB","Containers":"0"}
          ],
          "Containers": [
            {"ID":"c1","Names":"app","State":"running","Size":"10MB"},
            {"ID":"c2","Names":"old","State":"exited","Size":"5MB"}
          ],
          "Volumes": [
            {"Name":"data","Size":"20MB","Links":"1"},
            {"Name":"scratch","Size":"7MB","Links":"0"}
          ],
          "BuildCache": [
            {"ID":"bc1","Size":"3MB","InUse":"false","Description":"cache"}
          ]
        }
        """
        let usage = DockerJSON.diskUsage(from: json)
        XCTAssertEqual(usage.images.total, 2)
        XCTAssertEqual(usage.images.active, 1)
        XCTAssertEqual(usage.images.bytes, 140_000_000)
        XCTAssertEqual(usage.images.reclaimableBytes, 50_000_000)
        XCTAssertEqual(usage.volumes.reclaimableBytes, 7_000_000)
        XCTAssertEqual(usage.buildCache.reclaimableBytes, 3_000_000)
    }

    func testMergingImageDiskUsagePreservesCumulativeSizeAndAddsUniqueSize() {
        let image = DockerImage(id: "sha256:abc123", repoTags: ["app:latest"],
                                size: "1.4GB", uniqueSize: nil, containers: 0)
        let diskImage = DockerDiskUsageItem(id: "sha256:abc123", name: "app:latest",
                                            size: "320MB", bytes: 320_000_000, inUse: true)
        let disk = DockerDiskUsage(
            images: DockerDiskUsageCategory(title: "Images", total: 1, active: 1,
                                            size: "320MB", bytes: 320_000_000,
                                            reclaimable: "0B", reclaimableBytes: 0,
                                            items: [diskImage]),
            containers: .empty, volumes: .empty, buildCache: .empty
        )

        let merged = DockerJSON.mergingDiskUsage([image], with: disk)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].size, "1.4GB")
        XCTAssertEqual(merged[0].uniqueSize, "320MB")
        XCTAssertEqual(merged[0].containers, 1)
    }

    func testMergingVolumeDiskUsageAddsSizeAndPreservesListedMetadata() {
        let volume = DockerVolume(name: "data", driver: "local", scope: "local",
                                  mountpoint: "/var/lib/docker/volumes/data/_data",
                                  composeProject: "shop")
        let diskVolume = DockerDiskUsageItem(id: "data", name: "data", size: "8.5MB",
                                             bytes: 8_500_000, inUse: true)
        let disk = DockerDiskUsage(
            images: .empty, containers: .empty,
            volumes: DockerDiskUsageCategory(title: "Volumes", total: 1, active: 1,
                                             size: "8.5MB", bytes: 8_500_000,
                                             reclaimable: "0B", reclaimableBytes: 0,
                                             items: [diskVolume]),
            buildCache: .empty
        )

        let merged = DockerJSON.mergingDiskUsage([volume], with: disk)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].size, "8.5MB")
        XCTAssertEqual(merged[0].composeProject, "shop")
        XCTAssertEqual(merged[0].mountpoint, "/var/lib/docker/volumes/data/_data")
        XCTAssertEqual(merged[0].links, 1)
    }

    func testInspectRedactsEnvironmentInRawJSON() {
        let json = """
        [{"Config":{"Env":["SECRET=hidden","PATH=/usr/bin"],"Entrypoint":["/bin/app"],"Cmd":["serve","--port","8080"],"Labels":{"a":"b"}},"HostConfig":{"RestartPolicy":{"Name":"no"},"LogConfig":{"Type":"json-file"}},"Mounts":[]}]
        """
        let summary = DockerJSON.inspect(from: json)
        XCTAssertTrue(summary.rawJSON.contains("SECRET=••••"))
        XCTAssertFalse(summary.rawJSON.contains("SECRET=hidden"))
        XCTAssertTrue(summary.environment.contains("SECRET=hidden"))
        XCTAssertEqual(summary.restartPolicy, "no")
        XCTAssertEqual(summary.logDriver, "json-file")
        XCTAssertEqual(summary.entrypoint, ["/bin/app"])
        XCTAssertEqual(summary.command, ["serve", "--port", "8080"])
    }

    func testInspectExtractsMountArgumentsForRunCommand() {
        let json = """
        [{"Config":{"Env":[],"Entrypoint":["/bin/app"],"Cmd":[]},"HostConfig":{"RestartPolicy":{"Name":"unless-stopped"}},"Mounts":[{"Type":"bind","Source":"/tmp/data","Destination":"/data","RW":false},{"Type":"volume","Name":"db-data","Destination":"/var/lib/db","RW":true}]}]
        """
        let summary = DockerJSON.inspect(from: json)
        XCTAssertEqual(summary.mountArguments, [
            "type=bind,source=/tmp/data,target=/data,readonly",
            "type=volume,source=db-data,target=/var/lib/db",
        ])
    }

    func testStatsParseMultipleContainersByName() {
        let output = """
        {"Name":"web","CPUPerc":"1.25%","MemUsage":"64MiB / 1GiB","MemPerc":"6.25%","NetIO":"1kB / 2kB","BlockIO":"0B / 0B","PIDs":"4"}
        {"Name":"/worker","CPUPerc":"0.00%","MemUsage":"8MiB / 1GiB","MemPerc":"0.78%","NetIO":"0B / 0B","BlockIO":"0B / 0B","PIDs":"1"}
        """
        let stats = DockerJSON.statsByName(from: output)
        XCTAssertEqual(stats["web"]?.cpuPercent, "1.25%")
        XCTAssertEqual(stats["web"]?.memoryUsage, "64MiB / 1GiB")
        XCTAssertEqual(stats["worker"]?.cpuPercent, "0.00%")
    }

    func testComposeCommandUsesEveryFileAndProjectDirectory() {
        let compose = ComposeReference(project: "shop",
                                       workingDirectory: "/tmp/a b",
                                       configFiles: ["/tmp/a b/compose.yml",
                                                     "/tmp/a b/override.yml"])
        let arguments = DockerComposeAction.downVolumes.arguments(compose: compose)
        XCTAssertEqual(arguments.first, "compose")
        XCTAssertTrue(arguments.contains("--project-directory"))
        XCTAssertTrue(arguments.contains("/tmp/a b"))
        XCTAssertEqual(arguments.filter { $0 == "-f" }.count, 2)
        XCTAssertEqual(arguments.suffix(2), ["down", "--volumes"])

        let deleteProject = DockerComposeAction.down.arguments(compose: compose)
        XCTAssertEqual(deleteProject.suffix(1), ["down"])
        XCTAssertEqual(DockerComposeAction.down.title, "Delete project")
    }

    func testComposeStartUsesServicesAndRestartUsesSupportedTimeoutFlag() {
        let compose = ComposeReference(project: "shop", workingDirectory: "/shop",
                                       configFiles: ["/shop/compose.yml"])
        let start = DockerComposeAction.start.arguments(compose: compose)
        XCTAssertEqual(start.last, "start")

        let selectedStart = DockerComposeAction.start.arguments(
            compose: compose, services: ["worker", "web", "web"]
        )
        XCTAssertEqual(Array(selectedStart.suffix(4)),
                       ["up", "--detach", "web", "worker"])

        let restart = DockerComposeAction.restart.arguments(compose: compose)
        XCTAssertEqual(Array(restart.suffix(3)), ["restart", "--timeout", "10"])
        XCTAssertFalse(restart.contains("--time"))
    }

    func testResourcePruneScopesAreDistinctAndExplicit() {
        XCTAssertEqual(DockerPruneMode.images.arguments(all: false),
                       ["image", "prune", "--force"])
        XCTAssertEqual(DockerPruneMode.images.arguments(all: true),
                       ["image", "prune", "--all", "--force"])
        XCTAssertEqual(DockerPruneMode.volumes.arguments(all: false),
                       ["volume", "prune", "--force"])
        XCTAssertEqual(DockerPruneMode.volumes.arguments(all: true),
                       ["volume", "prune", "--all", "--force"])
        XCTAssertEqual(DockerPruneMode.buildCache.arguments(all: false),
                       ["builder", "prune", "--force"])
        XCTAssertEqual(DockerPruneMode.buildCache.arguments(all: true),
                       ["builder", "prune", "--all", "--force"])
        XCTAssertEqual(DockerPruneMode.containers.arguments(all: false),
                       DockerPruneMode.containers.arguments(all: true))
        XCTAssertEqual(DockerPruneMode.networks.arguments(all: false),
                       DockerPruneMode.networks.arguments(all: true))
    }

    func testDisplayedSizesSeparateNumberFromUnit() {
        XCTAssertEqual(DockerFormatting.spacedSize("475kB"), "475 kB")
        XCTAssertEqual(DockerFormatting.spacedSize("1.02GB"), "1.02 GB")
        XCTAssertEqual(DockerFormatting.spacedSize("—"), "—")
        XCTAssertEqual(DockerFormatting.spacedSize("900 MB"), "900 MB")
    }

    func testPruneCommandsAreExplicit() {
        XCTAssertEqual(DockerPruneMode.basic.arguments,
                       ["system", "prune", "--force"])
        XCTAssertEqual(DockerPruneMode.all.arguments,
                       ["system", "prune", "--all", "--force", "--volumes"])
    }

    func testImageAndResourceCommandsKeepArgumentsSeparated() {
        XCTAssertEqual(DockerCommands.imagePull("registry.example/app:1"),
                       ["image", "pull", "registry.example/app:1"])
        XCTAssertEqual(DockerCommands.imageTag("app:old", as: "app:new"),
                       ["image", "tag", "app:old", "app:new"])
        XCTAssertEqual(DockerCommands.imagePush("registry.example/app:1"),
                       ["image", "push", "registry.example/app:1"])
        XCTAssertEqual(DockerCommands.imageBuild(tag: "local/app:dev", context: "/tmp/a b"),
                       ["build", "--tag", "local/app:dev", "/tmp/a b"])
        XCTAssertEqual(DockerCommands.imageSave(id: "sha256:abc", to: "/tmp/app.tar"),
                       ["image", "save", "--output", "/tmp/app.tar", "sha256:abc"])
        XCTAssertEqual(DockerCommands.volumeCreate("data"), ["volume", "create", "data"])
        XCTAssertEqual(DockerCommands.networkCreate("app-net"), ["network", "create", "app-net"])
        XCTAssertEqual(DockerCommands.networkConnect("app-net", container: "web"),
                       ["network", "connect", "app-net", "web"])
        XCTAssertEqual(DockerCommands.networkDisconnect("app-net", container: "web"),
                       ["network", "disconnect", "app-net", "web"])
        XCTAssertEqual(DockerCommands.copyFile(from: "web:/tmp/a", to: "/tmp/a b"),
                       ["cp", "web:/tmp/a", "/tmp/a b"])
    }

    func testRunCommandCopiesInspectableConfigurationAndQuotesSecrets() {
        let container = DockerContainer(
            id: "abc", name: "web app", image: "example/web:1",
            state: .running, status: "Up", health: .none,
            ports: [DockerPortMapping(hostIP: "127.0.0.1", hostPort: 8080,
                                      containerPort: 80, proto: "tcp")]
        )
        let inspect = DockerInspectSummary(
            rawJSON: "", environment: ["TOKEN=a'b"],
            entrypoint: ["/bin/sh", "-c"], command: ["serve"],
            mountArguments: ["type=bind,source=/tmp/a b,target=/app"],
            restartPolicy: "unless-stopped"
        )

        let command = DockerRunCommand.make(container: container, inspect: inspect)

        XCTAssertEqual(command,
                       "docker run --name 'web app' --restart 'unless-stopped' -p '127.0.0.1:8080:80/tcp' --mount 'type=bind,source=/tmp/a b,target=/app' -e 'TOKEN=a'\\''b' --entrypoint '/bin/sh' 'example/web:1' '-c' 'serve'")
    }

    func testDockerExecValidation() {
        XCTAssertTrue(DockerExecValidation.isValidContainerID("97bd1f5bc3f4"))
        XCTAssertTrue(DockerExecValidation.isValidContainerID("shop-web-1"))
        XCTAssertTrue(DockerExecValidation.isValidShell("sh"))
        XCTAssertFalse(DockerExecValidation.isValidShell("sh; rm -rf /"))
        XCTAssertEqual(DockerExecValidation.command(containerID: "shop-web-1", shell: "sh"),
                       "docker exec -it shop-web-1 sh")
    }
}
