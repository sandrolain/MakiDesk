import WebKit
import XCTest
@testable import MakiBrowser

@MainActor
final class BrowserTests: XCTestCase {
    func testLifecycleBoundaries() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func tab(age: TimeInterval, pinned: Bool = false) -> BrowserTab {
            BrowserTab(lastUsed: now.addingTimeInterval(-age), isPinned: pinned)
        }

        XCTAssertEqual(BrowserTabLifecycle.phase(for: tab(age: 0), now: now), .active)
        XCTAssertEqual(BrowserTabLifecycle.phase(for: tab(age: 24 * 3600 - 1), now: now), .active)
        XCTAssertEqual(BrowserTabLifecycle.phase(for: tab(age: 24 * 3600), now: now), .old)
        XCTAssertEqual(BrowserTabLifecycle.phase(for: tab(age: 48 * 3600 - 1), now: now), .old)
        XCTAssertFalse(BrowserTabLifecycle.isExpired(tab(age: 48 * 3600 - 1), now: now))
        XCTAssertTrue(BrowserTabLifecycle.isExpired(tab(age: 48 * 3600), now: now))
        XCTAssertEqual(BrowserTabLifecycle.phase(for: tab(age: 72 * 3600, pinned: true), now: now), .pinned)
        XCTAssertFalse(BrowserTabLifecycle.isExpired(tab(age: 72 * 3600, pinned: true), now: now))
    }

    func testOrderingIsPinnedThenActiveThenOldAndMRU() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pinnedOld = BrowserTab(title: "pinned-old", lastUsed: now.addingTimeInterval(-72 * 3600), isPinned: true)
        let pinnedNew = BrowserTab(title: "pinned-new", lastUsed: now.addingTimeInterval(-1 * 3600), isPinned: true)
        let activeNew = BrowserTab(title: "active-new", lastUsed: now.addingTimeInterval(-60))
        let activeOld = BrowserTab(title: "active-old", lastUsed: now.addingTimeInterval(-2 * 3600))
        let old = BrowserTab(title: "old", lastUsed: now.addingTimeInterval(-30 * 3600))

        let ordered = BrowserTabLifecycle.ordered([activeOld, old, pinnedOld, activeNew, pinnedNew], now: now)
        XCTAssertEqual(ordered.map(\.title), ["pinned-new", "pinned-old", "active-new", "active-old", "old"])
    }

    func testRelativeTimeUsesFiveMinuteSteps() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func label(_ seconds: TimeInterval) -> String {
            BrowserTimeLabel.string(since: now.addingTimeInterval(-seconds), now: now)
        }
        XCTAssertEqual(label(0), "now")
        XCTAssertEqual(label(299), "now")
        XCTAssertEqual(label(300), "5m")
        XCTAssertEqual(label(3599), "55m")
        XCTAssertEqual(label(3600), "1h")
        XCTAssertEqual(label(3900), "1h 5m")
        XCTAssertEqual(label(24 * 3600), "1d")
        XCTAssertEqual(label(26 * 3600), "1d 2h")
    }

    func testRegistrableDomainNormalization() {
        func domain(_ value: String) -> String? {
            guard let url = URL(string: value) else { return nil }
            return BrowserDomain.registrableDomain(url)
        }
        XCTAssertEqual(domain("https://www.example.com/a"), "example.com")
        XCTAssertEqual(domain("https://sub.example.co.uk/a"), "example.co.uk")
        XCTAssertEqual(domain("https://a.b.example.com"), "example.com")
        XCTAssertEqual(domain("http://localhost:8080"), "localhost")
        XCTAssertEqual(domain("http://192.168.1.10/x"), "192.168.1.10")
    }

    func testBlockerPrecedence() {
        var settings = BrowserSettings()
        let old = BrowserTab(lastUsed: .distantPast)
        XCTAssertTrue(BrowserBlockerPolicy.isEnabled(settings: settings, tab: old, domain: "example.com"))

        settings.disabledBlockerDomains.insert("example.com")
        XCTAssertFalse(BrowserBlockerPolicy.isEnabled(settings: settings, tab: old, domain: "example.com"))
        XCTAssertTrue(BrowserBlockerPolicy.isEnabled(settings: settings, tab: old, domain: "other.com"))

        var override = old
        override.blockerOverride = true
        XCTAssertTrue(BrowserBlockerPolicy.isEnabled(settings: settings, tab: override, domain: "example.com"))

        settings.blockerEnabledByDefault = false
        XCTAssertFalse(BrowserBlockerPolicy.isEnabled(settings: settings, tab: override, domain: "other.com"))
    }

    func testAddressInput() {
        XCTAssertEqual(BrowserURLInput.url(from: "https://example.com/a")?.absoluteString,
                       "https://example.com/a")
        XCTAssertEqual(BrowserURLInput.url(from: "example.com")?.absoluteString,
                       "https://example.com")
        let search = BrowserURLInput.url(from: "swift webkit")
        XCTAssertEqual(search?.host, "www.google.com")
        XCTAssertEqual(search?.query, "q=swift%20webkit")
        let duck = BrowserURLInput.url(from: "swift webkit", searchEngine: .duckDuckGo)
        XCTAssertEqual(duck?.host, "duckduckgo.com")
    }

    func testPersistenceRoundTripAndExpiredDrop() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiBrowserTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = BrowserTabStore(fileURL: directory.appendingPathComponent("tabs.json"))
        let now = Date()
        let active = BrowserTab(title: "active", lastUsed: now)
        let expired = BrowserTab(title: "expired", lastUsed: now.addingTimeInterval(-49 * 3600))
        let pinned = BrowserTab(title: "pinned", lastUsed: now.addingTimeInterval(-100 * 3600), isPinned: true)
        let payload = BrowserTabsPayload(tabs: [active, expired, pinned],
                                        selectedTabID: expired.id,
                                        sidebarWidth: 280)
        XCTAssertTrue(store.save(payload))

        let loaded = store.load(now: now)
        XCTAssertEqual(loaded.tabs.map(\.title), ["active", "pinned"])
        XCTAssertEqual(loaded.selectedTabID, active.id)
        XCTAssertEqual(loaded.sidebarWidth, 280)
    }

    func testNewTabSelectsAnEmptyTabAndPrefillsTheDefaultPage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiBrowserNewTab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = BrowserStore(
            tabStore: BrowserTabStore(fileURL: directory.appendingPathComponent("tabs.json")),
            settingsStore: BrowserSettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            historyStore: BrowserHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        )
        store.settings.defaultPageURL = "https://example.org/start"
        let tab = store.newTab()
        XCTAssertEqual(store.selectedTabID, tab.id)
        XCTAssertNotNil(store.selectedSession)
        XCTAssertTrue(store.isAddressVisible)
        XCTAssertEqual(store.addressText, "https://example.org/start")
        XCTAssertNil(tab.url)
        store.stop()
    }

    func testSearchEngineSelection() {
        XCTAssertEqual(BrowserURLInput.url(from: "swift webkit")?.host, "www.google.com")
        XCTAssertEqual(BrowserURLInput.url(from: "swift webkit", searchEngine: .duckDuckGo)?.host,
                       "duckduckgo.com")
        XCTAssertEqual(BrowserURLInput.url(from: "swift webkit", searchEngine: .bing)?.host,
                       "www.bing.com")
    }

    func testAddressSuggestionsUseLocalHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiBrowserHistory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let historyStore = BrowserHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let entries = [
            BrowserHistoryEntry(url: URL(string: "https://example.com/a")!, title: "Example A", lastVisited: Date()),
            BrowserHistoryEntry(url: URL(string: "https://other.com/b")!, title: "Other", lastVisited: Date()),
        ]
        XCTAssertTrue(historyStore.save(entries))
        let loaded = historyStore.load()
        XCTAssertEqual(loaded.count, 2)

        let store = BrowserStore(
            tabStore: BrowserTabStore(fileURL: directory.appendingPathComponent("tabs.json")),
            settingsStore: BrowserSettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            historyStore: historyStore
        )
        store.history = loaded
        store.addressText = "example"
        XCTAssertEqual(store.addressSuggestions.map(\.title), ["Example A"])
    }

    func testBlockerRulesAreValidJSON() throws {
        let json = try XCTUnwrap(BrowserAdBlocker.rulesJSON())
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        let rules = try XCTUnwrap(object as? [[String: Any]])
        XCTAssertEqual(rules.count, BrowserAdBlocker.starterDomains.count)
        XCTAssertTrue(rules.allSatisfy { $0["trigger"] is [String: Any] })
    }

    func testStarterBlockerCompilesInWebKit() async throws {
        let json = try XCTUnwrap(BrowserAdBlocker.rulesJSON())
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        let identifier = "makidesk-browser-test-\(UUID().uuidString)"
        let list: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier,
                                         encodedContentRuleList: json) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: error ?? BrowserTestError.compileFailed)
                }
            }
        }
        XCTAssertGreaterThan(list.identifier.count, 0)
    }

    func testStorePreparesBlockerAndCreatesASession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiBrowserStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = BrowserStore(
            tabStore: BrowserTabStore(fileURL: directory.appendingPathComponent("tabs.json")),
            settingsStore: BrowserSettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        )
        await store.start()
        XCTAssertTrue(store.isStarted)
        XCTAssertNotNil(store.blockerList)
        XCTAssertNotNil(store.selectedSession)
        XCTAssertEqual(store.tabs.count, 1)
        store.stop()
    }

    func testFaviconFallbackIsStable() {
        XCTAssertEqual(BrowserColor.fallback(for: "example.com"),
                       BrowserColor.fallback(for: "example.com"))
        XCTAssertNotEqual(BrowserColor.fallback(for: "example.com"),
                          BrowserColor.fallback(for: "other.com"))
        let color = BrowserColor.fallback(for: "example.com")
        XCTAssertTrue((0...1).contains(color.red))
        XCTAssertTrue((0...1).contains(color.green))
        XCTAssertTrue((0...1).contains(color.blue))
    }
}

private enum BrowserTestError: Error {
    case compileFailed
}
