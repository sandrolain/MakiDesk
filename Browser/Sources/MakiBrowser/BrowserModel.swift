import Foundation

/// The lifecycle bucket of a browser tab. `pinned` is not a time bucket: it
/// overrides the 24/48 hour rule, so the enum is also the UI section.
enum BrowserTabPhase: String, Codable, CaseIterable {
    case pinned
    case active
    case old

    var sectionTitle: String {
        switch self {
        case .pinned: return "PINNED"
        case .active: return "ACTIVE"
        case .old: return "OLD"
        }
    }
}

/// A serialisable colour extracted from a favicon. Kept independent of AppKit
/// so the model and its tests do not depend on a window server.
struct BrowserColor: Codable, Equatable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    /// A stable hue from the registrable domain. It is the fallback when a
    /// favicon is missing or cannot be decoded, so the tab still has an
    /// identity without a network request.
    static func fallback(for domain: String) -> BrowserColor {
        var hash: UInt32 = 2_166_136_261
        for byte in domain.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        let hue = Double(hash % 360) / 360
        return hsb(hue: hue, saturation: 0.58, brightness: 0.66)
    }

    static func hsb(hue: Double, saturation: Double, brightness: Double) -> BrowserColor {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let i = floor(h)
        let f = h - i
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * f)
        let t = brightness * (1 - saturation * (1 - f))
        switch Int(i) % 6 {
        case 0: return BrowserColor(red: brightness, green: t, blue: p)
        case 1: return BrowserColor(red: q, green: brightness, blue: p)
        case 2: return BrowserColor(red: p, green: brightness, blue: t)
        case 3: return BrowserColor(red: p, green: q, blue: brightness)
        case 4: return BrowserColor(red: t, green: p, blue: brightness)
        default: return BrowserColor(red: brightness, green: p, blue: q)
        }
    }
}

/// One browser tab. The value is persisted; the `WKWebView` is not.
struct BrowserTab: Identifiable, Codable, Equatable {
    var id: UUID
    var url: URL?
    var title: String
    var createdAt: Date
    var lastUsed: Date
    var isPinned: Bool
    var faviconURL: URL?
    var faviconColor: BrowserColor?
    /// A session-only override for this exact tab. `nil` means "use the domain
    /// and global settings"; it is deliberately not persisted.
    var blockerOverride: Bool?
    /// WebKit's opaque restoration state. It is only kept when the archive
    /// succeeds; a tab restored from a URL alone is still valid.
    var interactionState: Data?

    init(id: UUID = UUID(),
         url: URL? = nil,
         title: String = "",
         createdAt: Date = Date(),
         lastUsed: Date = Date(),
         isPinned: Bool = false,
         faviconURL: URL? = nil,
         faviconColor: BrowserColor? = nil,
         blockerOverride: Bool? = nil,
         interactionState: Data? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.createdAt = createdAt
        self.lastUsed = lastUsed
        self.isPinned = isPinned
        self.faviconURL = faviconURL
        self.faviconColor = faviconColor
        self.blockerOverride = blockerOverride
        self.interactionState = interactionState
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return url?.host ?? "New Tab"
    }

    var hostKey: String? {
        url.flatMap(BrowserDomain.hostKey)
    }
}

enum BrowserSearchEngine: String, Codable, CaseIterable, Identifiable {
    case google
    case duckDuckGo
    case bing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        }
    }

    func searchURL(for query: String) -> URL? {
        var components: URLComponents?
        switch self {
        case .google:
            components = URLComponents(string: "https://www.google.com/search")
        case .duckDuckGo:
            components = URLComponents(string: "https://duckduckgo.com/")
        case .bing:
            components = URLComponents(string: "https://www.bing.com/search")
        }
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}

struct BrowserSettings: Codable, Equatable {
    var blockerEnabledByDefault: Bool
    var disabledBlockerDomains: Set<String>
    var summaryEnabled: Bool
    /// Prefilled, not loaded automatically, when a new tab opens.
    var defaultPageURL: String
    var searchEngine: BrowserSearchEngine
    var compactTabs: Bool

    init(blockerEnabledByDefault: Bool = true,
         disabledBlockerDomains: Set<String> = [],
         summaryEnabled: Bool = true,
         defaultPageURL: String = "https://www.google.com",
         searchEngine: BrowserSearchEngine = .google,
         compactTabs: Bool = false) {
        self.blockerEnabledByDefault = blockerEnabledByDefault
        self.disabledBlockerDomains = disabledBlockerDomains
        self.summaryEnabled = summaryEnabled
        self.defaultPageURL = defaultPageURL
        self.searchEngine = searchEngine
        self.compactTabs = compactTabs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blockerEnabledByDefault = try container.decodeIfPresent(Bool.self, forKey: .blockerEnabledByDefault) ?? true
        disabledBlockerDomains = try container.decodeIfPresent(Set<String>.self, forKey: .disabledBlockerDomains) ?? []
        summaryEnabled = try container.decodeIfPresent(Bool.self, forKey: .summaryEnabled) ?? true
        defaultPageURL = try container.decodeIfPresent(String.self, forKey: .defaultPageURL) ?? "https://www.google.com"
        searchEngine = try container.decodeIfPresent(BrowserSearchEngine.self, forKey: .searchEngine) ?? .google
        compactTabs = try container.decodeIfPresent(Bool.self, forKey: .compactTabs) ?? false
    }
}

/// The 24/48 hour rule, as pure functions so tests do not need a clock or a
/// window. The view and the timer both call this; nothing else owns the rule.
enum BrowserTabLifecycle {
    static let activeLimit: TimeInterval = 24 * 60 * 60
    static let oldLimit: TimeInterval = 48 * 60 * 60

    static func phase(for tab: BrowserTab, now: Date) -> BrowserTabPhase {
        if tab.isPinned { return .pinned }
        let age = max(0, now.timeIntervalSince(tab.lastUsed))
        if age < activeLimit { return .active }
        if age < oldLimit { return .old }
        return .old
    }

    static func isExpired(_ tab: BrowserTab, now: Date) -> Bool {
        guard !tab.isPinned else { return false }
        return now.timeIntervalSince(tab.lastUsed) >= oldLimit
    }

    /// Tabs in display order: pinned first, then active, then old. Every group
    /// is MRU; the ID is the stable tie-break when two dates are equal.
    static func ordered(_ tabs: [BrowserTab], now: Date) -> [BrowserTab] {
        tabs.sorted { lhs, rhs in
            let left = phase(for: lhs, now: now)
            let right = phase(for: rhs, now: now)
            if left != right {
                return sectionIndex(left) < sectionIndex(right)
            }
            if lhs.lastUsed != rhs.lastUsed {
                return lhs.lastUsed > rhs.lastUsed
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    static func sectionIndex(_ phase: BrowserTabPhase) -> Int {
        switch phase {
        case .pinned: return 0
        case .active: return 1
        case .old: return 2
        }
    }
}

/// Offsets use wall-clock time because the 24/48 hour rule must survive a
/// relaunch. A clock that moves backwards is clamped: nothing closes early.
enum BrowserTimeLabel {
    static func string(since date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 300.0)) * 5
        if minutes < 5 { return "now" }
        if minutes < 60 { return "\(minutes)m" }

        let hours = minutes / 60
        let remainder = minutes % 60
        if hours < 24 {
            return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
        }

        let days = hours / 24
        let rest = hours % 24
        return rest == 0 ? "\(days)d" : "\(days)d \(rest)h"
    }
}

/// Domain keys used by the blocker exception list and by favicon fallbacks.
enum BrowserDomain {
    /// Common two-label public suffixes. This is intentionally a small,
    /// deterministic list instead of a full PSL dependency in the first
    /// version; `example.co.uk` still becomes one key, and an unknown suffix
    /// falls back to the host without `www`.
    private static let multiPartSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk",
        "com.au", "net.au", "org.au", "co.nz", "co.jp", "ne.jp", "or.jp",
        "com.br", "com.cn", "com.mx", "com.tr", "com.sg", "com.hk",
        "co.in", "co.za", "co.kr", "co.id", "co.il", "co.th",
    ]

    static func hostKey(_ url: URL) -> String? {
        guard var host = url.host?.lowercased() else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    static func registrableDomain(_ url: URL) -> String? {
        guard let host = hostKey(url) else { return nil }
        if host.contains(":") { return host } // IPv6
        if isIPAddress(host) { return host }
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count > 2 else { return host }
        let suffix = parts.suffix(2).joined(separator: ".")
        let labelCount = multiPartSuffixes.contains(suffix) ? 3 : 2
        return parts.suffix(labelCount).joined(separator: ".")
    }

    static func isIPAddress(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } == true }
    }
}

/// The blocker is a pure decision for a tab, a domain and the settings. The
/// view, the context menu and the tests all call this instead of duplicating
/// precedence rules.
enum BrowserBlockerPolicy {
    static func isEnabled(settings: BrowserSettings,
                          tab: BrowserTab,
                          domain: String?) -> Bool {
        guard settings.blockerEnabledByDefault else { return false }
        if let override = tab.blockerOverride { return override }
        guard let domain, !domain.isEmpty else { return true }
        return !settings.disabledBlockerDomains.contains(domain)
    }
}

/// Turns what the address field contains into a URL. A bare host becomes
/// HTTPS; anything with spaces or without a dot becomes a DuckDuckGo search.
enum BrowserURLInput {
    static func url(from raw: String, searchEngine: BrowserSearchEngine = .google) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let url = URL(string: value), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return url
        }

        let looksLikeHost = !value.contains(" ")
            && (value.contains(".") || value.hasPrefix("localhost"))
        if looksLikeHost, let url = URL(string: "https://\(value)") {
            return url
        }

        return searchEngine.searchURL(for: value)
    }
}
