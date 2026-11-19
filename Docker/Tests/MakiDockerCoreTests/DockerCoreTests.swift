import XCTest
@testable import MakiDockerCore

final class DockerCoreTests: XCTestCase {
    func testEmptyInventory() {
        XCTAssertTrue(DockerJSON.containers(from: "").isEmpty)
        XCTAssertEqual(DockerJSON.diskUsage(from: ""), .empty)
    }

    func testPortParsing() {
        let ports = DockerFormatting.ports(
            from: "127.0.0.1:8888->8080/tcp, [::]:8080->80/tcp, 9000/tcp"
        )
        XCTAssertEqual(ports.count, 3)
        XCTAssertEqual(ports[0].hostPort, 8888)
        XCTAssertEqual(ports[0].containerPort, 8080)
        XCTAssertEqual(ports[2].hostPort, nil)
        XCTAssertEqual(ports[2].containerPort, 9000)
    }

    func testSizeParsing() {
        XCTAssertEqual(DockerFormatting.bytes(from: "900MB"), 900_000_000)
        XCTAssertEqual(DockerFormatting.bytes(from: "1.02GB"), 1_020_000_000)
        XCTAssertNil(DockerFormatting.bytes(from: "N/A"))
        XCTAssertEqual(DockerFormatting.size(0), "0B")
        XCTAssertEqual(DockerFormatting.size(900_000_000), "900MB")
        XCTAssertEqual(DockerFormatting.size(1_020_000_000), "1.02GB")
    }

    func testPrunePlanKeepsRunningAndUsed() {
        let running = DockerContainer(id: "a", name: "a", image: "i", state: .running,
                                      status: "", health: .none)
        let stopped = DockerContainer(id: "b", name: "b", image: "i", state: .exited,
                                      status: "", health: .none)
        let usedImage = DockerImage(id: "i1", repoTags: ["x:1"], size: "1MB", containers: 1)
        let unusedImage = DockerImage(id: "i2", repoTags: ["x:2"], size: "2MB", containers: 0)
        let usedVolume = DockerVolume(name: "v1", driver: "local", scope: "local",
                                      mountpoint: "/v1", size: "1MB", links: 1)
        let unusedVolume = DockerVolume(name: "v2", driver: "local", scope: "local",
                                        mountpoint: "/v2", size: "2MB", links: 0)
        let network = DockerNetwork(id: "n1", name: "custom", driver: "bridge",
                                    scope: "local", containers: [])
        let plan = DockerPrunePlan(containers: [running, stopped],
                                   images: [usedImage, unusedImage],
                                   volumes: [usedVolume, unusedVolume],
                                   networks: [network],
                                   diskUsage: .empty)
        XCTAssertEqual(plan.stoppedContainers.map(\.id), ["b"])
        XCTAssertEqual(plan.unusedImages.map(\.id), ["i2"])
        XCTAssertEqual(plan.unusedVolumes.map(\.name), ["v2"])
        XCTAssertEqual(plan.unusedNetworks.map(\.id), ["n1"])
        XCTAssertEqual(plan.estimatedBytes(for: .images), 2_000_000)
        XCTAssertEqual(plan.estimatedBytes(for: .containers), 0)
    }

    func testLogBufferSplitsPartialLines() {
        var buffer = DockerLogBuffer(maxLines: 10, maxBytes: 1_000)
        _ = buffer.append("one\ntw")
        XCTAssertEqual(buffer.lines, ["one"])
        XCTAssertEqual(buffer.partial, "tw")
        _ = buffer.append("o\nthree\n")
        XCTAssertEqual(buffer.lines, ["one", "two", "three"])
        XCTAssertEqual(buffer.partial, "")
    }

    func testProcessParsingPreservesCommandArguments() {
        XCTAssertEqual(
            DockerCommands.processes(id: "container-123"),
            ["top", "container-123", "-eo", "pid,ppid,user,stat,%cpu,%mem,etime,args"]
        )
        let output = """
        PID PPID USER STAT %CPU %MEM ELAPSED COMMAND
        17 1 root S 0.4 2.1 00:12 /usr/bin/node server.js --host 0.0.0.0
        28 17 app R 1.2 3.4 01:05 worker --queue background jobs
        """
        let processes = DockerProcessParsing.parse(output)
        XCTAssertEqual(processes.count, 2)
        XCTAssertEqual(processes[0].pid, "17")
        XCTAssertEqual(processes[0].parentPID, "1")
        XCTAssertEqual(processes[0].command, "/usr/bin/node server.js --host 0.0.0.0")
        XCTAssertEqual(processes[1].command, "worker --queue background jobs")
    }

    func testRegistryPagesResolveCommonRegistriesAndSkipLocalOrDigestOnlyImages() {
        XCTAssertEqual(
            DockerRegistryPage(imageReference: "nginx:1.27")?.url.absoluteString,
            "https://hub.docker.com/_/nginx"
        )
        XCTAssertEqual(
            DockerRegistryPage(imageReference: "acme/api:2.0")?.url.absoluteString,
            "https://hub.docker.com/r/acme/api"
        )
        XCTAssertEqual(
            DockerRegistryPage(imageReference: "ghcr.io/acme/api:2.0")?.url.absoluteString,
            "https://github.com/acme/packages/container/package/api"
        )
        XCTAssertEqual(
            DockerRegistryPage(imageReference: "quay.io/acme/api:2.0")?.url.absoluteString,
            "https://quay.io/repository/acme/api"
        )
        XCTAssertEqual(
            DockerRegistryPage(imageReference: "registry.example.com:5000/team/api:2.0")?
                .url.absoluteString,
            "https://registry.example.com:5000/team/api"
        )
        XCTAssertNil(DockerRegistryPage(imageReference: "localhost:5000/acme/api:2.0"))
        XCTAssertNil(DockerRegistryPage(imageReference: "sha256:abcdef123456"))
    }

    func testAttentionIncludesKnownFailuresButNotExpectedStoppedContainers() {
        let unhealthy = DockerContainer(id: "a", name: "api", image: "api:latest",
                                        state: .running, status: "Up", health: .unhealthy)
        let restarting = DockerContainer(id: "b", name: "worker", image: "worker:latest",
                                         state: .restarting, status: "Restarting",
                                         health: .starting)
        let stopped = DockerContainer(id: "c", name: "batch", image: "batch:latest",
                                      state: .exited, status: "Exited", health: .none)
        let items = DockerAttention.items(for: [stopped, restarting, unhealthy])
        XCTAssertEqual(items.map(\.container.id), ["a", "b"])
        XCTAssertEqual(items.map(\.reason), [.unhealthy, .restarting])
    }

    func testRefreshRequestsDuringAnActiveReadCoalesceIntoOneFollowUp() {
        var coalescer = DockerRefreshCoalescer()
        coalescer.request()
        coalescer.request()
        XCTAssertTrue(coalescer.takePendingRequest())
        XCTAssertFalse(coalescer.takePendingRequest())
    }
}
