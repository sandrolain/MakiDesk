import XCTest
@testable import MakiDesk

/// T44: the persisted dropzone shape, its tolerant decoding, the validation the
/// editor shows and the confirmation hash that guards a changed command.
final class DropzoneConfigTests: XCTestCase {
    private func roundTrip(_ zone: DropzoneConfig) throws -> DropzoneConfig {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DropzoneConfig.self, from: encoder.encode(zone))
    }

    func testZoneRoundTripsThroughJSON() throws {
        var zone = DropzoneConfig(name: "Resize", icon: .emoji("🖼️"))
        zone.accepts = DropzoneAccept(kinds: [.files, .images], utis: ["public.image"],
                                      match: .any, minItems: 1, maxItems: 5)
        zone.command = CommandSpec(line: "shortcuts run ID --input-path {paths}",
                                   mode: .argv, stdin: .none,
                                   environment: ["FOO": "bar"],
                                   workingDirectory: "/tmp",
                                   timeoutSeconds: 30)
        zone.feedback = DropFeedback(notifyOnSuccess: false, showOutput: .stdout, revealOutput: true)
        // Whole seconds: the ISO-8601 format the store writes has no sub-second
        // precision, so a different default would fail the round-trip.
        zone.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        zone.markConfirmed()

        let decoded = try roundTrip(zone)
        XCTAssertEqual(decoded, zone)
    }

    func testIconKindsEncodeAsAKindAndValue() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(DropzoneIcon.file("icons/folder.png"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(object, ["kind": "file", "value": "icons/folder.png"])

        let symbol = try JSONDecoder().decode(
            DropzoneIcon.self,
            from: Data(#"{"kind":"symbol","value":"photo"}"#.utf8))
        XCTAssertEqual(symbol, .symbol("photo"))
    }

    func testMissingFieldsFallBackToDefaults() throws {
        let zone = try JSONDecoder().decode(DropzoneConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(zone.name, "")
        XCTAssertTrue(zone.enabled)
        XCTAssertEqual(zone.accepts.kinds, [.files])
        XCTAssertEqual(zone.accepts.match, .all)
        XCTAssertEqual(zone.accepts.minItems, 1)
        XCTAssertNil(zone.accepts.maxItems)
        XCTAssertEqual(zone.command.mode, .argv)
        XCTAssertEqual(zone.feedback.showOutput, .none)
        XCTAssertTrue(zone.requiresConfirmation)
    }

    func testAcceptKindsAreDeduplicatedAndCanonical() throws {
        let accept = DropzoneAccept(kinds: [.images, .files, .files], utis: [" public.image ", "public.image", ""])
        XCTAssertEqual(accept.kinds, [.files, .images])
        XCTAssertEqual(accept.utis, ["public.image"])
    }

    func testMinimumBelowOneIsNormalised() throws {
        let json = #"{"accepts":{"kinds":["files"],"minItems":0}}"#.data(using: .utf8)!
        let zone = try JSONDecoder().decode(DropzoneConfig.self, from: json)
        XCTAssertEqual(zone.accepts.minItems, 1)
    }

    // MARK: - Validation

    func testEmptyNameAndCommandAreReported() {
        let zone = DropzoneConfig()
        let issues = zone.issues()
        XCTAssertTrue(issues.contains(.emptyName))
        XCTAssertTrue(issues.contains(.emptyCommand))
    }

    func testInvalidTimeoutAndRangeAreReported() {
        var zone = DropzoneConfig(name: "Test", command: CommandSpec(line: "echo hi", timeoutSeconds: 4000))
        zone.accepts.minItems = 5
        zone.accepts.maxItems = 2
        let issues = zone.issues()
        XCTAssertTrue(issues.contains(.invalidTimeout(4000)))
        XCTAssertTrue(issues.contains(.invalidItemRange))
    }

    func testInvalidUTIIsReported() {
        var zone = DropzoneConfig(name: "Test", command: CommandSpec(line: "echo hi"))
        zone.accepts.utis = ["not a uti"]
        XCTAssertEqual(zone.issues(), [.invalidUTI("not a uti")])
    }

    func testNoAcceptedKindsIsReported() {
        var zone = DropzoneConfig(name: "Test", command: CommandSpec(line: "echo hi"))
        zone.accepts.kinds = []
        XCTAssertTrue(zone.issues().contains(.noAcceptedKinds))
    }

    // MARK: - Confirmation

    func testConfirmationHashCoversWhatRunsAndNotTheTimeout() {
        var zone = DropzoneConfig(name: "Test", command: CommandSpec(line: "echo one"))
        let original = DropzoneConfig.confirmationHash(for: zone.command)
        zone.command.timeoutSeconds = 300
        XCTAssertEqual(DropzoneConfig.confirmationHash(for: zone.command), original)

        zone.command.line = "echo two"
        XCTAssertNotEqual(DropzoneConfig.confirmationHash(for: zone.command), original)

        zone = DropzoneConfig(name: "Test", command: CommandSpec(line: "echo one", mode: .shell))
        XCTAssertNotEqual(DropzoneConfig.confirmationHash(for: zone.command), original)

        zone = DropzoneConfig(name: "Test", command: CommandSpec(line: "echo one", stdin: .text))
        XCTAssertNotEqual(DropzoneConfig.confirmationHash(for: zone.command), original)

        zone = DropzoneConfig(name: "Test", command: CommandSpec(line: "echo one", environment: ["A": "b"]))
        XCTAssertNotEqual(DropzoneConfig.confirmationHash(for: zone.command), original)

        zone = DropzoneConfig(name: "Test", command: CommandSpec(line: "echo one", workingDirectory: "/tmp"))
        XCTAssertNotEqual(DropzoneConfig.confirmationHash(for: zone.command), original)
    }

    func testConfirmedZoneDoesNotAskAgainUntilTheCommandChanges() {
        var zone = DropzoneConfig(name: "Test", command: CommandSpec(line: "echo hi"))
        XCTAssertTrue(zone.requiresConfirmation)
        zone.markConfirmed()
        XCTAssertFalse(zone.requiresConfirmation)
        zone.command.environment["NEW"] = "value"
        XCTAssertTrue(zone.requiresConfirmation)
    }
}
