import AppKit
import Foundation
import Observation
import WebKit

/// The browser model and the owner of its live WebKit objects.
///
/// The value model (`tabs`) is observable and persisted; the sessions, timer,
/// observers and caches are implementation details and stay off the observable
/// surface. Every asynchronous callback is validated against the current tab
/// and URL before it can publish.
@Observable
@MainActor
final class BrowserStore {
    var tabs: [BrowserTab]
    var selectedTabID: UUID?
    var settings: BrowserSettings
    var sidebarWidth: Double {
        didSet { scheduleSave() }
    }
    var now: Date
    var isAddressVisible = false
    var addressText = ""
    var addressFocusToken = UUID()
    var isSettingsVisible = false
    var isCredentialsVisible = false
    var addressSelectionIndex = -1
    var summary: BrowserSummaryState = .idle
    var summaryTabID: UUID?
    var errorText: String?
    var loadingTabID: UUID?
    var canGoBack = false
    var canGoForward = false
    var isStarted = false
    var sessionRevision = 0
    var history: [BrowserHistoryEntry] = []

    @ObservationIgnored private let tabStore: BrowserTabStore
    @ObservationIgnored private let settingsStore: BrowserSettingsStore
    @ObservationIgnored private let historyStore: BrowserHistoryStore
    @ObservationIgnored private let credentialStore = BrowserCredentialStore()
    @ObservationIgnored private var expandedSidebarWidth: Double = 264
    @ObservationIgnored private let blocker = BrowserAdBlocker()
    @ObservationIgnored private let faviconProvider = BrowserFaviconProvider()
    @ObservationIgnored private let summaryController = BrowserSummaryController()

    @ObservationIgnored private(set) var blockerList: WKContentRuleList?
    @ObservationIgnored private var blockerReady = false
    @ObservationIgnored private var sessions: [UUID: BrowserTabSession] = [:]
    @ObservationIgnored private var faviconImages: [UUID: Data] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var clockObserver: NSObjectProtocol?
    @ObservationIgnored private var saveWorkItem: DispatchWorkItem?
    @ObservationIgnored private var lastActivityWrite: [UUID: Date] = [:]
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var rebuilding: Set<UUID> = []

    init(tabStore: BrowserTabStore = BrowserTabStore(),
         settingsStore: BrowserSettingsStore = BrowserSettingsStore(),
         historyStore: BrowserHistoryStore = BrowserHistoryStore()) {
        self.tabStore = tabStore
        self.settingsStore = settingsStore
        self.historyStore = historyStore
        let payload = tabStore.load()
        tabs = payload.tabs
        selectedTabID = payload.selectedTabID
        sidebarWidth = payload.sidebarWidth
        settings = settingsStore.load()
        if payload.sidebarWidth > 120 { expandedSidebarWidth = payload.sidebarWidth }
        history = historyStore.load()
        now = Date()
    }

    // MARK: - Lifecycle

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        blockerList = await blocker.prepare()
        guard !stopped else { return }
        blockerReady = true

        if tabs.isEmpty {
            let tab = BrowserTab(title: "New Tab")
            tabs = [tab]
            selectedTabID = tab.id
            isAddressVisible = true
            addressText = settings.defaultPageURL
            addressSelectionIndex = -1
        } else if let selectedTabID,
                  tabs.contains(where: { $0.id == selectedTabID }) == false {
            self.selectedTabID = orderedTabs.first?.id
        }
        if selectedTabID == nil {
            selectedTabID = orderedTabs.first?.id
        }

        isStarted = true
        installClock()
        if let selectedTabID {
            _ = ensureSession(for: selectedTabID)
        }
        scheduleSave()
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let clockObserver {
            NotificationCenter.default.removeObserver(clockObserver)
            self.clockObserver = nil
        }
        summaryController.cancel()
        for session in sessions.values { session.stop() }
        sessions.removeAll()
        flush()
    }

    // MARK: - Derived state

    var orderedTabs: [BrowserTab] {
        BrowserTabLifecycle.ordered(tabs, now: now)
    }

    var pinnedTabs: [BrowserTab] {
        orderedTabs.filter { $0.isPinned }
    }

    var activeTabs: [BrowserTab] {
        orderedTabs.filter { !$0.isPinned && BrowserTabLifecycle.phase(for: $0, now: now) == .active }
    }

    var oldTabs: [BrowserTab] {
        orderedTabs.filter { !$0.isPinned && BrowserTabLifecycle.phase(for: $0, now: now) == .old }
    }

    var selectedTab: BrowserTab? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    var selectedSession: BrowserTabSession? {
        guard let selectedTabID else { return nil }
        return sessions[selectedTabID]
    }

    var isLoading: Bool {
        selectedTabID != nil && loadingTabID == selectedTabID
    }

    var windowTitle: String {
        guard let tab = selectedTab else { return "MakiBrowser" }
        if let url = tab.url {
            return "\(tab.displayTitle) — \(url.absoluteString)"
        }
        return tab.displayTitle
    }

    var windowSubtitle: String {
        selectedTab?.url?.host ?? ""
    }

    var addressSuggestions: [BrowserHistoryEntry] {
        let query = addressText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        return history.filter { entry in
            entry.url.absoluteString.lowercased().contains(query)
                || entry.title.lowercased().contains(query)
        }
        .prefix(6)
        .map { $0 }
    }

    func isBlockerEnabled(for tab: BrowserTab) -> Bool {
        BrowserBlockerPolicy.isEnabled(settings: settings,
                                       tab: tab,
                                       domain: tab.url.flatMap(BrowserDomain.registrableDomain))
    }

    func faviconImage(for tab: BrowserTab) -> NSImage? {
        guard let data = faviconImages[tab.id] else { return nil }
        return NSImage(data: data)
    }

    func fallbackColor(for tab: BrowserTab) -> BrowserColor {
        if let color = tab.faviconColor { return color }
        return BrowserColor.fallback(for: tab.url.flatMap(BrowserDomain.registrableDomain) ?? "new-tab")
    }

    // MARK: - Tab commands

    @discardableResult
    func newTab(url: URL? = nil, title: String = "New Tab", select: Bool = true) -> BrowserTab {
        let tab = BrowserTab(url: url, title: title)
        tabs.append(tab)
        if select {
            selectedTabID = tab.id
            isAddressVisible = true
            addressText = settings.defaultPageURL
            addressFocusToken = UUID()
            addressSelectionIndex = -1
            ensureSession(for: tab.id)
        }
        scheduleSave()
        return tab
    }

    func select(_ tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        guard selectedTabID != tabID else { return }
        selectedTabID = tabID
        isAddressVisible = false
        addressSelectionIndex = -1
        touch(tabID, force: true)
        summaryController.cancel()
        summary = .idle
        summaryTabID = nil
        _ = ensureSession(for: tabID)
        scheduleSave()
    }

    func close(_ tabID: UUID) {
        sessions[tabID]?.stop()
        sessions.removeValue(forKey: tabID)
        faviconImages.removeValue(forKey: tabID)
        lastActivityWrite.removeValue(forKey: tabID)
        tabs.removeAll { $0.id == tabID }
        if summaryTabID == tabID {
            summaryController.cancel()
            summary = .idle
            summaryTabID = nil
        }

        if selectedTabID == tabID {
            selectedTabID = orderedTabs.first?.id
            if let selectedTabID { _ = ensureSession(for: selectedTabID) }
        }
        if tabs.isEmpty {
            let tab = BrowserTab(title: "New Tab")
            tabs = [tab]
            selectedTabID = tab.id
            ensureSession(for: tab.id)
        }
        scheduleSave()
    }

    func closeSelected() {
        guard let selectedTabID else { return }
        close(selectedTabID)
    }

    func togglePin(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].isPinned.toggle()
        scheduleSave()
    }

    func touch(_ tabID: UUID, force: Bool = false) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let current = Date()
        if !force, let last = lastActivityWrite[tabID], current.timeIntervalSince(last) < 60 {
            return
        }
        lastActivityWrite[tabID] = current
        tabs[index].lastUsed = current
        now = current
        scheduleSave()
    }

    func tick(now value: Date = Date()) {
        now = value
        let expired = tabs.filter { BrowserTabLifecycle.isExpired($0, now: value) }
        guard !expired.isEmpty else { return }
        let expiredIDs = Set(expired.map(\.id))
        for id in expiredIDs {
            sessions[id]?.stop()
            sessions.removeValue(forKey: id)
            faviconImages.removeValue(forKey: id)
        }
        tabs.removeAll { expiredIDs.contains($0.id) }
        if let selectedTabID, expiredIDs.contains(selectedTabID) {
            self.selectedTabID = orderedTabs.first?.id
            if let selected = self.selectedTabID { _ = ensureSession(for: selected) }
        }
        if tabs.isEmpty {
            let tab = BrowserTab(title: "New Tab")
            tabs = [tab]
            selectedTabID = tab.id
            ensureSession(for: tab.id)
        }
        scheduleSave()
    }

    // MARK: - Navigation

    func navigate(_ raw: String) {
        guard let url = BrowserURLInput.url(from: raw,
                                             searchEngine: settings.searchEngine) else { return }
        navigate(to: url)
    }

    func navigate(to url: URL) {
        summaryController.cancel()
        summary = .idle
        summaryTabID = nil
        if let selectedTabID, let session = sessions[selectedTabID] {
            session.load(url)
            touch(selectedTabID, force: true)
        } else {
            _ = newTab(url: url, title: url.host ?? url.absoluteString)
        }
        isAddressVisible = false
        scheduleSave()
    }

    func goBack() {
        selectedSession?.webView.goBack()
    }

    func goForward() {
        selectedSession?.webView.goForward()
    }

    func reload() {
        selectedSession?.webView.reload()
    }

    func stopLoading() {
        selectedSession?.webView.stopLoading()
    }

    func showAddress() {
        addressText = selectedTab?.url?.absoluteString ?? settings.defaultPageURL
        isAddressVisible = true
        addressFocusToken = UUID()
        addressSelectionIndex = -1
    }

    func hideAddress() {
        isAddressVisible = false
        addressSelectionIndex = -1
    }

    func resetAddressSelection() {
        addressSelectionIndex = -1
    }

    func moveAddressSelection(by delta: Int) {
        let count = addressSuggestions.count
        guard count > 0 else { return }
        if addressSelectionIndex < 0 {
            addressSelectionIndex = delta > 0 ? 0 : count - 1
        } else {
            addressSelectionIndex = (addressSelectionIndex + delta + count) % count
        }
    }

    @discardableResult
    func acceptAddressSelection() -> Bool {
        let suggestions = addressSuggestions
        guard addressSelectionIndex >= 0,
              suggestions.indices.contains(addressSelectionIndex) else { return false }
        navigate(to: suggestions[addressSelectionIndex].url)
        return true
    }

    func toggleCompactTabs() {
        if settings.compactTabs {
            settings.compactTabs = false
            sidebarWidth = max(240, expandedSidebarWidth)
        } else {
            expandedSidebarWidth = max(sidebarWidth, 240)
            settings.compactTabs = true
            sidebarWidth = 96
        }
        settingsStore.save(settings)
    }

    // MARK: - Credentials

    func credentialsForCurrentDomain() -> [BrowserCredential] {
        guard let domain = selectedTab?.url.flatMap(BrowserDomain.registrableDomain) else { return [] }
        return credentialStore.credentials(for: domain)
    }

    func saveCredential(username: String, password: String) {
        guard let domain = selectedTab?.url.flatMap(BrowserDomain.registrableDomain),
              !username.isEmpty, !password.isEmpty else { return }
        credentialStore.save(domain: domain, username: username, password: password)
    }

    func deleteCredential(_ credential: BrowserCredential) {
        credentialStore.delete(credential)
    }

    func fillCredential(_ credential: BrowserCredential) {
        guard let session = selectedSession else { return }
        Task { @MainActor in
            _ = await BrowserCredentialStore.fill(credential,
                                                  in: session.webView)
        }
    }

    // MARK: - Blocker

    func toggleBlockerForSelectedDomain() {
        guard let tab = selectedTab,
              let domain = tab.url.flatMap(BrowserDomain.registrableDomain) else { return }
        if settings.disabledBlockerDomains.contains(domain) {
            settings.disabledBlockerDomains.remove(domain)
        } else {
            settings.disabledBlockerDomains.insert(domain)
        }
        settingsStore.save(settings)
        rebuildTabs(for: domain)
    }

    func toggleBlockerForSelectedTab() {
        guard let tab = selectedTab else { return }
        let enabled = isBlockerEnabled(for: tab)
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs[index].blockerOverride = !enabled
        rebuild(tab.id)
    }

    func updateSettings(_ newSettings: BrowserSettings) {
        let blockerChanged = settings.blockerEnabledByDefault != newSettings.blockerEnabledByDefault
        settings = newSettings
        settingsStore.save(settings)
        if newSettings.summaryEnabled == false {
            summaryController.cancel()
            summary = .idle
            summaryTabID = nil
        }
        if blockerChanged {
            for tab in tabs { rebuild(tab.id) }
        }
    }

    func setSummaryEnabled(_ enabled: Bool) {
        settings.summaryEnabled = enabled
        if !enabled {
            summaryController.cancel()
            summary = .idle
            summaryTabID = nil
        }
        settingsStore.save(settings)
    }

    private func rebuildTabs(for domain: String) {
        let affected = tabs.filter {
            $0.url.flatMap(BrowserDomain.registrableDomain) == domain
        }
        for tab in affected { rebuild(tab.id) }
    }

    private func rebuild(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let url = tabs[index].url
        rebuilding.insert(tabID)
        sessions[tabID]?.stop()
        sessions.removeValue(forKey: tabID)
        sessionRevision &+= 1
        if selectedTabID == tabID {
            _ = ensureSession(for: tabID)
            if let url { sessions[tabID]?.load(url) }
        }
        rebuilding.remove(tabID)
        scheduleSave()
    }

    // MARK: - Summary

    func requestSummary() {
        guard settings.summaryEnabled,
              let selectedTabID,
              let session = sessions[selectedTabID] else { return }
        summaryTabID = selectedTabID
        summary = .extracting
        summaryController.summarize(webView: session.webView) { [weak self] state in
            guard let self, self.summaryTabID == selectedTabID else { return }
            self.summary = state
        }
    }

    func cancelSummary() {
        summaryController.cancel()
        summary = .idle
        summaryTabID = nil
    }

    // MARK: - Session callbacks

    func sessionDidStart(tabID: UUID, url: URL?) {
        loadingTabID = tabID
        errorText = nil
        if summaryTabID == tabID {
            summaryController.cancel()
            summary = .idle
            summaryTabID = nil
        }
        touch(tabID, force: true)
    }

    func sessionDidCommit(tabID: UUID, url: URL?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let oldDomain = tabs[index].url.flatMap(BrowserDomain.registrableDomain)
        let newDomain = url.flatMap(BrowserDomain.registrableDomain)
        let oldEnabled = BrowserBlockerPolicy.isEnabled(settings: settings,
                                                        tab: tabs[index],
                                                        domain: oldDomain)
        tabs[index].url = url
        if oldDomain != newDomain {
            tabs[index].blockerOverride = nil
        }
        if isAddressVisible { addressText = url?.absoluteString ?? "" }
        let newEnabled = BrowserBlockerPolicy.isEnabled(settings: settings,
                                                        tab: tabs[index],
                                                        domain: newDomain)
        canGoBack = sessions[tabID]?.webView.canGoBack ?? false
        canGoForward = sessions[tabID]?.webView.canGoForward ?? false
        scheduleSave()
        if oldEnabled != newEnabled, !rebuilding.contains(tabID) {
            rebuild(tabID)
        }
    }

    func sessionDidFinish(tabID: UUID,
                          url: URL?,
                          title: String?,
                          canGoBack: Bool,
                          canGoForward: Bool) {
        loadingTabID = nil
        if let index = tabs.firstIndex(where: { $0.id == tabID }) {
            if let url { tabs[index].url = url }
            let resolved = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            tabs[index].title = resolved.isEmpty
                ? (url?.host ?? "New Tab")
                : resolved
            tabs[index].lastUsed = Date()
            now = tabs[index].lastUsed
            recordHistory(url: url ?? tabs[index].url, title: tabs[index].title)
        }
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        scheduleSave()
        loadFavicon(tabID: tabID)
    }

    func sessionDidFail(tabID: UUID, message: String) {
        loadingTabID = nil
        if selectedTabID == tabID {
            errorText = message
        }
    }

    func sessionDidTerminate(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let url = tabs[index].url
        sessions[tabID]?.stop()
        sessions.removeValue(forKey: tabID)
        sessionRevision &+= 1
        if selectedTabID == tabID {
            _ = ensureSession(for: tabID)
            if let url { sessions[tabID]?.load(url) }
        }
        errorText = "The page stopped responding and was reloaded."
    }

    func sessionDidRequestNewTab(url: URL) {
        newTab(url: url, title: url.host ?? "New Tab", select: true)
    }

    private func recordHistory(url: URL?, title: String) {
        guard let url, url.scheme?.hasPrefix("http") == true else { return }
        history.removeAll { $0.url == url }
        history.insert(BrowserHistoryEntry(url: url, title: title, lastVisited: Date()), at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        historyStore.save(history)
    }

    // MARK: - Session creation

    @discardableResult
    func ensureSession(for tabID: UUID) -> BrowserTabSession? {
        if let existing = sessions[tabID] { return existing }
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return nil }
        let configuration = makeConfiguration(for: tab)
        let session = BrowserTabSession(tabID: tabID,
                                        configuration: configuration,
                                        store: self)
        sessions[tabID] = session
        if let url = tab.url {
            session.load(url)
        }
        sessionRevision &+= 1
        return session
    }

    private func makeConfiguration(for tab: BrowserTab) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.applicationNameForUserAgent = "MakiDesk/\(BrowserVersion.string)"
        if blockerReady,
           let blockerList,
           BrowserBlockerPolicy.isEnabled(settings: settings,
                                          tab: tab,
                                          domain: tab.url.flatMap(BrowserDomain.registrableDomain)) {
            configuration.userContentController.add(blockerList)
        }
        return configuration
    }

    // MARK: - Favicon

    private func loadFavicon(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              let pageURL = tabs[index].url,
              pageURL.scheme?.hasPrefix("http") == true else { return }
        let expectedURL = pageURL
        let session = sessions[tabID]
        let script = #"""
        (() => {
          const links = [...document.querySelectorAll(
            'link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="mask-icon"]'
          )];
          const score = link => {
            const sizes = (link.getAttribute('sizes') || '').split('x').map(Number);
            return (sizes[0] || 0) * (sizes[1] || 0);
          };
          links.sort((a, b) => score(b) - score(a));
          return links[0]?.href || new URL('/favicon.ico', location.href).href;
        })()
        """#
        Task { @MainActor [weak self] in
            guard let self, let session else { return }
            let value = try? await session.webView.evaluateJavaScript(script)
            guard let href = value as? String else { return }
            guard let iconURL = URL(string: href, relativeTo: expectedURL)?.absoluteURL else { return }
            guard self.tabs.first(where: { $0.id == tabID })?.url == expectedURL else { return }
            guard let favicon = await self.faviconProvider.favicon(at: iconURL) else { return }
            guard let index = self.tabs.firstIndex(where: { $0.id == tabID }),
                  self.tabs[index].url == expectedURL else { return }
            self.tabs[index].faviconURL = iconURL
            self.tabs[index].faviconColor = favicon.color
            self.faviconImages[tabID] = favicon.data
            self.scheduleSave()
        }
    }

    // MARK: - Clock and persistence

    private func installClock() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick(now: Date()) }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick(now: Date()) }
        }
        clockObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick(now: Date()) }
        }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        let payload = BrowserTabsPayload(tabs: tabs,
                                         selectedTabID: selectedTabID,
                                         sidebarWidth: sidebarWidth)
        _ = tabStore.save(payload)
    }
}

private enum BrowserVersion {
    static var string: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
