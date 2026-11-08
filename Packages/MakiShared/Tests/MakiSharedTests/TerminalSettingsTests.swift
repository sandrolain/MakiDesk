import XCTest
@testable import MakiShared

final class TerminalSettingsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiTerminalSettings-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testDefaultsAreUsable() {
        let settings = TerminalSettingsDocument.defaults
        XCTAssertEqual(settings.fontSize, 13)
        XCTAssertNil(settings.fontFamily)
        XCTAssertNil(settings.shell)
        XCTAssertEqual(settings.quakeHeightFraction, 0.45, accuracy: 0.001)
        XCTAssertEqual(settings.cursorStyle, .block)
        XCTAssertTrue(settings.cursorBlink)
        XCTAssertNil(settings.scrollbackLimitMB)
    }

    func testAnOlderSettingsFileGainsTheNewDefaults() throws {
        let old = """
        {"version":1,"fontFamily":"Menlo","fontSize":14,"shell":"/bin/zsh","quakeHeightFraction":0.5}
        """
        let settings = try JSONDecoder().decode(TerminalSettingsDocument.self,
                                                from: Data(old.utf8))
        XCTAssertEqual(settings.fontFamily, "Menlo")
        XCTAssertEqual(settings.cursorStyle, .block)
        XCTAssertTrue(settings.cursorBlink)
        XCTAssertNil(settings.scrollbackLimitMB)
    }

    func testCursorShapesAndScrollbackRoundTrip() {
        let settings = TerminalSettingsDocument(cursorStyle: .bar,
                                                cursorBlink: false,
                                                scrollbackLimitMB: 20)
        let data = try! JSONEncoder().encode(settings)
        let decoded = try! JSONDecoder().decode(TerminalSettingsDocument.self, from: data)
        XCTAssertEqual(decoded.cursorStyle, .bar)
        XCTAssertFalse(decoded.cursorBlink)
        XCTAssertEqual(decoded.scrollbackLimitMB, 20)
    }

    func testNormalizationClampsTheScrollbackAndChecksTheShape() {
        XCTAssertEqual(TerminalSettingsDocument(scrollbackLimitMB: 0).normalized().scrollbackLimitMB, 1)
        XCTAssertEqual(TerminalSettingsDocument(scrollbackLimitMB: 5000).normalized().scrollbackLimitMB, 1024)
        XCTAssertNil(TerminalSettingsDocument(scrollbackLimitMB: nil).normalized().scrollbackLimitMB)

        let raw = #"{"cursorStyle":"block_hollow"}"#
        let decoded = try! JSONDecoder().decode(TerminalSettingsDocument.self,
                                                from: Data(raw.utf8))
        XCTAssertEqual(decoded.cursorStyle, .blockHollow)
        XCTAssertEqual(decoded.cursorStyle.rawValue, "block_hollow")
    }

    func testNormalizationClampsAndCleans() {
        let settings = TerminalSettingsDocument(fontFamily: "  ", fontSize: 99,
                                                shell: " /bin/fish ", quakeHeightFraction: 0.1)
        let normalized = settings.normalized()
        XCTAssertNil(normalized.fontFamily)
        XCTAssertEqual(normalized.fontSize, 20)
        XCTAssertEqual(normalized.shell, "/bin/fish")
        XCTAssertEqual(normalized.quakeHeightFraction, 0.3, accuracy: 0.001)
    }

    func testTheSettingsStoreRoundTrips() {
        let store = TerminalSettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        let settings = TerminalSettingsDocument(fontFamily: "Menlo", fontSize: 15,
                                                shell: "/bin/zsh", quakeHeightFraction: 0.5)
        XCTAssertTrue(store.save(settings))
        XCTAssertEqual(store.load(), settings)
    }

    func testACorruptSettingsFileFallsBackAndIsSetAside() throws {
        let url = directory.appendingPathComponent("settings.json")
        try Data("not json".utf8).write(to: url)
        let store = TerminalSettingsStore(fileURL: url)
        XCTAssertEqual(store.load(), .defaults)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathExtension("bak").path))
    }

    func testThemeNormalizationKeepsSixteenColours() {
        let theme = TerminalThemeDocument(id: "test", name: "Test",
                                          background: "oops", foreground: "#AbCdEf",
                                          cursor: "#123456", selectionBackground: "#000000",
                                          selectionForeground: "#FFFFFF",
                                          ansi: ["#111111"]).normalized()
        XCTAssertEqual(theme.foreground, "#ABCDEF")
        XCTAssertEqual(theme.background, TerminalThemeDocument.fallback.background)
        XCTAssertEqual(theme.surface, theme.background)
        XCTAssertEqual(theme.subtext, theme.foreground)
        XCTAssertEqual(theme.accent, "#123456")
        XCTAssertEqual(theme.ansi.count, 16)
        XCTAssertEqual(theme.ansi[0], "#111111")
        XCTAssertEqual(theme.ansi[1], TerminalThemeDocument.standardANSI[1])
    }

    func testTheThemeStoreRoundTrips() {
        let store = TerminalThemeStore(fileURL: directory.appendingPathComponent("theme.json"))
        var theme = TerminalThemeDocument.fallback
        theme.background = "#101010"
        XCTAssertTrue(store.save(theme))
        XCTAssertEqual(store.load(), theme)
    }

    func testAMissingThemeFileUsesTheFallback() {
        let store = TerminalThemeStore(fileURL: directory.appendingPathComponent("theme.json"))
        XCTAssertEqual(store.load(), .fallback)
    }

    func testAnSSHProfileBecomesACommandLine() {
        let profile = TerminalSSHProfile(name: "Build", host: "example.com",
                                         user: "deploy", port: 2222,
                                         identityFile: "/Users/me/.ssh/id_ed25519",
                                         remoteCommand: "cd /srv && ./run", forwardAgent: true)
        XCTAssertEqual(profile.commandLine(),
                       "ssh -p 2222 -i /Users/me/.ssh/id_ed25519 -A deploy@example.com 'cd /srv && ./run'")
    }

    func testAnSSHProfileWithoutAUserOrExtrasIsShort() {
        let profile = TerminalSSHProfile(host: "example.com")
        XCTAssertEqual(profile.commandLine(), "ssh example.com")
    }

    func testAnInvalidSSHProfileHasNoCommand() {
        XCTAssertNil(TerminalSSHProfile(host: "   ").commandLine())
        XCTAssertFalse(TerminalSSHProfile(host: "").isValid)
        XCTAssertFalse(TerminalSSHProfile(host: "example.com", port: 0).isValid)
    }

    func testAProfileWithSpacesIsQuoted() {
        let profile = TerminalSSHProfile(host: "example.com",
                                         identityFile: "/Users/me/My Keys/id")
        XCTAssertEqual(profile.commandLine(), "ssh -i '/Users/me/My Keys/id' example.com")
    }

    func testProfilesSurviveTheSettingsFile() {
        let store = TerminalSettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        let profile = TerminalSSHProfile(name: "  Build  ", host: " example.com ",
                                         user: "deploy", port: 2222)
        var settings = TerminalSettingsDocument.defaults
        settings.sshProfiles = [profile]
        XCTAssertTrue(store.save(settings))
        let loaded = store.load()
        XCTAssertEqual(loaded.sshProfiles.count, 1)
        XCTAssertEqual(loaded.sshProfiles.first?.name, "Build")
        XCTAssertEqual(loaded.sshProfiles.first?.host, "example.com")
        XCTAssertEqual(loaded.sshProfiles.first?.port, 2222)
    }
}
