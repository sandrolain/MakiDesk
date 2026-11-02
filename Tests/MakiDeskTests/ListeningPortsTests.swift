import XCTest
@testable import MakiDesk

@MainActor
final class ListeningPortsTests: XCTestCase {
    // MARK: - Parsing

    func testGroupsAddressesByProcessAndPort() {
        let output = """
        p101
        cnode
        n127.0.0.1:3000
        n[::1]:3000
        p202
        cpython3
        n*:8000
        """
        let ports = ListeningPortsParser.parse(output)
        XCTAssertEqual(ports.count, 2)
        XCTAssertEqual(ports[0].port, 3000)
        XCTAssertEqual(ports[0].pid, 101)
        XCTAssertEqual(ports[0].processName, "node")
        XCTAssertEqual(ports[0].addresses, ["127.0.0.1", "[::1]"])
        XCTAssertEqual(ports[0].id, "101-3000")
        XCTAssertEqual(ports[1].port, 8000)
        XCTAssertEqual(ports[1].name, "python3")
        XCTAssertEqual(ports[1].addresses, ["*"])
    }

    func testDifferentProcessesOnTheSamePortAreKeptApart() {
        let output = """
        p2
        cb
        n*:5000
        p1
        ca
        n*:5000
        """
        let ports = ListeningPortsParser.parse(output)
        XCTAssertEqual(ports.map(\.name), ["a", "b"])
        XCTAssertEqual(ports.map(\.pid), [1, 2])
    }

    func testSortsByPortThenProcessName() {
        let output = """
        p9
        czz
        n*:9000
        p3
        cbbb
        n*:80
        p1
        caaa
        n*:80
        """
        let ports = ListeningPortsParser.parse(output)
        XCTAssertEqual(ports.map(\.port), [80, 80, 9000])
        XCTAssertEqual(ports.map(\.name), ["aaa", "bbb", "zz"])
    }

    func testMalformedAndIncompleteLinesAreIgnored() {
        let output = """
        n127.0.0.1:3000
        p
        c
        n
        n127.0.0.1:notaport
        n127.0.0.1:99999
        p42
        cgood
        n*:1234
        xignored
        """
        let ports = ListeningPortsParser.parse(output)
        XCTAssertEqual(ports.count, 1)
        XCTAssertEqual(ports.first?.port, 1234)
        XCTAssertEqual(ports.first?.pid, 42)
    }

    func testEmptyOutputHasNoPorts() {
        XCTAssertTrue(ListeningPortsParser.parse("").isEmpty)
        XCTAssertTrue(ListeningPortsParser.parse("\n\n").isEmpty)
    }

    func testSplitHandlesIPv4IPv6WildcardAndInvalid() {
        XCTAssertEqual(ListeningPortsParser.split("127.0.0.1:3000")?.port, 3000)
        XCTAssertEqual(ListeningPortsParser.split("127.0.0.1:3000")?.host, "127.0.0.1")
        XCTAssertEqual(ListeningPortsParser.split("*:8080")?.host, "*")
        XCTAssertEqual(ListeningPortsParser.split("[::1]:3000")?.host, "[::1]")
        XCTAssertEqual(ListeningPortsParser.split("[::]:22")?.host, "[::]")
        XCTAssertEqual(ListeningPortsParser.split(":80")?.host, "*")
        XCTAssertNil(ListeningPortsParser.split("127.0.0.1"))
        XCTAssertNil(ListeningPortsParser.split("127.0.0.1:0"))
        XCTAssertNil(ListeningPortsParser.split("127.0.0.1:70000"))
    }

    // MARK: - Filtering

    func testFilterMatchesPortNamePIDAndAddress() {
        let port = ListeningPort(port: 8080, pid: 1234, processName: "node",
                                 addresses: ["127.0.0.1", "[::1]"])
        XCTAssertTrue(port.matches(""))
        XCTAssertTrue(port.matches("  "))
        XCTAssertTrue(port.matches("808"))
        XCTAssertTrue(port.matches("NODE"))
        XCTAssertTrue(port.matches("1234"))
        XCTAssertTrue(port.matches("[::1]"))
        XCTAssertFalse(port.matches("python"))
    }

    // MARK: - Model

    func testModelPublishesTheInjectedReaderAndCallsBack() async {
        let expected = [ListeningPort(port: 3000, pid: 42, processName: "node",
                                      addresses: ["*"])]
        let model = ListeningPortsModel(reader: ListeningPortsReader {
            .success(expected)
        })
        let finished = expectation(description: "ports read")
        model.refresh { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 3)

        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.failure)
        XCTAssertEqual(model.ports, expected)
    }

    func testAFailedRefreshKeepsThePortsAlreadyShown() async {
        final class Box: @unchecked Sendable {
            var calls = 0
        }
        let box = Box()
        let expected = [ListeningPort(port: 3000, pid: 42, processName: "node",
                                      addresses: ["*"])]
        let model = ListeningPortsModel(reader: ListeningPortsReader {
            box.calls += 1
            if box.calls == 1 { return .success(expected) }
            return .failure(.timedOut)
        })

        let first = expectation(description: "first read")
        model.refresh { first.fulfill() }
        await fulfillment(of: [first], timeout: 3)
        XCTAssertEqual(model.ports, expected)

        let second = expectation(description: "second read")
        model.refresh { second.fulfill() }
        await fulfillment(of: [second], timeout: 3)
        XCTAssertEqual(model.ports, expected)
        XCTAssertEqual(model.failure, .timedOut)
    }
}
