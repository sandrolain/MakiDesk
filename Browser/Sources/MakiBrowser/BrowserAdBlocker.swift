import Foundation
import WebKit

/// The built-in blocker. The production list is generated from EasyList and
/// EasyPrivacy by the pipeline in the browser analysis; this first version
/// ships a compact starter list so the feature is useful immediately and the
/// compile/attach path is real, not a stub. Replacing the array with a
/// generated JSON resource does not change the API.
@MainActor
final class BrowserAdBlocker {
    static let identifier = "makidesk-browser-starter-v1"

    private var cached: WKContentRuleList?
    private var prepared = false

    /// The common networks that appear in display and tracking calls. This is
    /// deliberately domain-level: it cannot hide elements, but it stops the
    /// requests without a large list and without over-blocking editorial
    /// content.
    static let starterDomains: [String] = [
        "doubleclick.net",
        "googlesyndication.com",
        "googleadservices.com",
        "adservice.google.com",
        "amazon-adsystem.com",
        "adsrvr.org",
        "adnxs.com",
        "adform.net",
        "adition.com",
        "bidswitch.net",
        "casalemedia.com",
        "contextweb.com",
        "criteo.com",
        "criteo.net",
        "emxdgt.com",
        "flashtalking.com",
        "gumgum.com",
        "indexexchange.com",
        "innovid.com",
        "lijit.com",
        "media.net",
        "mgid.com",
        "moatads.com",
        "nativo.com",
        "openx.net",
        "outbrain.com",
        "plista.com",
        "pubmatic.com",
        "quantserve.com",
        "revcontent.com",
        "rubiconproject.com",
        "scorecardresearch.com",
        "serving-sys.com",
        "sharethrough.com",
        "sizmek.com",
        "smartadserver.com",
        "sovrn.com",
        "spotxchange.com",
        "taboola.com",
        "teads.tv",
        "tremorhub.com",
        "triplelift.com",
        "turn.com",
        "undertone.com",
        "vidazoo.com",
        "yieldlab.net",
        "yieldmo.com",
        "zedo.com",
        "zergnet.com",
        "adroll.com",
        "bing.com/bat.js",
        "facebook.com/tr",
        "connect.facebook.net",
        "analytics.twitter.com",
        "static.ads-twitter.com",
        "bat.bing.com",
        "ct.pinterest.com",
        "sc-static.net",
        "snap.licdn.com",
        "px.ads.linkedin.com",
    ]

    /// Compiles once and returns the list. A failure is not fatal: the browser
    /// works without a blocker and the UI can say so.
    func prepare() async -> WKContentRuleList? {
        if prepared { return cached }
        prepared = true

        guard let store = WKContentRuleListStore.default() else { return nil }

        if let existing = await lookup(store) {
            cached = existing
            return existing
        }

        guard let json = Self.rulesJSON() else { return nil }
        do {
            let list = try await compile(store, json: json)
            cached = list
            return list
        } catch {
            BrowserLog.store.error("browser blocker: compile failed -> \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func lookup(_ store: WKContentRuleListStore) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: Self.identifier) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    private func compile(_ store: WKContentRuleListStore,
                         json: String) async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: Self.identifier,
                                         encodedContentRuleList: json) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: error ?? BrowserBlockerError.compileFailed)
                }
            }
        }
    }

    static func rulesJSON() -> String? {
        let rules: [[String: Any]] = starterDomains.map { domain in
            let escaped = NSRegularExpression.escapedPattern(for: domain)
            return [
                "trigger": [
                    "url-filter": "^[^:]+:(//)?([^/]+\\.)?\(escaped)([/:?].*)?$",
                ],
                "action": ["type": "block"],
            ]
        }
        guard JSONSerialization.isValidJSONObject(rules),
              let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }
}

private enum BrowserBlockerError: LocalizedError {
    case compileFailed

    var errorDescription: String? { "The content blocker could not be compiled." }
}
