import XCTest
@testable import MakiDesk

final class ApplicationSearchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDesk-Applications-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Scanner

    func testScannerFindsAppsInFoldersAndSkipsHiddenAndDuplicateBundles() throws {
        try makeApp("Safari", displayName: "Safari", executable: "Safari",
                    bundleID: "com.apple.Safari")
        try makeApp("Utilities/Terminal", displayName: "Terminal", executable: "Terminal",
                    bundleID: "com.apple.Terminal")
        try makeApp("Copy/Safari Copy", displayName: "Safari Copy", executable: "Safari",
                    bundleID: "com.apple.Safari")
        try makeApp(".Hidden", displayName: "Hidden", executable: "Hidden",
                    bundleID: "test.hidden")

        let apps = ApplicationScanner.scan(roots: [root])

        XCTAssertEqual(apps.map(\.name), ["Safari", "Terminal"])
        XCTAssertEqual(apps.first?.executable, "Safari")
        XCTAssertEqual(apps.first?.bundleIdentifier, "com.apple.Safari")
    }

    func testScannerSkipsBundlesWithoutAnInfoPlist() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Broken.app/Contents"),
            withIntermediateDirectories: true
        )

        XCTAssertTrue(ApplicationScanner.scan(roots: [root]).isEmpty)
    }

    func testScannerFallsBackToTheBundleFileName() throws {
        try makeApp("Notes", displayName: nil, executable: nil, bundleID: nil)

        let app = try XCTUnwrap(ApplicationScanner.scan(roots: [root]).first)
        XCTAssertEqual(app.name, "Notes")
        XCTAssertEqual(app.executable, "Notes")
        XCTAssertNil(app.bundleIdentifier)
    }

    // MARK: - Search ranking

    func testSearchRanksTheNameBeforeTheExecutableAndIsCaseInsensitive() {
        let apps = [
            application("Safari", executable: "Safari"),
            application("Calendar", executable: "Calendar"),
            application("Visual Studio Code", executable: "Electron"),
            application("Café", executable: "Café")
        ]

        XCTAssertEqual(ApplicationSearch.matches(apps, query: "SAF").map(\.name), ["Safari"])
        XCTAssertEqual(ApplicationSearch.matches(apps, query: "cal").map(\.name), ["Calendar"])
        XCTAssertEqual(ApplicationSearch.matches(apps, query: "cafe").map(\.name), ["Café"])
        XCTAssertEqual(ApplicationSearch.matches(apps, query: "electron").map(\.name),
                       ["Visual Studio Code"])
    }

    func testSearchMatchesWordStartsAndAllQueryTokens() {
        let apps = [
            application("Visual Studio Code", executable: "Electron"),
            application("Code Runner", executable: "CodeRunner"),
            application("Code", executable: "Code")
        ]

        XCTAssertEqual(ApplicationSearch.matches(apps, query: "studio").map(\.name),
                       ["Visual Studio Code"])
        XCTAssertEqual(ApplicationSearch.matches(apps, query: "visual code").map(\.name),
                       ["Visual Studio Code"])
        // Exact, then prefix, then a word start.
        XCTAssertEqual(ApplicationSearch.matches(apps, query: "code").map(\.name),
                       ["Code", "Code Runner", "Visual Studio Code"])
    }

    func testEmptyQueryAndLimitReturnNothingOrTheBestMatches() {
        let apps = (1...20).map { application("App \($0)", executable: "App\($0)") }

        XCTAssertTrue(ApplicationSearch.matches(apps, query: "   ").isEmpty)
        XCTAssertEqual(ApplicationSearch.matches(apps, query: "app", limit: 5).count, 5)
        XCTAssertTrue(ApplicationSearch.matches(apps, query: "app", limit: 0).isEmpty)
    }

    // MARK: - Helpers

    private func application(_ name: String, executable: String) -> InstalledApplication {
        InstalledApplication(path: "/Applications/\(name).app", name: name,
                             executable: executable, bundleIdentifier: nil)
    }

    private func makeApp(_ relativePath: String, displayName: String?,
                         executable: String?, bundleID: String?) throws {
        let app = root.appendingPathComponent("\(relativePath).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundlePackageType": "APPL"]
        info["CFBundleDisplayName"] = displayName
        info["CFBundleExecutable"] = executable
        info["CFBundleIdentifier"] = bundleID
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
