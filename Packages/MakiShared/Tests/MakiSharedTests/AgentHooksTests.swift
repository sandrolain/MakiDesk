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
        let result = try AgentHooks.install(for: .claudeCode, command: command, settingsURL: settings)
        XCTAssertTrue(result.changed)
        XCTAssertNil(result.backupURL)
        let found = try handlers(in: object())
        XCTAssertEqual(found.count, AgentHooks.Agent.claudeCode.events.count)
        XCTAssertEqual(Set(found.map(\.event)), Set(AgentHooks.Agent.claudeCode.events.map(\.name)))
        for item in found {
            XCTAssertEqual(item.handler["type"] as? String, "command")
            XCTAssertEqual(item.handler["command"] as? String, command)
            XCTAssertEqual(item.handler["timeout"] as? Int, 5)
            let args = try XCTUnwrap(item.handler["args"] as? [String])
            XCTAssertEqual(args.first, AgentHooks.markerArgument)
            let state = try XCTUnwrap(AgentHooks.Agent.claudeCode.events.first { $0.name == item.event }?.state)
            XCTAssertEqual(args[1], state.rawValue)
        }
        let notification = try XCTUnwrap(found.first { $0.event == "Notification" })
        XCTAssertEqual(notification.matcher, "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input")
        let stop = try XCTUnwrap(found.first { $0.event == "Stop" })
        XCTAssertNil(stop.matcher)
    }

    func testCodexHasItsOwnFileEventsAndTimeout() throws {
        try Data(#"{"description":"My hooks"}"#.utf8).write(to: settings)
        let result = try AgentHooks.install(for: .codex, command: command, settingsURL: settings)
        XCTAssertTrue(result.changed)

        var root = try object()
        XCTAssertEqual(root["description"] as? String, "My hooks")
        let found = try handlers(in: root)
        XCTAssertEqual(found.count, 6)
        XCTAssertEqual(Set(found.map(\.event)),
                       ["UserPromptSubmit", "PermissionRequest", "PreModelRequest",
                        "Stop", "Interrupt", "SessionEnd"])
        XCTAssertNil(found.first { $0.event == "Notification" })
        let waiting = try XCTUnwrap(found.first { $0.event == "PermissionRequest" })
        XCTAssertEqual((waiting.handler["args"] as? [String])?[1], "waiting")
        XCTAssertEqual(waiting.handler["timeout"] as? Int, 3)
        XCTAssertEqual(waiting.handler["command"] as? String, command)
        XCTAssertEqual((waiting.handler["args"] as? [String])?.last, "Codex")

        XCTAssertEqual(AgentHooks.status(for: .codex, settingsURL: settings).state, .installed)
        _ = try AgentHooks.uninstall(from: .codex, settingsURL: settings)
        root = try object()
        XCTAssertEqual(root["description"] as? String, "My hooks")
        XCTAssertNil(root["hooks"])
    }

    func testCodexKeepsAnotherAgentsFileApart() throws {
        _ = try AgentHooks.install(for: .claudeCode, command: command, settingsURL: settings)
        let other = directory.appendingPathComponent("hooks.json")
        _ = try AgentHooks.install(for: .codex, command: command, settingsURL: other)
        _ = try AgentHooks.uninstall(from: .codex, settingsURL: other)
        XCTAssertEqual(AgentHooks.status(for: .claudeCode, settingsURL: settings).state,
                       .installed)
        XCTAssertEqual(AgentHooks.status(for: .codex, settingsURL: other).state, .absent)
    }

    func testInstallingTwiceChangesNothing() throws {
        _ = try AgentHooks.install(for: .claudeCode, command: command, settingsURL: settings)
        let before = try Data(contentsOf: settings)
        let second = try AgentHooks.install(for: .claudeCode, command: command, settingsURL: settings)
        XCTAssertFalse(second.changed)
        XCTAssertEqual(try Data(contentsOf: settings), before)
    }

    func testAMovedCommandReplacesTheOldPath() throws {
        _ = try AgentHooks.install(for: .claudeCode, command: command, settingsURL: settings)
        let moved = "/Applications/MakiDesk.app/Contents/Resources/bin/makidesk"
        let result = try AgentHooks.install(for: .claudeCode, command: moved, settingsURL: settings)
        XCTAssertTrue(result.changed)
        let commands = Set(try handlers(in: object()).compactMap { $0.handler["command"] as? String })
        XCTAssertEqual(commands, [moved])
    }

    func testTheOriginalFileIsBackedUpOnce() throws {
        try Data(#"{"model":"opus","permissions":{"allow":["Bash"]}}"#.utf8).write(to: settings)
        let first = try AgentHooks.install(for: .claudeCode, command: command, settingsURL: settings)
        let backup = try XCTUnwrap(first.backupURL)
        XCTAssertEqual(backup, AgentHooks.backupURL(for: settings))
        XCTAssertEqual(try Data(contentsOf: backup),
                       Data(#"{"model":"opus","permissions":{"allow":["Bash"]}}"#.utf8))

        _ = try AgentHooks.uninstall(from: .claudeCode, settingsURL: settings)
        let second = try AgentHooks.install(for: .claudeCode, command: command, settingsURL: settings)
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

        _ = try AgentHooks.install(for: .claudeCode, command: command, settingsURL: settings)
        var root = try object()
        XCTAssertEqual(root["model"] as? String, "opus")
        var stop = try XCTUnwrap((root["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2)
        XCTAssertTrue(stop.contains { ($0["hooks"] as? [[String: Any]])?
            .contains { $0["command"] as? String == "/usr/bin/true" } ?? false })

        _ = try AgentHooks.uninstall(from: .claudeCode, settingsURL: settings)
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
        let result = try AgentHooks.uninstall(from: .claudeCode, settingsURL: settings)
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
        let result = try AgentHooks.uninstall(from: .claudeCode, settingsURL: settings)
        XCTAssertTrue(result.changed)
        let found = try handlers(in: object())
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.handler["command"] as? String, "/usr/bin/true")
    }

    func testTheHooksKeyDisappearsWhenNothingIsLeft() throws {
        _ = try AgentHooks.install(for: .claudeCode, command: command, settingsURL: settings)
        _ = try AgentHooks.uninstall(from: .claudeCode, settingsURL: settings)
        XCTAssertNil(try object()["hooks"])
    }

    func testUninstallOnAMissingFileIsANoOp() throws {
        let result = try AgentHooks.uninstall(from: .claudeCode, settingsURL: settings)
        XCTAssertFalse(result.changed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path))
    }

    func testStatusFollowsTheInstallation() throws {
        XCTAssertEqual(AgentHooks.status(for: .claudeCode, settingsURL: settings).state, .absent)

        _ = try AgentHooks.install(for: .claudeCode, command: command, settingsURL: settings)
        var status = AgentHooks.status(for: .claudeCode, settingsURL: settings)
        XCTAssertEqual(status.state, .installed)
        XCTAssertEqual(status.present, AgentHooks.Agent.claudeCode.events.count)
        XCTAssertEqual(status.expected, AgentHooks.Agent.claudeCode.events.count)
        XCTAssertEqual(status.command, command)

        _ = try AgentHooks.uninstall(from: .claudeCode, settingsURL: settings)
        status = AgentHooks.status(for: .claudeCode, settingsURL: settings)
        XCTAssertEqual(status.state, .absent)
        XCTAssertEqual(status.present, 0)
    }

    func testAPartialInstallationIsReported() throws {
        try Data("""
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/x/makidesk","args":["hook","done"]}]}]}}
        """.utf8).write(to: settings)
        let status = AgentHooks.status(for: .claudeCode, settingsURL: settings)
        XCTAssertEqual(status.state, .partial)
        XCTAssertEqual(status.present, 1)
    }

    func testInvalidJSONIsNeverOverwritten() throws {
        let broken = Data("{ not json".utf8)
        try broken.write(to: settings)
        XCTAssertThrowsError(try AgentHooks.install(for: .claudeCode, command: command, settingsURL: settings)) { error in
            XCTAssertEqual(error as? AgentHooks.HookError,
                           .invalidSettings(settings.path))
        }
        XCTAssertEqual(try Data(contentsOf: settings), broken)
        XCTAssertEqual(AgentHooks.status(for: .claudeCode, settingsURL: settings).state, .unreadable)
    }

    func testAMalformedHooksValueIsRefused() throws {
        let original = Data(#"{"hooks":"nope"}"#.utf8)
        try original.write(to: settings)
        XCTAssertThrowsError(try AgentHooks.install(for: .claudeCode, command: command, settingsURL: settings)) { error in
            XCTAssertEqual(error as? AgentHooks.HookError,
                           .invalidHooks(settings.path))
        }
        XCTAssertEqual(try Data(contentsOf: settings), original)
    }

    func testARelativeCommandIsRefused() {
        XCTAssertThrowsError(try AgentHooks.install(for: .claudeCode, command: "bin/makidesk", settingsURL: settings)) { error in
            guard case .writeFailed = error as? AgentHooks.HookError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path))
    }

    func testAConfigWithOnlyOurHooksRoundTrips() throws {
        _ = try AgentHooks.install(for: .claudeCode, command: command, settingsURL: settings)
        _ = try AgentHooks.uninstall(from: .claudeCode, settingsURL: settings)
        let status = AgentHooks.status(for: .claudeCode, settingsURL: settings)
        XCTAssertEqual(status.state, .absent)
        XCTAssertEqual(status.present, 0)
    }
}
