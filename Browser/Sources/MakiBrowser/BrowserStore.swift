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
        didSet {
            if settings.compactTabs == false, sidebarWidth > 120 {
                expandedSidebarWidth = sidebarWidth
            }
            scheduleSave()
        }
    }
    var now: Date
    var isAddressVisible = false
    var isFindVisible = false
    var findText = ""
    var findMatchFound: Bool?
    var findMatchCount: Int?
    var isFindSearching = false
    var noticeText: String?
    var addressText = ""
    var addressFocusToken = UUID()
    var isSettingsVisible = false
    var addressSelectionIndex = -1
    var summary: BrowserSummaryState = .idle
    var summaryTabID: UUID?
    var errorText: String?
    var loadingTabID: UUID?
    var canGoBack = false
    var canGoForward = false
    var isStarted = false
    var addressRequiresNavigation: Bool { selectedTab?.url == nil }
    var sessionRevision = 0
    var history: [BrowserHistoryEntry] = []
    var externalOpenRequest: BrowserExternalOpenRequest?
    var siteDataConfirmationTabID: UUID?
    var siteDataConfirmationHost: String? {
        siteDataConfirmationTabID.flatMap { id in tabs.first(where: { $0.id == id })?.url?.host }
    }
    var isReaderVisible = false
    var readerPage: BrowserPageText?
    var readerError: String?
    var readerTextSize = 17.0

    @ObservationIgnored private let tabStore: BrowserTabStore
    @ObservationIgnored private let settingsStore: BrowserSettingsStore
    @ObservationIgnored private let historyStore: BrowserHistoryStore
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
    @ObservationIgnored private var provisionalNavigations: Set<UUID> = []
    @ObservationIgnored private var queuedExternalURLs: [URL] = []
    @ObservationIgnored private var privateTabIDs: Set<UUID> = []
    @ObservationIgnored private var readerTask: Task<Void, Never>?
    @ObservationIgnored private var readerGeneration = UUID()
    @ObservationIgnored private var findTask: Task<Void, Never>?
    @ObservationIgnored private var findGeneration = UUID()
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    struct ExternalApp: Identifiable, Equatable {
        let url: URL
        let name: String
        let bundleIdentifier: String?
        var id: String { url.standardizedFileURL.path }
    }

    struct BrowserExternalOpenRequest: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let apps: [ExternalApp]
    }

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
        expandedSidebarWidth = payload.expandedSidebarWidth
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
        readerTask?.cancel()
        readerTask = nil
        invalidateFind()
        noticeTask?.cancel()
        noticeTask = nil
        for session in sessions.values { session.stop() }
        sessions.removeAll()
        flush()
    }

    func receiveExternalURL(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        guard externalOpenRequest == nil else {
            queuedExternalURLs.append(url)
            return
        }
        presentExternalURL(url)
    }

    func finishExternalOpenRequest() {
        guard externalOpenRequest == nil, !queuedExternalURLs.isEmpty else { return }
        presentExternalURL(queuedExternalURLs.removeFirst())
    }

    func openExternalURLInBrowser() {
        guard let url = externalOpenRequest?.url, isStarted else { return }
        _ = newTab(url: url, title: url.host ?? url.absoluteString)
        isAddressVisible = false
        externalOpenRequest = nil
    }

    func openExternalURL(in app: ExternalApp) {
        guard let request = externalOpenRequest else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([request.url], withApplicationAt: app.url,
                                configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.errorText = "Could not open link in \(app.name): \(error.localizedDescription)"
            }
        }
        externalOpenRequest = nil
    }

    func requestAsDefaultBrowser() async throws {
        let appURL = Bundle.main.bundleURL
        try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "http")
        try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "https")
    }

    private func presentExternalURL(_ url: URL) {
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url).compactMap { appURL -> ExternalApp? in
            let bundle = Bundle(url: appURL)
            guard appURL.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL,
                  bundle?.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
            return ExternalApp(url: appURL,
                               name: bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                                   ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                                   ?? appURL.deletingPathExtension().lastPathComponent,
                               bundleIdentifier: bundle?.bundleIdentifier)
        }
        externalOpenRequest = BrowserExternalOpenRequest(url: url, apps: apps)
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

    private func refreshSelectedNavigationState() {
        guard let selectedTabID,
              let session = sessions[selectedTabID] else {
            loadingTabID = nil
            canGoBack = false
            canGoForward = false
            errorText = nil
            return
        }
        loadingTabID = session.webView.isLoading ? selectedTabID : nil
        canGoBack = session.webView.canGoBack
        canGoForward = session.webView.canGoForward
        errorText = nil
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

    var addressSuggestions: [BrowserAddressSuggestion] {
        let normalized = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = normalized.lowercased()
        guard !query.isEmpty else { return [] }
        let openTabs = tabs.filter { $0.id != selectedTabID && $0.url != nil }.filter { tab in
            tab.displayTitle.lowercased().contains(query)
                || (tab.url?.absoluteString.lowercased().contains(query) ?? false)
        }
        let openURLs = Set(openTabs.compactMap { $0.url?.absoluteString })
        let historyMatches = history.filter { entry in
            entry.url.absoluteString.lowercased().contains(query)
                || entry.title.lowercased().contains(query)
        }
        .filter { !openURLs.contains($0.url.absoluteString) }
        .prefix(4)
        .map(BrowserAddressSuggestion.history)

        let tabMatches = openTabs.prefix(3).map(BrowserAddressSuggestion.openTab)
        var results = historyMatches + tabMatches
        if BrowserURLInput.looksLikeAddress(normalized),
           let url = BrowserURLInput.url(from: normalized, searchEngine: settings.searchEngine),
           selectedTab?.url != url,
           history.contains(where: { $0.url == url }) == false,
           openTabs.contains(where: { $0.url == url }) == false {
            results.append(.visit(url))
        }
        results.append(.search(query: normalized, engine: settings.searchEngine))
        return results
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
    func newTab(url: URL? = nil,
                title: String = "New Tab",
                select: Bool = true,
                isPrivate: Bool = false) -> BrowserTab {
        let tab = BrowserTab(url: url, title: title)
        tabs.append(tab)
        if isPrivate { privateTabIDs.insert(tab.id) }
        if select {
            if isFindVisible { hideFind() }
            cancelSummary()
            closeReaderMode()
            selectedTabID = tab.id
            isAddressVisible = true
            addressText = settings.defaultPageURL
            addressFocusToken = UUID()
            addressSelectionIndex = -1
            ensureSession(for: tab.id)
            refreshSelectedNavigationState()
        }
        scheduleSave()
        return tab
    }

    func newPrivateTab() {
        _ = newTab(title: "Private Tab", isPrivate: true)
    }

    func isPrivateTab(_ tabID: UUID) -> Bool {
        privateTabIDs.contains(tabID)
    }

    func select(_ tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        guard selectedTabID != tabID else { return }
        if isFindVisible { hideFind() }
        selectedTabID = tabID
        isAddressVisible = false
        closeReaderMode()
        addressSelectionIndex = -1
        touch(tabID, force: true)
        summaryController.cancel()
        summary = .idle
        summaryTabID = nil
        _ = ensureSession(for: tabID)
        refreshSelectedNavigationState()
        scheduleSave()
    }

    func close(_ tabID: UUID) {
        if selectedTabID == tabID, isFindVisible { hideFind() }
        if selectedTabID == tabID { closeReaderMode() }
        sessions[tabID]?.stop()
        sessions.removeValue(forKey: tabID)
        faviconImages.removeValue(forKey: tabID)
        provisionalNavigations.remove(tabID)
        lastActivityWrite.removeValue(forKey: tabID)
        tabs.removeAll { $0.id == tabID }
        privateTabIDs.remove(tabID)
        if summaryTabID == tabID {
            summaryController.cancel()
            summary = .idle
            summaryTabID = nil
        }

        if selectedTabID == tabID {
            selectedTabID = orderedTabs.first?.id
            if let selectedTabID { _ = ensureSession(for: selectedTabID) }
            refreshSelectedNavigationState()
        }
        if tabs.isEmpty {
            let tab = BrowserTab(title: "New Tab")
            tabs = [tab]
            selectedTabID = tab.id
            isAddressVisible = true
            addressText = settings.defaultPageURL
            addressFocusToken = UUID()
            ensureSession(for: tab.id)
            refreshSelectedNavigationState()
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
            provisionalNavigations.remove(id)
            privateTabIDs.remove(id)
        }
        if let summaryTabID, expiredIDs.contains(summaryTabID) {
            cancelSummary()
        }
        tabs.removeAll { expiredIDs.contains($0.id) }
        if let selectedTabID, expiredIDs.contains(selectedTabID) {
            self.selectedTabID = orderedTabs.first?.id
            if let selected = self.selectedTabID { _ = ensureSession(for: selected) }
            refreshSelectedNavigationState()
        }
        if tabs.isEmpty {
            let tab = BrowserTab(title: "New Tab")
            tabs = [tab]
            selectedTabID = tab.id
            ensureSession(for: tab.id)
            refreshSelectedNavigationState()
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
        closeReaderMode()
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
        if isFindVisible {
            isFindVisible = false
            invalidateFind()
        }
        addressText = selectedTab?.url?.absoluteString ?? settings.defaultPageURL
        isAddressVisible = true
        addressFocusToken = UUID()
        addressSelectionIndex = -1
    }

    func hideAddress() {
        guard !addressRequiresNavigation else {
            isAddressVisible = true
            return
        }
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
        acceptAddressSuggestion(suggestions[addressSelectionIndex])
        return true
    }

    func acceptAddressSelectionInNewTab() -> Bool {
        let suggestions = addressSuggestions
        guard addressSelectionIndex >= 0,
              suggestions.indices.contains(addressSelectionIndex) else { return false }
        acceptAddressSuggestion(suggestions[addressSelectionIndex], inNewTab: true)
        return true
    }

    func acceptAddressSuggestion(at index: Int) {
        let suggestions = addressSuggestions
        guard suggestions.indices.contains(index) else { return }
        acceptAddressSuggestion(suggestions[index])
    }

    func navigateInNewTab(_ raw: String) {
        guard let url = BrowserURLInput.url(from: raw, searchEngine: settings.searchEngine) else { return }
        navigateInNewTab(to: url)
    }

    private func acceptAddressSuggestion(_ suggestion: BrowserAddressSuggestion,
                                         inNewTab: Bool = false) {
        switch suggestion {
        case .history(let entry):
            inNewTab ? navigateInNewTab(to: entry.url) : navigate(to: entry.url)
        case .openTab(let tab):
            if inNewTab, let url = tab.url {
                navigateInNewTab(to: url)
            } else {
                select(tab.id)
                hideAddress()
            }
        case .visit(let url):
            inNewTab ? navigateInNewTab(to: url) : navigate(to: url)
        case .search(let query, let engine):
            guard let url = engine.searchURL(for: query) else { return }
            inNewTab ? navigateInNewTab(to: url) : navigate(to: url)
        }
    }

    private func navigateInNewTab(to url: URL) {
        _ = newTab(url: url, title: url.host ?? url.absoluteString)
        isAddressVisible = false
        addressText = url.absoluteString
        addressSelectionIndex = -1
        scheduleSave()
    }

    func toggleCompactTabs() {
        if settings.compactTabs {
            settings.compactTabs = false
            sidebarWidth = max(240, expandedSidebarWidth)
        } else {
            expandedSidebarWidth = max(sidebarWidth, 240)
            settings.compactTabs = true
            sidebarWidth = 97
        }
        settingsStore.save(settings)
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
        let inspectorChanged = settings.webInspectorEnabled != newSettings.webInspectorEnabled
        settings = newSettings
        settingsStore.save(settings)
        if inspectorChanged {
            for session in sessions.values {
                session.webView.isInspectable = isWebInspectorEnabled(for: session.tabID)
            }
        }
        if newSettings.summaryEnabled == false {
            summaryController.cancel()
            summary = .idle
            summaryTabID = nil
        }
        if blockerChanged {
            for tab in tabs { rebuild(tab.id) }
        }
    }

    func isWebInspectorEnabled(for tabID: UUID) -> Bool {
        tabs.first(where: { $0.id == tabID })?.webInspectorOverride ?? settings.webInspectorEnabled
    }

    func toggleWebInspectorForSelectedTab() {
        guard let tabID = selectedTabID,
              selectedTab?.url != nil,
              let session = sessions[tabID] else { return }
        let enabled = !isWebInspectorEnabled(for: tabID)
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].webInspectorOverride = enabled
        session.webView.isInspectable = enabled
        scheduleSave()
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
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        rebuilding.insert(tabID)
        provisionalNavigations.remove(tabID)
        sessions[tabID]?.stop()
        sessions.removeValue(forKey: tabID)
        sessionRevision &+= 1
        if selectedTabID == tabID {
            _ = ensureSession(for: tabID)
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

    @discardableResult
    func summarizeInChatGPT(_ tabID: UUID? = nil) -> Bool {
        let id = tabID ?? selectedTabID
        guard let id,
              let session = sessions[id],
              let pageURL = session.webView.url ?? tabs.first(where: { $0.id == id })?.url,
              let handoff = BrowserChatGPTHandoff.url(for: pageURL) else { return false }
        return NSWorkspace.shared.open(handoff)
    }

    func cancelSummary() {
        summaryController.cancel()
        summary = .idle
        summaryTabID = nil
    }

    func openReaderMode() {
        guard let tabID = selectedTabID,
              let session = sessions[tabID],
              session.webView.isLoading == false,
              let pageURL = session.webView.url else { return }
        closeReaderMode()
        isReaderVisible = true
        readerError = nil
        let token = UUID()
        readerGeneration = token
        readerTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            guard let page = await BrowserPageTextExtractor.extract(from: session.webView) else {
                guard self.readerGeneration == token,
                      self.selectedTabID == tabID,
                      session.webView.url == pageURL else { return }
                self.readerError = "This page has no readable article text."
                self.readerTask = nil
                return
            }
            guard self.readerGeneration == token,
                  self.selectedTabID == tabID,
                  self.sessions[tabID] === session,
                  session.webView.url == pageURL else { return }
            self.readerPage = page
            self.readerTask = nil
        }
    }

    func closeReaderMode() {
        readerGeneration = UUID()
        readerTask?.cancel()
        readerTask = nil
        isReaderVisible = false
        readerPage = nil
        readerError = nil
    }

    func changeReaderTextSize(by delta: Double) {
        readerTextSize = min(max(readerTextSize + delta, 13), 26)
    }

    func requestSiteDataClear(for tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID && $0.url?.host != nil }) else { return }
        siteDataConfirmationTabID = tabID
    }

    func cancelSiteDataClear() {
        siteDataConfirmationTabID = nil
    }

    func clearConfirmedSiteData() async {
        guard let tabID = siteDataConfirmationTabID,
              let tab = tabs.first(where: { $0.id == tabID }),
              let host = tab.url?.host?.lowercased() else { return }
        siteDataConfirmationTabID = nil
        guard !privateTabIDs.contains(tabID) || sessions[tabID] != nil else { return }
        let dataStore = sessions[tabID]?.webView.configuration.websiteDataStore ?? WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records: [WKWebsiteDataRecord] = await withCheckedContinuation { (continuation: CheckedContinuation<[WKWebsiteDataRecord], Never>) in
            dataStore.fetchDataRecords(ofTypes: types) { continuation.resume(returning: $0) }
        }
        let matchingRecords = records.filter { record in
            let name = record.displayName.lowercased()
            return name == host || host.hasSuffix(".\(name)") || name.hasSuffix(".\(host)")
        }
        guard matchingRecords.isEmpty == false else {
            if let session = sessions[tabID] { session.webView.reloadFromOrigin() }
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            dataStore.removeData(ofTypes: types, for: matchingRecords) {
                continuation.resume()
            }
        }
        let registrableDomain = tab.url.flatMap(BrowserDomain.registrableDomain)
        let isPrivate = privateTabIDs.contains(tabID)
        for affected in tabs where privateTabIDs.contains(affected.id) == isPrivate
            && affected.url.flatMap(BrowserDomain.registrableDomain) == registrableDomain {
            sessions[affected.id]?.webView.reloadFromOrigin()
        }
    }

    // MARK: - Session callbacks

    func sessionDidStart(tabID: UUID, url: URL?) {
        provisionalNavigations.insert(tabID)
        if selectedTabID == tabID { invalidateFind() }
        if selectedTabID == tabID, isReaderVisible { closeReaderMode() }
        if selectedTabID == tabID {
            loadingTabID = tabID
            errorText = nil
        }
        if summaryTabID == tabID {
            summaryController.cancel()
            summary = .idle
            summaryTabID = nil
        }
        touch(tabID, force: true)
    }

    func sessionDidCommit(tabID: UUID, url: URL?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        provisionalNavigations.remove(tabID)
        let oldDomain = tabs[index].url.flatMap(BrowserDomain.registrableDomain)
        let newDomain = url.flatMap(BrowserDomain.registrableDomain)
        let oldEnabled = BrowserBlockerPolicy.isEnabled(settings: settings,
                                                        tab: tabs[index],
                                                        domain: oldDomain)
        updateTabURL(url, at: index)
        if selectedTabID == tabID {
            if isAddressVisible { addressText = url?.absoluteString ?? "" }
            canGoBack = sessions[tabID]?.webView.canGoBack ?? false
            canGoForward = sessions[tabID]?.webView.canGoForward ?? false
        }
        let newEnabled = BrowserBlockerPolicy.isEnabled(settings: settings,
                                                        tab: tabs[index],
                                                        domain: newDomain)
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
        provisionalNavigations.remove(tabID)
        if selectedTabID == tabID { loadingTabID = nil }
        if let index = tabs.firstIndex(where: { $0.id == tabID }) {
            updateTabURL(url, at: index)
            let resolved = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            tabs[index].title = resolved.isEmpty
                ? (url?.host ?? "New Tab")
                : resolved
            tabs[index].lastUsed = Date()
            now = tabs[index].lastUsed
            if !privateTabIDs.contains(tabID) {
                recordHistory(url: url ?? tabs[index].url, title: tabs[index].title)
            }
        }
        if selectedTabID == tabID {
            self.canGoBack = canGoBack
            self.canGoForward = canGoForward
            if isFindVisible, !findText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                findInPage()
            }
        }
        scheduleSave()
        loadFavicon(tabID: tabID)
    }

    func sessionDidObserve(_ session: BrowserTabSession, state: BrowserNavigationState) {
        let tabID = session.tabID
        guard sessions[tabID] === session,
              let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let previousURL = tabs[index].url
        let canApplyPageState = state.isLoading == false && provisionalNavigations.contains(tabID) == false
        let urlChanged = canApplyPageState && updateTabURL(state.url, at: index)
        let resolvedTitle = state.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var didChange = urlChanged
        if canApplyPageState, resolvedTitle.isEmpty == false,
           tabs[index].title != resolvedTitle {
            tabs[index].title = resolvedTitle
            didChange = true
        }
        if selectedTabID == tabID {
            loadingTabID = state.isLoading ? tabID : nil
            canGoBack = state.canGoBack
            canGoForward = state.canGoForward
            if urlChanged, isAddressVisible {
                addressText = state.url?.absoluteString ?? ""
            }
        }
        if urlChanged, previousURL?.host?.caseInsensitiveCompare(state.url?.host ?? "") != .orderedSame,
           state.isLoading == false {
            loadFavicon(tabID: tabID)
        }
        if didChange { scheduleSave() }
    }

    func sessionDidFail(tabID: UUID, error: Error) {
        provisionalNavigations.remove(tabID)
        if selectedTabID == tabID {
            loadingTabID = nil
            let failure = error as NSError
            guard failure.domain != NSURLErrorDomain || failure.code != NSURLErrorCancelled else { return }
            errorText = error.localizedDescription
        }
    }

    func dismissNavigationError() {
        errorText = nil
    }

    func copyURL(for tabID: UUID? = nil) {
        guard let tab = tabs.first(where: { $0.id == (tabID ?? selectedTabID) }),
              let url = tab.url else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(url.absoluteString, forType: .string) else {
            errorText = "Could not copy the page URL to the clipboard."
            return
        }
        noticeTask?.cancel()
        noticeText = "URL copied"
        noticeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.noticeText = nil
                self?.noticeTask = nil
            } catch {
                return
            }
        }
    }

    func showFind() {
        isAddressVisible = false
        isFindVisible = true
    }

    func hideFind() {
        isFindVisible = false
        invalidateFind()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isFindVisible,
                  let webView = self.selectedSession?.webView else { return }
            NSApp.keyWindow?.makeFirstResponder(webView)
        }
    }

    func findInPage(backwards: Bool = false) {
        let query = findText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              let tabID = selectedTabID,
              let session = sessions[tabID] else {
            invalidateFind()
            return
        }
        findTask?.cancel()
        let generation = UUID()
        findGeneration = generation
        findMatchFound = nil
        isFindSearching = true
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        findTask = Task { @MainActor [weak self, weak session] in
            do {
                let result = try await session?.webView.find(query, configuration: configuration)
                guard let self,
                      self.findGeneration == generation else { return }
                guard self.selectedTabID == tabID,
                      let session,
                      self.sessions[tabID] === session else {
                    self.isFindSearching = false
                    self.findTask = nil
                    return
                }
                let pageText = try await session.webView.evaluateJavaScript("document.body?.innerText ?? ''") as? String
                guard self.findGeneration == generation,
                      self.selectedTabID == tabID,
                      self.sessions[tabID] === session else { return }
                let count = Self.countFindMatches(in: pageText ?? "", query: query)
                self.findMatchCount = count
                self.findMatchFound = (result?.matchFound ?? false) || count > 0
                self.isFindSearching = false
                self.findTask = nil
            } catch {
                guard let self, self.findGeneration == generation, !Task.isCancelled else { return }
                self.isFindSearching = false
                self.findTask = nil
                self.errorText = "Could not search the page: \(error.localizedDescription)"
            }
        }
    }

    private func invalidateFind() {
        findGeneration = UUID()
        findTask?.cancel()
        findTask = nil
        findMatchFound = nil
        findMatchCount = nil
        isFindSearching = false
    }

    static func countFindMatches(in text: String, query: String) -> Int {
        guard !query.isEmpty else { return 0 }
        let source = text as NSString
        var location = 0
        var count = 0
        while location < source.length {
            let range = source.range(of: query,
                                     options: [.caseInsensitive],
                                     range: NSRange(location: location,
                                                    length: source.length - location))
            guard range.location != NSNotFound else { break }
            count += 1
            location = NSMaxRange(range)
        }
        return count
    }

    @discardableResult
    private func updateTabURL(_ url: URL?, at index: Int) -> Bool {
        guard let url, tabs[index].url != url else { return false }
        let oldURL = tabs[index].url
        let oldDomain = oldURL.flatMap(BrowserDomain.registrableDomain)
        let newDomain = BrowserDomain.registrableDomain(url)
        tabs[index].url = url
        tabs[index].title = url.host ?? url.absoluteString
        if oldDomain != newDomain { tabs[index].blockerOverride = nil }
        if oldURL?.host?.lowercased() != url.host?.lowercased() {
            tabs[index].faviconURL = nil
            tabs[index].faviconColor = nil
            faviconImages.removeValue(forKey: tabs[index].id)
        }
        return true
    }

    func sessionDidTerminate(tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        if selectedTabID == tabID { invalidateFind() }
        provisionalNavigations.remove(tabID)
        sessions[tabID]?.stop()
        sessions.removeValue(forKey: tabID)
        sessionRevision &+= 1
        if selectedTabID == tabID {
            _ = ensureSession(for: tabID)
            errorText = "The page stopped responding and was reloaded."
        }
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
                                        store: self,
                                        isInspectable: isWebInspectorEnabled(for: tabID))
        sessions[tabID] = session
        if let url = tab.url {
            session.load(url)
        }
        sessionRevision &+= 1
        return session
    }

    private func makeConfiguration(for tab: BrowserTab) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = privateTabIDs.contains(tab.id)
            ? WKWebsiteDataStore.nonPersistent()
            : WKWebsiteDataStore.default()
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
        let persistentTabs = tabs.filter { !privateTabIDs.contains($0.id) }
        let persistentSelection = selectedTabID.flatMap { privateTabIDs.contains($0) ? nil : $0 }
            ?? orderedTabs.first(where: { !privateTabIDs.contains($0.id) })?.id
        let payload = BrowserTabsPayload(tabs: persistentTabs,
                                         selectedTabID: persistentSelection,
                                         sidebarWidth: sidebarWidth,
                                         expandedSidebarWidth: expandedSidebarWidth)
        _ = tabStore.save(payload)
    }
}

private enum BrowserVersion {
    static var string: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
