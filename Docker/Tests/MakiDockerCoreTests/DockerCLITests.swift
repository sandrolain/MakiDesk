import XCTest
@testable import MakiDockerCore

final class DockerCLITests: XCTestCase {
    func testRunnerPassesContextAsArgumentsAndCapturesOutput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("makidesk-docker-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = directory.appendingPathComponent("docker")
        let capture = directory.appendingPathComponent("args.txt")
        try """
        #!/bin/sh
        printf '%s\n' "$@" > "\(capture.path)"
        printf 'hello from docker'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)

        let cli = DockerCLI(executableURL: script, context: "test-context",
                            environment: ["CAPTURE_FILE": capture.path])
        let result = try await cli.run(["ps", "-a"], timeout: 10)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "hello from docker")
        let arguments = try String(contentsOf: capture, encoding: .utf8)
        XCTAssertEqual(arguments, "--context\ntest-context\nps\n-a\n")
    }

    func testRunnerReportsNonZeroExit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("makidesk-docker-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("docker")
        try """
        #!/bin/sh
        echo "daemon is down" >&2
        exit 7
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)

        let cli = DockerCLI(executableURL: script, environment: [:])
        do {
            _ = try await cli.runChecked(["info"], timeout: 10)
            XCTFail("expected a non-zero error")
        } catch let DockerCLIError.nonZero(code, detail) {
            XCTAssertEqual(code, 7)
            XCTAssertTrue(detail.contains("daemon is down"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRunnerTimesOutAndTerminates() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("makidesk-docker-timeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("docker")
        try "#!/bin/sh\nsleep 5\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        let cli = DockerCLI(executableURL: script, environment: [:])
        let started = Date()
        do {
            _ = try await cli.run(["logs"], timeout: 0.3)
            XCTFail("expected a timeout")
        } catch DockerCLIError.timedOut {
            XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testLocatorFindsDockerInPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("makidesk-docker-locate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("docker")
        try "#!/bin/sh\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        let found = DockerExecutableLocator.locateBlocking(
            environment: ["PATH": directory.path]
        )
        XCTAssertEqual(found?.path, script.path)
    }

    func testNetworkDetailsParseContainers() {
        let json = """
        [{"Name":"shop_default","Id":"net1","IPAM":{"Config":[{"Subnet":"172.20.0.0/16","Gateway":"172.20.0.1"}]},"Containers":{"abc":{"Name":"shop-web-1","IPv4Address":"172.20.0.2/16"}}}]
        """
        let details = DockerJSON.networkDetails(from: json)
        XCTAssertEqual(details.count, 1)
        XCTAssertEqual(details[0].subnet, "172.20.0.0/16")
        XCTAssertEqual(details[0].gateway, "172.20.0.1")
        XCTAssertEqual(details[0].containers.first?.name, "shop-web-1")
    }
}
