import XCTest
@testable import MakiDesk

/// T37: the launcher's ordering and its small use table are decisions, so they
/// are checked without a panel or a real Applications folder.
@MainActor
final class ApplicationLauncherTests: XCTestCase {
    private func app(_ name: String, executable: String? = nil,
                     bundle: String? = nil) -> InstalledApplication {
        InstalledApplication(
            path: "/Applications/\(name).app",
            name: name,
            executable: executable ?? name.lowercased(),
            bundleIdentifier: bundle ?? "test.\(name.replacingOccurrences(of: " ", with: ""))"
        )
    }

    private func usage(_ count: Int, _ day: Double) -> ApplicationUsage {
        ApplicationUsage(count: count, lastUsed: Date(timeIntervalSince1970: day * 86_400))
    }

    // MARK: - Ranking with a query

    func testAnExactNameBeatsAPrefixEvenWhenThePrefixWasUsed() {
        let notes = app("Notes")
        let noteshelf = app("Noteshelf")
        let used: [String: ApplicationUsage] = [noteshelf.usageKey: usage(40, 100)]
        let results = ApplicationSearch.launcherResults([noteshelf, notes],
                                                         query: "notes", usage: used)
        XCTAssertEqual(results.map(\.name), ["Notes", "Noteshelf"])
    }

    func testTypingDoesNotLiftAUsedAppOverABetterMatch() {
        // "Code" is the exact name; Visual Studio Code only contains the word.
        let code = app("Code")
        let visual = app("Visual Studio Code")
        let used: [String: ApplicationUsage] = [visual.usageKey: usage(90, 1_000)]
        let results = ApplicationSearch.launcherResults([visual, code],
                                                         query: "code", usage: used)
        XCTAssertEqual(results.map(\.name), ["Code", "Visual Studio Code"])
    }

    func testRecentUseBreaksATieWithinTheSameRank() {
        // Both are prefix matches for "ma"; the one opened last comes first.
        let mail = app("Mail")
        let maps = app("Maps")
        let used: [String: ApplicationUsage] = [
            mail.usageKey: usage(30, 10),
            maps.usageKey: usage(1, 20)
        ]
        let results = ApplicationSearch.launcherResults([mail, maps],
                                                         query: "ma", usage: used)
        XCTAssertEqual(results.map(\.name), ["Maps", "Mail"])
    }

    func testMoreOpensBreakATieWhenTheDatesAreEqual() {
        let mail = app("Mail")
        let maps = app("Maps")
        let used: [String: ApplicationUsage] = [
            mail.usageKey: usage(30, 10),
            maps.usageKey: usage(1, 10)
        ]
        let results = ApplicationSearch.launcherResults([maps, mail],
                                                         query: "ma", usage: used)
        XCTAssertEqual(results.map(\.name), ["Mail", "Maps"])
    }

    func testNoMatchReturnsNothingRatherThanTheWholeInventory() {
        let results = ApplicationSearch.launcherResults([app("Mail"), app("Maps")],
                                                         query: "zzz", usage: [:])
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - The empty field

    func testAnEmptyFieldShowsRecentsFirstThenTheRestAlphabetically() {
        let alpha = app("Alpha")
        let beta = app("Beta")
        let gamma = app("Gamma")
        let delta = app("Delta")
        let used: [String: ApplicationUsage] = [
            beta.usageKey: usage(2, 10),
            gamma.usageKey: usage(9, 30)
        ]
        let results = ApplicationSearch.launcherResults([alpha, beta, gamma, delta],
                                                         query: "", usage: used)
        // Gamma was used most recently, then Beta; unused apps keep the
        // scanner's alphabetical order.
        XCTAssertEqual(results.map(\.name), ["Gamma", "Beta", "Alpha", "Delta"])
    }

    func testAUsageEntryForAnApplicationThatIsGoneChangesNothing() {
        let mail = app("Mail")
        let used: [String: ApplicationUsage] = ["com.removed.App": usage(9, 99)]
        let results = ApplicationSearch.launcherResults([mail], query: "", usage: used)
        XCTAssertEqual(results.map(\.name), ["Mail"])
    }

    func testTheEmptyFieldIsLimited() {
        let apps = (0..<20).map { app("App\($0)") }
        let results = ApplicationSearch.launcherResults(apps, query: "", usage: [:])
        XCTAssertEqual(results.count, 8)
        XCTAssertEqual(results.first?.name, "App0")
    }

    func testWhitespaceOnlyIsAnEmptyQuery() {
        let results = ApplicationSearch.launcherResults([app("Mail")], query: "   ",
                                                         usage: [:])
        XCTAssertEqual(results.map(\.name), ["Mail"])
    }

    // MARK: - Use table

    func testTheKeyPrefersTheBundleIdentifier() {
        let app = InstalledApplication(path: "/Applications/Thing.app", name: "Thing",
                                       executable: "Thing", bundleIdentifier: "com.test.thing")
        XCTAssertEqual(app.usageKey, "com.test.thing")
        let bare = InstalledApplication(path: "/Applications/Bare.app", name: "Bare",
                                        executable: "Bare", bundleIdentifier: nil)
        XCTAssertEqual(bare.usageKey, "/Applications/Bare.app")
    }

    func testTheStoreCountsAndRemembersTheLastDate() {
        let defaults = makeDefaults()
        defer { clean(defaults) }
        let store = ApplicationUsageStore(defaults: defaults)
        let mail = app("Mail")

        store.record(mail, at: Date(timeIntervalSince1970: 100))
        store.record(mail, at: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(store.usage[mail.usageKey]?.count, 2)
        XCTAssertEqual(store.usage[mail.usageKey]?.lastUsed, Date(timeIntervalSince1970: 200))
    }

    func testTheStoreIsReadBackInAFreshInstance() {
        let defaults = makeDefaults()
        defer { clean(defaults) }
        let maps = app("Maps")
        ApplicationUsageStore(defaults: defaults).record(maps, at: Date(timeIntervalSince1970: 42))

        let reloaded = ApplicationUsageStore(defaults: defaults)
        XCTAssertEqual(reloaded.usage[maps.usageKey]?.count, 1)
        XCTAssertEqual(reloaded.usage[maps.usageKey]?.lastUsed, Date(timeIntervalSince1970: 42))
    }

    func testTheStoreKeepsOnlyTheMostRecentEntries() {
        let defaults = makeDefaults()
        defer { clean(defaults) }
        let store = ApplicationUsageStore(defaults: defaults)
        let apps = (0...ApplicationUsageStore.maximumEntries).map { app("App\($0)") }
        for (index, application) in apps.enumerated() {
            store.record(application, at: Date(timeIntervalSince1970: Double(index)))
        }
        XCTAssertEqual(store.usage.count, ApplicationUsageStore.maximumEntries)
        XCTAssertNil(store.usage[apps[0].usageKey], "the oldest entry goes first")
        XCTAssertNotNil(store.usage[apps.last!.usageKey])
    }

    // MARK: - Helpers

    private func makeDefaults() -> UserDefaults {
        let suite = "MakiDesk-LauncherTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(suite, forKey: "suiteName")
        return defaults
    }

    private func clean(_ defaults: UserDefaults) {
        guard let suite = defaults.string(forKey: "suiteName") else { return }
        defaults.removePersistentDomain(forName: suite)
    }
}
