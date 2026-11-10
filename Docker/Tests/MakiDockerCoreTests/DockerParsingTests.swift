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

    func testInspectRedactsEnvironmentInRawJSON() {
        let json = """
        [{"Config":{"Env":["SECRET=hidden","PATH=/usr/bin"],"Labels":{"a":"b"}},"HostConfig":{"RestartPolicy":{"Name":"no"},"LogConfig":{"Type":"json-file"}},"Mounts":[]}]
        """
        let summary = DockerJSON.inspect(from: json)
        XCTAssertTrue(summary.rawJSON.contains("SECRET=••••"))
        XCTAssertFalse(summary.rawJSON.contains("SECRET=hidden"))
        XCTAssertTrue(summary.environment.contains("SECRET=hidden"))
        XCTAssertEqual(summary.restartPolicy, "no")
        XCTAssertEqual(summary.logDriver, "json-file")
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
    }

    func testPruneCommandsAreExplicit() {
        XCTAssertEqual(DockerPruneMode.basic.arguments,
                       ["system", "prune", "--force"])
        XCTAssertEqual(DockerPruneMode.all.arguments,
                       ["system", "prune", "--all", "--force", "--volumes"])
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
