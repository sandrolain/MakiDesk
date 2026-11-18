import AppKit
import WebKit
import XCTest
import MakiShared
@testable import MakiBrowser

@MainActor
final class BrowserTests: XCTestCase {
    func testCustomThemeSetsBrowserChromeColorsAndAppearance() {
        let document = TerminalThemeDocument(
            id: "custom",
            name: "Custom",
            background: "#FFFFFF",
            foreground: "#101010",
            cursor: "#336699",
            selectionBackground: "#DDDDDD",
            selectionForeground: "#101010",
            surface: "#EEEEEE",
            subtext: "#555555",
            accent: "#336699"
        )
        let theme = BrowserUITheme(document: document)

        XCTAssertFalse(theme.followsSystemAppearance)
        XCTAssertFalse(theme.isDark)
        XCTAssertEqual(theme.preferredColorScheme, .light)
        XCTAssertEqual(hex(NSColor(theme.background)), "#FFFFFF")
        XCTAssertEqual(hex(NSColor(theme.surface)), "#EEEEEE")
        XCTAssertEqual(hex(NSColor(theme.accent)), "#336699")
    }

    func testSystemThemeLeavesAppearanceToMacOS() {
        let document = TerminalThemeDocument(
            id: "system",
            name: "System",
            background: "#000000",
            foreground: "#FFFFFF",
            cursor: "#336699",
            selectionBackground: "#333333",
            selectionForeground: "#FFFFFF"
        )
        let theme = BrowserUITheme(document: document)

        XCTAssertTrue(theme.followsSystemAppearance)
        XCTAssertNil(theme.preferredColorScheme)
        XCTAssertNil(theme.windowAppearance)
    }

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

    private func hex(_ color: NSColor) -> String? {
        guard let color = color.usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
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

    func testFindMatchCountCountsRepeatedCaseInsensitiveMatches() {
        XCTAssertEqual(BrowserStore.countFindMatches(in: "WebKit finds webkit and WEBKIT.", query: "webkit"), 3)
        XCTAssertEqual(BrowserStore.countFindMatches(in: "No occurrence here.", query: "webkit"), 0)
        XCTAssertEqual(BrowserStore.countFindMatches(in: "Any text.", query: ""), 0)
    }

    func testChatGPTHandoffEncodesURLInPromptWithoutSubmitting() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://example.com/a?x=1&y=due"))
        let handoff = try XCTUnwrap(BrowserChatGPTHandoff.url(for: pageURL))
        let components = try XCTUnwrap(URLComponents(url: handoff, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "codex")
        XCTAssertEqual(components.host, "new")
        let prompt = try XCTUnwrap(components.queryItems?.first(where: { $0.name == "prompt" })?.value)
        XCTAssertTrue(prompt.contains(pageURL.absoluteString))
        XCTAssertTrue(prompt.contains("riassumi l’articolo in italiano"))
        XCTAssertNil(components.queryItems?.first(where: { $0.name == "submit" }))
        XCTAssertNil(BrowserChatGPTHandoff.url(for: URL(fileURLWithPath: "/tmp/page.html")))
    }

    func testIncomingExternalURLWaitsForUserChoice() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiBrowserExternal-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserStore(
            tabStore: BrowserTabStore(fileURL: directory.appendingPathComponent("tabs.json")),
            settingsStore: BrowserSettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            historyStore: BrowserHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        )
        let url = try XCTUnwrap(URL(string: "https://login.example/path"))

        store.receiveExternalURL(url)

        XCTAssertEqual(store.externalOpenRequest?.url, url)
        XCTAssertTrue(store.tabs.isEmpty)
        store.receiveExternalURL(URL(string: "mailto:user@example.com")!)
        XCTAssertEqual(store.externalOpenRequest?.url, url)
        store.stop()
    }

    func testExternalAppChoicesOrderByLastUseThenName() {
        let older = BrowserExternalApp(url: URL(fileURLWithPath: "/Applications/Safari.app"),
                                       name: "Safari",
                                       bundleIdentifier: "com.apple.Safari")
        let recent = BrowserExternalApp(url: URL(fileURLWithPath: "/Applications/Firefox.app"),
                                        name: "Firefox",
                                        bundleIdentifier: "org.mozilla.firefox")
        let unusedB = BrowserExternalApp(url: URL(fileURLWithPath: "/Applications/Zulu.app"),
                                         name: "Zulu",
                                         bundleIdentifier: "com.example.zulu")
        let unusedA = BrowserExternalApp(url: URL(fileURLWithPath: "/Applications/Arc.app"),
                                         name: "Arc",
                                         bundleIdentifier: "company.thebrowser.Browser")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let ordered = BrowserExternalAppOrdering.ordered(
            [older, unusedB, recent, unusedA],
            lastUsed: [
                older.usageKey: now.addingTimeInterval(-60),
                recent.usageKey: now
            ]
        )

        XCTAssertEqual(ordered.map(\.name), ["Firefox", "Safari", "Arc", "Zulu"])
    }

    func testExternalAppUsageIsBoundedAndPersistsAcrossSettingsReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiBrowserExternalAppUsage-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var usage = Dictionary(uniqueKeysWithValues: (0..<BrowserExternalAppOrdering.maximumRememberedApps)
            .map { index in
                ("com.example.\(index)", now.addingTimeInterval(-Double(index + 1)))
            })
        let app = BrowserExternalApp(url: URL(fileURLWithPath: "/Applications/New Browser.app"),
                                     name: "New Browser",
                                     bundleIdentifier: "com.example.new")
        BrowserExternalAppOrdering.recordUse(of: app, at: now, into: &usage)

        XCTAssertEqual(usage.count, BrowserExternalAppOrdering.maximumRememberedApps)
        XCTAssertEqual(usage[app.usageKey], now)
        XCTAssertNil(usage["com.example.79"])

        let settingsStore = BrowserSettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        XCTAssertTrue(settingsStore.save(BrowserSettings(externalAppLastUsed: usage)))
        XCTAssertEqual(settingsStore.load().externalAppLastUsed, usage)
    }

    func testPrivateTabsAreExcludedFromPersistedTabSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiBrowserPrivate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tabURL = directory.appendingPathComponent("tabs.json")
        let store = BrowserStore(
            tabStore: BrowserTabStore(fileURL: tabURL),
            settingsStore: BrowserSettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            historyStore: BrowserHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        )
        let saved = store.newTab(url: URL(string: "https://example.com")!, title: "Saved", select: false)
        let privateTab = store.newTab(url: URL(string: "https://private.example")!,
                                      title: "Private", select: false, isPrivate: true)
        store.selectedTabID = privateTab.id
        store.flush()

        let payload = BrowserTabStore(fileURL: tabURL).load()
        XCTAssertEqual(payload.tabs.map(\.id), [saved.id])
        XCTAssertEqual(payload.selectedTabID, saved.id)
        XCTAssertTrue(store.isPrivateTab(privateTab.id))
        store.stop()
    }

    func testWebInspectorSettingDefaultsOffForOlderSettingsFiles() throws {
        let data = Data(#"{"blockerEnabledByDefault":true,"disabledBlockerDomains":[],"summaryEnabled":true,"defaultPageURL":"https://www.google.com","searchEngine":"google","compactTabs":false}"#.utf8)
        let settings = try JSONDecoder().decode(BrowserSettings.self, from: data)
        XCTAssertFalse(settings.webInspectorEnabled)
        XCTAssertTrue(settings.externalAppLastUsed.isEmpty)

        var enabled = settings
        enabled.webInspectorEnabled = true
        let roundTrip = try JSONDecoder().decode(BrowserSettings.self,
                                                 from: JSONEncoder().encode(enabled))
        XCTAssertTrue(roundTrip.webInspectorEnabled)
    }

    func testWebInspectorCanBeOverriddenPerTab() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiBrowserInspector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserStore(
            tabStore: BrowserTabStore(fileURL: directory.appendingPathComponent("tabs.json")),
            settingsStore: BrowserSettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            historyStore: BrowserHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        )

        let first = store.newTab(url: URL(string: "https://one.example")!, title: "One")
        XCTAssertFalse(store.isWebInspectorEnabled(for: first.id))
        store.toggleWebInspectorForSelectedTab()
        XCTAssertTrue(store.isWebInspectorEnabled(for: first.id))
        XCTAssertTrue(store.selectedSession?.webView.isInspectable == true)

        let second = store.newTab(url: URL(string: "https://two.example")!, title: "Two")
        XCTAssertFalse(store.isWebInspectorEnabled(for: second.id))
        store.select(first.id)
        store.toggleWebInspectorForSelectedTab()
        XCTAssertFalse(store.isWebInspectorEnabled(for: first.id))
        XCTAssertFalse(store.selectedSession?.webView.isInspectable == true)

        var settings = store.settings
        settings.webInspectorEnabled = true
        store.updateSettings(settings)
        XCTAssertFalse(store.isWebInspectorEnabled(for: first.id))
        XCTAssertTrue(store.isWebInspectorEnabled(for: second.id))
        store.select(first.id)
        XCTAssertFalse(store.selectedSession?.webView.isInspectable == true)
        store.select(second.id)
        XCTAssertTrue(store.selectedSession?.webView.isInspectable == true)
        store.stop()
    }

    func testBackgroundNavigationDoesNotReplaceSelectedTabControls() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiBrowserNavigation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserStore(
            tabStore: BrowserTabStore(fileURL: directory.appendingPathComponent("tabs.json")),
            settingsStore: BrowserSettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            historyStore: BrowserHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        )
        let selected = BrowserTab(url: URL(string: "https://selected.example")!, title: "Selected")
        let background = BrowserTab(url: URL(string: "https://old.example")!, title: "Background")
        store.tabs = [selected, background]
        store.selectedTabID = selected.id
        store.loadingTabID = selected.id
        store.addressText = "https://selected.example"
        store.isAddressVisible = true
        store.canGoBack = true
        store.canGoForward = false

        store.sessionDidStart(tabID: background.id, url: background.url)
        let committedURL = try XCTUnwrap(URL(string: "https://background.example"))
        store.sessionDidCommit(tabID: background.id, url: committedURL)
        XCTAssertEqual(store.tabs.first(where: { $0.id == background.id })?.title,
                       committedURL.host)
        store.sessionDidFinish(tabID: background.id,
                              url: committedURL,
                              title: "Background finished",
                              canGoBack: false,
                              canGoForward: true)

        XCTAssertEqual(store.loadingTabID, selected.id)
        XCTAssertEqual(store.addressText, "https://selected.example")
        XCTAssertTrue(store.canGoBack)
        XCTAssertFalse(store.canGoForward)
        XCTAssertEqual(store.tabs.first(where: { $0.id == background.id })?.title, "Background finished")
        store.stop()
    }

    func testSameDocumentRouteUpdatesTabTitleAndClearsOldSiteIcon() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiBrowserRoute-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserStore(
            tabStore: BrowserTabStore(fileURL: directory.appendingPathComponent("tabs.json")),
            settingsStore: BrowserSettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            historyStore: BrowserHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        )
        let tab = BrowserTab(title: "Old page",
                             faviconURL: URL(string: "https://old.example/favicon.ico"),
                             faviconColor: BrowserColor(red: 1, green: 0, blue: 0))
        store.tabs = [tab]
        store.selectedTabID = tab.id
        let session = try XCTUnwrap(store.ensureSession(for: tab.id))
        store.tabs[0].url = try XCTUnwrap(URL(string: "https://old.example/article"))

        let route = try XCTUnwrap(URL(string: "https://new.example/story"))
        store.sessionDidObserve(session,
                                state: BrowserNavigationState(url: route,
                                                              title: "New story",
                                                              isLoading: false,
                                                              canGoBack: true,
                                                              canGoForward: false))

        XCTAssertEqual(store.tabs[0].url, route)
        XCTAssertEqual(store.tabs[0].title, "New story")
        XCTAssertNil(store.tabs[0].faviconURL)
        XCTAssertNil(store.tabs[0].faviconColor)
        XCTAssertTrue(store.canGoBack)
        XCTAssertFalse(store.canGoForward)
        store.stop()
    }

    func testNavigationFailuresIgnoreCancellationAndExposeErrorPageState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiBrowserErrors-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserStore(
            tabStore: BrowserTabStore(fileURL: directory.appendingPathComponent("tabs.json")),
            settingsStore: BrowserSettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            historyStore: BrowserHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        )
        let tab = BrowserTab()
        store.tabs = [tab]
        store.selectedTabID = tab.id
        let session = try XCTUnwrap(store.ensureSession(for: tab.id))

        store.sessionDidFail(session,
                             error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        XCTAssertNil(store.errorText)
        XCTAssertNil(store.selectedNavigationFailure)
        store.sessionDidFail(session,
                             error: NSError(domain: "BrowserTests", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "Could not load page"]))
        XCTAssertEqual(store.selectedNavigationFailure?.kind, .other)
        XCTAssertEqual(store.selectedNavigationFailure?.detail, "Could not load page")
        store.stop()
    }

    func testNewTabClearsPreviousNavigationControls() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiBrowserNewTabState-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserStore(
            tabStore: BrowserTabStore(fileURL: directory.appendingPathComponent("tabs.json")),
            settingsStore: BrowserSettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            historyStore: BrowserHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        )
        let previous = BrowserTab(title: "Previous")
        store.tabs = [previous]
        store.selectedTabID = previous.id
        _ = store.ensureSession(for: previous.id)
        store.loadingTabID = previous.id
        store.canGoBack = true
        store.canGoForward = true
        store.errorText = "Previous page failed"

        let newTab = store.newTab()

        XCTAssertEqual(store.selectedTabID, newTab.id)
        XCTAssertNil(store.loadingTabID)
        XCTAssertFalse(store.canGoBack)
        XCTAssertFalse(store.canGoForward)
        XCTAssertNil(store.errorText)
        store.stop()
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

    func testPinnedTabsCannotBeClosedAndCloseAllOldTabsPreservesThem() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiBrowserCloseOld-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let pinned = BrowserTab(title: "Pinned", lastUsed: now.addingTimeInterval(-100 * 3600), isPinned: true)
        let active = BrowserTab(title: "Active", lastUsed: now.addingTimeInterval(-3600))
        let old = BrowserTab(title: "Old", lastUsed: now.addingTimeInterval(-30 * 3600))
        let tabStore = BrowserTabStore(fileURL: directory.appendingPathComponent("tabs.json"))
        XCTAssertTrue(tabStore.save(BrowserTabsPayload(tabs: [pinned, active, old],
                                                       selectedTabID: old.id,
                                                       sidebarWidth: 264)))
        let store = BrowserStore(
            tabStore: tabStore,
            settingsStore: BrowserSettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            historyStore: BrowserHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        )

        store.close(pinned.id)
        XCTAssertTrue(store.tabs.contains(where: { $0.id == pinned.id }))
        store.closeAllOldTabs()

        XCTAssertEqual(Set(store.tabs.map(\.id)), Set([pinned.id, active.id]))
        XCTAssertTrue(store.pinnedTabs.contains(where: { $0.id == pinned.id }))
        XCTAssertTrue(store.oldTabs.isEmpty)
        store.stop()
    }

    func testAutomaticTickClosesExpiredTabsButKeepsPinnedTabs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiBrowserExpiryTick-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let active = BrowserTab(title: "Active", lastUsed: now)
        let becomesExpired = BrowserTab(title: "Old", lastUsed: now.addingTimeInterval(-30 * 3600))
        let pinned = BrowserTab(title: "Pinned", lastUsed: now.addingTimeInterval(-100 * 3600), isPinned: true)
        let tabStore = BrowserTabStore(fileURL: directory.appendingPathComponent("tabs.json"))
        XCTAssertTrue(tabStore.save(BrowserTabsPayload(tabs: [active, becomesExpired, pinned],
                                                       selectedTabID: becomesExpired.id,
                                                       sidebarWidth: 264)))
        let store = BrowserStore(
            tabStore: tabStore,
            settingsStore: BrowserSettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            historyStore: BrowserHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        )

        store.tick(now: now.addingTimeInterval(19 * 3600))

        XCTAssertFalse(store.tabs.contains(where: { $0.id == becomesExpired.id }))
        XCTAssertTrue(store.tabs.contains(where: { $0.id == active.id }))
        XCTAssertTrue(store.tabs.contains(where: { $0.id == pinned.id }))
        store.stop()
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
        XCTAssertTrue(store.addressRequiresNavigation)
        store.hideAddress()
        XCTAssertTrue(store.isAddressVisible)
        store.navigate("")
        XCTAssertTrue(store.isAddressVisible)
        store.navigate("https://example.org/start")
        XCTAssertFalse(store.isAddressVisible)
        store.stop()
    }

    func testCompactTabColumnMatchesToolbarButtonWidthAndRestoresSidebarWidth() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiBrowserCompactTabs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = BrowserStore(
            tabStore: BrowserTabStore(fileURL: directory.appendingPathComponent("tabs.json")),
            settingsStore: BrowserSettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            historyStore: BrowserHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        )
        store.sidebarWidth = 320

        store.toggleCompactTabs()
        XCTAssertTrue(store.settings.compactTabs)
        XCTAssertEqual(store.sidebarWidth, 97)
        store.stop()

        let reopenedStore = BrowserStore(
            tabStore: BrowserTabStore(fileURL: directory.appendingPathComponent("tabs.json")),
            settingsStore: BrowserSettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            historyStore: BrowserHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        )
        XCTAssertTrue(reopenedStore.settings.compactTabs)
        XCTAssertEqual(reopenedStore.sidebarWidth, 97)
        reopenedStore.toggleCompactTabs()
        XCTAssertFalse(reopenedStore.settings.compactTabs)
        XCTAssertEqual(reopenedStore.sidebarWidth, 320)
        reopenedStore.stop()
    }

    func testPerTabControlOverridesSurviveRestart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiBrowserTabControls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let tabStore = BrowserTabStore(fileURL: directory.appendingPathComponent("tabs.json"))
        let settingsStore = BrowserSettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        let historyStore = BrowserHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let store = BrowserStore(tabStore: tabStore,
                                 settingsStore: settingsStore,
                                 historyStore: historyStore)
        let tab = store.newTab(url: try XCTUnwrap(URL(string: "about:blank")))

        store.toggleBlockerForSelectedTab()
        store.toggleWebInspectorForSelectedTab()
        store.stop()

        let reopenedStore = BrowserStore(tabStore: tabStore,
                                         settingsStore: settingsStore,
                                         historyStore: historyStore)
        let restoredTab = try XCTUnwrap(reopenedStore.tabs.first(where: { $0.id == tab.id }))
        XCTAssertFalse(reopenedStore.isBlockerEnabled(for: restoredTab))
        XCTAssertTrue(reopenedStore.isWebInspectorEnabled(for: tab.id))
        reopenedStore.stop()
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
        XCTAssertEqual(store.addressSuggestions.map(\.title), [
            "Example A",
            "Search Google for “example”",
        ])
    }

    func testOmniboxCombinesLocalHistoryOpenTabsVisitAndSearch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiBrowserOmnibox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserStore(
            tabStore: BrowserTabStore(fileURL: directory.appendingPathComponent("tabs.json")),
            settingsStore: BrowserSettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            historyStore: BrowserHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        )
        store.settings.searchEngine = .duckDuckGo
        let selected = BrowserTab(url: URL(string: "https://current.example")!, title: "Current")
        let openTab = BrowserTab(url: URL(string: "https://example.com/dashboard")!, title: "Example dashboard")
        store.tabs = [selected, openTab]
        store.selectedTabID = selected.id
        store.history = [
            BrowserHistoryEntry(url: URL(string: "https://example.com/guide")!,
                                title: "Example guide",
                                lastVisited: Date()),
        ]
        store.addressText = "example.com"

        let suggestions = store.addressSuggestions
        XCTAssertTrue(suggestions.contains(.history(store.history[0])))
        XCTAssertTrue(suggestions.contains(.openTab(openTab)))
        XCTAssertTrue(suggestions.contains(.visit(URL(string: "https://example.com")!)))
        XCTAssertTrue(suggestions.contains(.search(query: "example.com", engine: .duckDuckGo)))

        store.moveAddressSelection(by: 1)
        XCTAssertEqual(store.addressSelectionIndex, 0)
        store.moveAddressSelection(by: 1)
        XCTAssertEqual(store.addressSelectionIndex, 1)
        for _ in 0..<suggestions.count { store.moveAddressSelection(by: 1) }
        XCTAssertEqual(store.addressSelectionIndex, 1)
        store.stop()
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

    func testBlockerToggleRecreatesSelectedSessionWithoutChangingTab() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiBrowserBlockerToggle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = BrowserStore(
            tabStore: BrowserTabStore(fileURL: directory.appendingPathComponent("tabs.json")),
            settingsStore: BrowserSettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            historyStore: BrowserHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        )
        let url = try XCTUnwrap(URL(string: "https://blocker-toggle.example/path"))
        let tab = BrowserTab(url: url, title: "Blocker test")
        store.tabs = [tab]
        store.selectedTabID = tab.id
        await store.start()
        let originalSession = try XCTUnwrap(store.selectedSession)

        store.toggleBlockerForSelectedDomain()

        let replacementSession = try XCTUnwrap(store.selectedSession)
        XCTAssertFalse(originalSession === replacementSession)
        XCTAssertEqual(replacementSession.tabID, tab.id)
        XCTAssertEqual(store.selectedTab?.url, url)
        XCTAssertFalse(store.isBlockerEnabled(for: tab))
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
