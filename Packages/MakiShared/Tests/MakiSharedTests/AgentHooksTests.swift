import XCTest
@testable import MakiShared

final class AgentHooksTests: XCTestCase {
    private var directory: URL!
    private var settings: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiAgentHooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settings = directory.appendingPathComponent("settings.json")
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private let command = "/Users/me/Library/Application Support/MakiDesk/Terminal/bin/makidesk"

    private func object() throws -> [String: Any] {
        let data = try Data(contentsOf: settings)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func handlers(in root: [String: Any]) throws -> [(event: String, matcher: String?, handler: [String: Any])] {
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        var result: [(String, String?, [String: Any])] = []
        for (event, value) in hooks {
            for group in try XCTUnwrap(value as? [[String: Any]]) {
                for handler in try XCTUnwrap(group["hooks"] as? [[String: Any]]) {
                    result.append((event, group["matcher"] as? String, handler))
                }
            }
        }
        return result
    }

    func testInstallCreatesOneHandlerPerEvent() throws {
        let result = try AgentHooks.install(into: settings, command: command)
        XCTAssertTrue(result.changed)
        XCTAssertNil(result.backupURL)
        let found = try handlers(in: object())
        XCTAssertEqual(found.count, AgentHooks.events.count)
        XCTAssertEqual(Set(found.map(\.event)), Set(AgentHooks.events.map(\.name)))
        for item in found {
            XCTAssertEqual(item.handler["type"] as? String, "command")
            XCTAssertEqual(item.handler["command"] as? String, command)
            XCTAssertEqual(item.handler["timeout"] as? Int, 5)
            let args = try XCTUnwrap(item.handler["args"] as? [String])
            XCTAssertEqual(args.first, AgentHooks.markerArgument)
            let state = try XCTUnwrap(AgentHooks.events.first { $0.name == item.event }?.state)
            XCTAssertEqual(args[1], state.rawValue)
        }
        let notification = try XCTUnwrap(found.first { $0.event == "Notification" })
        XCTAssertEqual(notification.matcher, "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input")
        let stop = try XCTUnwrap(found.first { $0.event == "Stop" })
        XCTAssertNil(stop.matcher)
    }

    func testInstallingTwiceChangesNothing() throws {
        _ = try AgentHooks.install(into: settings, command: command)
        let before = try Data(contentsOf: settings)
        let second = try AgentHooks.install(into: settings, command: command)
        XCTAssertFalse(second.changed)
        XCTAssertEqual(try Data(contentsOf: settings), before)
    }

    func testAMovedCommandReplacesTheOldPath() throws {
        _ = try AgentHooks.install(into: settings, command: command)
        let moved = "/Applications/MakiDesk.app/Contents/Resources/bin/makidesk"
        let result = try AgentHooks.install(into: settings, command: moved)
        XCTAssertTrue(result.changed)
        let commands = Set(try handlers(in: object()).compactMap { $0.handler["command"] as? String })
        XCTAssertEqual(commands, [moved])
    }

    func testTheOriginalFileIsBackedUpOnce() throws {
        try Data(#"{"model":"opus","permissions":{"allow":["Bash"]}}"#.utf8).write(to: settings)
        let first = try AgentHooks.install(into: settings, command: command)
        let backup = try XCTUnwrap(first.backupURL)
        XCTAssertEqual(backup, AgentHooks.backupURL(for: settings))
        XCTAssertEqual(try Data(contentsOf: backup),
                       Data(#"{"model":"opus","permissions":{"allow":["Bash"]}}"#.utf8))

        _ = try AgentHooks.uninstall(from: settings)
        let second = try AgentHooks.install(into: settings, command: command)
        XCTAssertNil(second.backupURL)
        XCTAssertEqual(try Data(contentsOf: backup),
                       Data(#"{"model":"opus","permissions":{"allow":["Bash"]}}"#.utf8))
    }

    func testOtherSettingsAndHooksSurviveBothOperations() throws {
        let original = """
        {
          "model": "opus",
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "command": "/usr/bin/true" } ] }
            ],
            "PreToolUse": [
              { "matcher": "Bash", "hooks": [ { "type": "command", "command": "/bin/echo" } ] }
            ]
          }
        }
        """
        try Data(original.utf8).write(to: settings)

        _ = try AgentHooks.install(into: settings, command: command)
        var root = try object()
        XCTAssertEqual(root["model"] as? String, "opus")
        var stop = try XCTUnwrap((root["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2)
        XCTAssertTrue(stop.contains { ($0["hooks"] as? [[String: Any]])?
            .contains { $0["command"] as? String == "/usr/bin/true" } ?? false })

        _ = try AgentHooks.uninstall(from: settings)
        root = try object()
        XCTAssertEqual(root["model"] as? String, "opus")
        stop = try XCTUnwrap((root["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 1)
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["PreToolUse"])
        XCTAssertNil(hooks["UserPromptSubmit"])
        XCTAssertNil(hooks["SessionEnd"])
    }

    func testUninstallAlsoClearsEventsThisVersionDoesNotInstall() throws {
        try Data("""
        {"hooks":{"SomeOldEvent":[{"hooks":[{"type":"command","command":"/x/makidesk","args":["hook","done"]}]}]}}
        """.utf8).write(to: settings)
        let result = try AgentHooks.uninstall(from: settings)
        XCTAssertTrue(result.changed)
        XCTAssertNil(try object()["hooks"])
    }

    func testUninstallRemovesOnlyMarkedHandlers() throws {
        let original = """
        {
          "hooks": {
            "Stop": [
              { "hooks": [
                { "type": "command", "command": "/usr/bin/true" },
                { "type": "command", "command": "/x/makidesk", "args": ["hook", "done"] }
              ] }
            ]
          }
        }
        """
        try Data(original.utf8).write(to: settings)
        let result = try AgentHooks.uninstall(from: settings)
        XCTAssertTrue(result.changed)
        let found = try handlers(in: object())
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.handler["command"] as? String, "/usr/bin/true")
    }

    func testTheHooksKeyDisappearsWhenNothingIsLeft() throws {
        _ = try AgentHooks.install(into: settings, command: command)
        _ = try AgentHooks.uninstall(from: settings)
        XCTAssertNil(try object()["hooks"])
    }

    func testUninstallOnAMissingFileIsANoOp() throws {
        let result = try AgentHooks.uninstall(from: settings)
        XCTAssertFalse(result.changed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path))
    }

    func testStatusFollowsTheInstallation() throws {
        XCTAssertEqual(AgentHooks.status(in: settings).state, .absent)

        _ = try AgentHooks.install(into: settings, command: command)
        var status = AgentHooks.status(in: settings)
        XCTAssertEqual(status.state, .installed)
        XCTAssertEqual(status.present, AgentHooks.events.count)
        XCTAssertEqual(status.expected, AgentHooks.events.count)
        XCTAssertEqual(status.command, command)

        _ = try AgentHooks.uninstall(from: settings)
        status = AgentHooks.status(in: settings)
        XCTAssertEqual(status.state, .absent)
        XCTAssertEqual(status.present, 0)
    }

    func testAPartialInstallationIsReported() throws {
        try Data("""
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/x/makidesk","args":["hook","done"]}]}]}}
        """.utf8).write(to: settings)
        let status = AgentHooks.status(in: settings)
        XCTAssertEqual(status.state, .partial)
        XCTAssertEqual(status.present, 1)
    }

    func testInvalidJSONIsNeverOverwritten() throws {
        let broken = Data("{ not json".utf8)
        try broken.write(to: settings)
        XCTAssertThrowsError(try AgentHooks.install(into: settings, command: command)) { error in
            XCTAssertEqual(error as? AgentHooks.HookError,
                           .invalidSettings(settings.path))
        }
        XCTAssertEqual(try Data(contentsOf: settings), broken)
        XCTAssertEqual(AgentHooks.status(in: settings).state, .unreadable)
    }

    func testAMalformedHooksValueIsRefused() throws {
        let original = Data(#"{"hooks":"nope"}"#.utf8)
        try original.write(to: settings)
        XCTAssertThrowsError(try AgentHooks.install(into: settings, command: command)) { error in
            XCTAssertEqual(error as? AgentHooks.HookError,
                           .invalidHooks(settings.path))
        }
        XCTAssertEqual(try Data(contentsOf: settings), original)
    }

    func testARelativeCommandIsRefused() {
        XCTAssertThrowsError(try AgentHooks.install(into: settings, command: "bin/makidesk")) { error in
            guard case .writeFailed = error as? AgentHooks.HookError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path))
    }

    func testAConfigWithOnlyOurHooksRoundTrips() throws {
        _ = try AgentHooks.install(into: settings, command: command)
        _ = try AgentHooks.uninstall(from: settings)
        let status = AgentHooks.status(in: settings)
        XCTAssertEqual(status.state, .absent)
        XCTAssertEqual(status.present, 0)
    }
}
