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
}
