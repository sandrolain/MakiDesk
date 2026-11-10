import XCTest
import MakiShared

final class DockerWireTests: XCTestCase {
    func testFrameRoundTripKeepsExecRequest() throws {
        let message = DockerMessage(
            kind: .openExec,
            body: .init(containerID: "shop-web-1", shell: "sh", title: "Docker: web")
        )
        let data = try DockerWire.frame(message)
        var decoder = DockerFrameDecoder()
        let decoded = try decoder.append(data)
        XCTAssertEqual(decoded, [message])
    }

    func testTerminalDockerExecRoundTrip() throws {
        let message = TerminalMessage(
            kind: .dockerExec,
            body: .init(containerID: "shop-web-1", shell: "sh", title: "Docker: web")
        )
        let data = try TerminalWire.frame(message)
        var decoder = TerminalFrameDecoder()
        let decoded = try decoder.append(data)
        XCTAssertEqual(decoded, [message])
    }

    func testExecValidationRejectsCommands() {
        XCTAssertFalse(DockerExecValidation.isValidContainerID("web; rm -rf /"))
        XCTAssertFalse(DockerExecValidation.isValidShell("sh -c whoami"))
        XCTAssertEqual(DockerExecValidation.command(containerID: "web", shell: "bash"),
                       "docker exec -it web bash")
    }
}
