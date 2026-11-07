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
}
