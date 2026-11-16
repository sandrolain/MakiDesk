import XCTest
@testable import MakiDockerCore

final class DockerFiltersTests: XCTestCase {
    func testContainerStateFilterAndSavedVisibilityPreference() {
        let running = container("running", state: .running)
        let exited = container("exited", state: .exited)
        let paused = container("paused", state: .paused)

        XCTAssertTrue(DockerContainerStateFilter.defaultVisibility.includes(
            running, showStopped: false
        ))
        XCTAssertTrue(DockerContainerStateFilter.defaultVisibility.includes(
            paused, showStopped: false
        ))
        XCTAssertFalse(DockerContainerStateFilter.defaultVisibility.includes(
            exited, showStopped: false
        ))
        XCTAssertTrue(DockerContainerStateFilter.all.includes(exited, showStopped: false))
        XCTAssertTrue(DockerContainerStateFilter.stopped.includes(exited, showStopped: false))
        XCTAssertFalse(DockerContainerStateFilter.running.includes(exited, showStopped: true))
    }

    func testContainerHealthAndSourceFilters() {
        let compose = container("compose", state: .running, health: .unhealthy,
                                compose: ComposeReference(project: "demo"))
        let standalone = container("standalone", state: .running, health: .healthy)

        XCTAssertTrue(DockerContainerHealthFilter.unhealthy.includes(compose.health))
        XCTAssertFalse(DockerContainerHealthFilter.healthy.includes(compose.health))
        XCTAssertTrue(DockerContainerSourceFilter.compose.includes(compose))
        XCTAssertFalse(DockerContainerSourceFilter.standalone.includes(compose))
        XCTAssertTrue(DockerContainerSourceFilter.standalone.includes(standalone))
    }

    func testImageFilters() {
        let used = DockerImage(id: "used", repoTags: ["app:latest"],
                               size: "1MB", containers: 1)
        let unused = DockerImage(id: "unused", repoTags: ["app:old"], size: "1MB")
        let dangling = DockerImage(id: "dangling", repoTags: [], size: "1MB")

        XCTAssertTrue(DockerImageFilter.inUse.includes(used))
        XCTAssertTrue(DockerImageFilter.unused.includes(unused))
        XCTAssertTrue(DockerImageFilter.dangling.includes(dangling))
        XCTAssertFalse(DockerImageFilter.dangling.includes(used))
    }

    func testVolumeAndNetworkFilters() {
        let namedVolume = DockerVolume(name: "data", driver: "local", scope: "local",
                                       mountpoint: "/data", links: 1)
        let anonymousVolume = DockerVolume(name: String(repeating: "a", count: 64),
                                           driver: "local", scope: "local",
                                           mountpoint: "/anonymous")
        let builtInNetwork = DockerNetwork(id: "bridge", name: "bridge", driver: "bridge",
                                           scope: "local")
        let unusedNetwork = DockerNetwork(id: "unused", name: "unused", driver: "bridge",
                                          scope: "local")
        let userNetwork = DockerNetwork(id: "custom", name: "custom", driver: "bridge",
                                        scope: "local", containers: [
                                            DockerNetworkContainer(id: "c1", name: "app")
                                        ])

        XCTAssertTrue(DockerVolumeFilter.inUse.includes(namedVolume))
        XCTAssertTrue(DockerVolumeFilter.anonymous.includes(anonymousVolume))
        XCTAssertTrue(DockerVolumeFilter.named.includes(namedVolume))
        XCTAssertTrue(DockerNetworkFilter.builtIn.includes(builtInNetwork))
        XCTAssertFalse(DockerNetworkFilter.unused.includes(builtInNetwork))
        XCTAssertTrue(DockerNetworkFilter.userDefined.includes(userNetwork))
        XCTAssertTrue(DockerNetworkFilter.unused.includes(unusedNetwork))
        XCTAssertFalse(DockerNetworkFilter.unused.includes(userNetwork))
        XCTAssertTrue(DockerNetworkFilter.inUse.includes(userNetwork))
    }

    private func container(_ id: String,
                           state: DockerContainerState,
                           health: DockerHealth = .none,
                           compose: ComposeReference? = nil) -> DockerContainer {
        DockerContainer(id: id, name: id, image: "image", state: state,
                        status: "", health: health, compose: compose)
    }
}
