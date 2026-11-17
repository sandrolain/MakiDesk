import XCTest
@testable import MakiShared

final class TerminalWireTests: XCTestCase {
    func testAMessageRoundTrips() throws {
        let message = TerminalMessage(kind: .welcome,
                                      body: .init(protocolVersion: 1,
                                                  appVersion: "0.1",
                                                  pid: 42,
                                                  bundleIdentifier: "com.makidesk.app.terminal",
                                                  message: "title",
                                                  detail: "body"))
        let data = try TerminalWire.frame(message)
        var decoder = TerminalFrameDecoder()
        let messages = try decoder.append(data)
        XCTAssertEqual(messages, [message])
    }

    func testVersionOneFixturesPreserveHandshakeStateAndCommandShapes() throws {
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let workspaceID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let fixtures: [(String, TerminalMessage)] = [
            (
                #"{"version":1,"id":"00000000-0000-0000-0000-000000000001","kind":"hello","body":{"protocolVersion":1,"appVersion":"1.2.3","build":"105","pid":42,"bundleIdentifier":"com.makidesk.app"}}"#,
                TerminalMessage(kind: .hello,
                                body: .init(protocolVersion: 1,
                                            appVersion: "1.2.3",
                                            build: "105",
                                            pid: 42,
                                            bundleIdentifier: "com.makidesk.app"),
                                id: requestID)
            ),
            (
                #"{"version":1,"id":"00000000-0000-0000-0000-000000000001","kind":"welcome","body":{"protocolVersion":1,"appVersion":"1.2.3","build":"105","pid":42,"bundleIdentifier":"com.makidesk.app.terminal"}}"#,
                TerminalMessage(kind: .welcome,
                                body: .init(protocolVersion: 1,
                                            appVersion: "1.2.3",
                                            build: "105",
                                            pid: 42,
                                            bundleIdentifier: "com.makidesk.app.terminal"),
                                id: requestID)
            ),
            (
                #"{"version":1,"id":"00000000-0000-0000-0000-000000000001","kind":"state","body":{"workspaceCount":2,"quakeVisible":false,"workspaceID":"00000000-0000-0000-0000-000000000002"}}"#,
                TerminalMessage(kind: .state,
                                body: .init(workspaceCount: 2,
                                            quakeVisible: false,
                                            workspaceID: workspaceID.uuidString),
                                id: requestID)
            ),
            (
                #"{"version":1,"id":"00000000-0000-0000-0000-000000000001","kind":"dockerExec","body":{"containerID":"abc123","shell":"/bin/sh","title":"Build shell"}}"#,
                TerminalMessage(kind: .dockerExec,
                                body: .init(containerID: "abc123",
                                            shell: "/bin/sh",
                                            title: "Build shell"),
                                id: requestID)
            ),
        ]

        for (fixture, expected) in fixtures {
            let fixtureData = Data(fixture.utf8)
            let message = try TerminalWire.decode(fixtureData)
            XCTAssertEqual(message, expected)

            let framed = try TerminalWire.frame(message)
            let payload = Data(framed.dropFirst(4))
            XCTAssertEqual(try canonicalJSON(payload), try canonicalJSON(fixtureData))
        }
    }

    func testTheHeaderIsTheBigEndianPayloadLength() throws {
        let message = TerminalMessage(kind: .ping)
        let payload = try JSONEncoder().encode(message)
        let data = try TerminalWire.frame(message)
        let length = (Int(data[0]) << 24) | (Int(data[1]) << 16)
            | (Int(data[2]) << 8) | Int(data[3])
        XCTAssertEqual(length, payload.count)
        XCTAssertEqual(data.count, 4 + payload.count)
    }

    func testAnAgentStatusBodyRoundTrips() throws {
        let id = UUID()
        let message = TerminalMessage(
            kind: .agentStatus,
            body: .init(message: "Waiting for input", workspaceID: id.uuidString,
                        agentState: .waiting)
        )
        let data = try TerminalWire.frame(message)
        var decoder = TerminalFrameDecoder()
        XCTAssertEqual(try decoder.append(data), [message])
        XCTAssertEqual(message.body?.agentState, .waiting)
        XCTAssertEqual(message.body?.workspaceID, id.uuidString)
    }

    func testAPartialFrameWaitsForTheRest() throws {
        let message = TerminalMessage(kind: .showMain)
        let data = try TerminalWire.frame(message)
        var decoder = TerminalFrameDecoder()

        // Half the header, then the rest.
        XCTAssertEqual(try decoder.append(data.prefix(2)), [])
        let rest = try decoder.append(data.dropFirst(2))
        XCTAssertEqual(rest, [message])
    }

    func testTwoMessagesInOneChunkAreBothReturned() throws {
        let first = TerminalMessage(kind: .showMain)
        let second = TerminalMessage(kind: .ping)
        var data = try TerminalWire.frame(first)
        data.append(try TerminalWire.frame(second))

        var decoder = TerminalFrameDecoder()
        XCTAssertEqual(try decoder.append(data), [first, second])
    }

    func testAnEmptyFrameIsRejected() {
        var decoder = TerminalFrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data([0, 0, 0, 0]))) { error in
            XCTAssertEqual(error as? TerminalWireError, .malformed("empty frame"))
        }
    }

    func testAnOversizedFrameIsRejectedBeforeItIsBuffered() {
        let size = TerminalWire.maximumFrameBytes + 1
        let header = Data([
            UInt8((size >> 24) & 0xFF),
            UInt8((size >> 16) & 0xFF),
            UInt8((size >> 8) & 0xFF),
            UInt8(size & 0xFF),
        ])
        var decoder = TerminalFrameDecoder()
        XCTAssertThrowsError(try decoder.append(header)) { error in
            XCTAssertEqual(error as? TerminalWireError, .frameTooLarge(size))
        }
    }

    func testMalformedJSONIsRejected() {
        let payload = Data("not json".utf8)
        var data = Data()
        let length = UInt32(payload.count)
        data.append(UInt8((length >> 24) & 0xFF))
        data.append(UInt8((length >> 16) & 0xFF))
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))
        data.append(payload)

        var decoder = TerminalFrameDecoder()
        XCTAssertThrowsError(try decoder.append(data))
    }

    func testAnUnknownKindIsRejected() {
        let payload = Data(#"{"version":1,"id":"00000000-0000-0000-0000-000000000000","kind":"explode"}"#.utf8)
        var data = Data()
        let length = UInt32(payload.count)
        data.append(UInt8((length >> 24) & 0xFF))
        data.append(UInt8((length >> 16) & 0xFF))
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))
        data.append(payload)

        var decoder = TerminalFrameDecoder()
        XCTAssertThrowsError(try decoder.append(data))
    }

    func testAMissingVersionAndIDAreTolerated() throws {
        let payload = Data(#"{"kind":"ping"}"#.utf8)
        let message = try TerminalWire.decode(payload)
        XCTAssertEqual(message.version, TerminalMessage.wireVersion)
        XCTAssertEqual(message.kind, .ping)
    }

    func testUnsupportedWireVersionIsRejected() {
        let payload = Data(#"{"version":2,"id":"00000000-0000-0000-0000-000000000001","kind":"ping"}"#.utf8)
        XCTAssertThrowsError(try TerminalWire.decode(payload)) { error in
            XCTAssertEqual(error as? TerminalWireError, .unsupportedVersion(2))
        }

        var outgoing = TerminalMessage(kind: .ping)
        outgoing.version = 2
        XCTAssertThrowsError(try TerminalWire.frame(outgoing)) { error in
            XCTAssertEqual(error as? TerminalWireError, .unsupportedVersion(2))
        }
    }

    func testHandshakeVersionIsOptionalForLegacyPeersButMustMatchWhenPresent() {
        XCTAssertTrue(TerminalMessage.isSupportedHandshakeVersion(nil))
        XCTAssertTrue(TerminalMessage.isSupportedHandshakeVersion(1))
        XCTAssertFalse(TerminalMessage.isSupportedHandshakeVersion(2))
    }

    func testTheSocketLivesUnderApplicationSupport() {
        let path = TerminalSocketLocation.socketURL.path
        XCTAssertTrue(path.hasSuffix("MakiDesk/Terminal/terminal.sock"), path)
        XCTAssertTrue(TerminalSocketLocation.directory.path.hasSuffix("MakiDesk/Terminal"),
                      TerminalSocketLocation.directory.path)
    }

    private func canonicalJSON(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try JSONSerialization.data(withJSONObject: object,
                                         options: [.sortedKeys, .fragmentsAllowed])
    }
}
