import Foundation

public struct CodexUsageWindow: Equatable, Sendable {
    public let id: String
    public let label: String
    public let usedPercent: Int
    public let resetsAt: Date?

    public init(id: String, label: String, usedPercent: Int, resetsAt: Date?) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct CodexAccountUsage: Equatable, Sendable {
    public let windows: [CodexUsageWindow]
    public let lifetimeTokens: Int64?
    public let peakDailyTokens: Int64?
    public let resetCredits: Int?
    public let creditSummaries: [String]
    public let updatedAt: Date

    public init(windows: [CodexUsageWindow], lifetimeTokens: Int64?, peakDailyTokens: Int64?,
                resetCredits: Int?, creditSummaries: [String] = [], updatedAt: Date) {
        self.windows = windows
        self.lifetimeTokens = lifetimeTokens
        self.peakDailyTokens = peakDailyTokens
        self.resetCredits = resetCredits
        self.creditSummaries = creditSummaries
        self.updatedAt = updatedAt
    }
}

/// Small refresh state machine shared by the UI and deterministic lifecycle tests.
public struct CodexUsageRefreshLifecycle: Sendable {
    public private(set) var isVisible = false
    public private(set) var isRefreshing = false
    public private(set) var generation: UInt64 = 0

    public init() {}

    /// Returns true only when transitioning into visible state.
    @discardableResult
    public mutating func setVisible(_ visible: Bool) -> Bool {
        guard isVisible != visible else { return false }
        isVisible = visible
        generation &+= 1
        isRefreshing = false
        return visible
    }

    public mutating func beginRefresh() -> UInt64? {
        guard isVisible, isRefreshing == false else { return nil }
        generation &+= 1
        isRefreshing = true
        return generation
    }

    /// A response can publish only for the active visible generation.
    @discardableResult
    public mutating func finishRefresh(generation: UInt64) -> Bool {
        guard isVisible, isRefreshing, self.generation == generation else { return false }
        isRefreshing = false
        return true
    }
}

/// Strictly parses only account quota and account-wide token activity returned
/// by the documented app-server methods. Unknown and thread-scoped fields are ignored.
public enum CodexAccountUsageParser {
    public static func rateLimits(from object: Any, updatedAt: Date = Date()) -> CodexAccountUsage? {
        guard let root = object as? [String: Any],
              let result = root["result"] as? [String: Any] else { return nil }
        var buckets: [String: Any] = [:]
        if let byID = result["rateLimitsByLimitId"] as? [String: Any] {
            buckets = byID
        } else if let single = result["rateLimits"] as? [String: Any],
                  let id = single["limitId"] as? String {
            buckets[id] = single
        }

        let windows = buckets.keys.sorted().flatMap { id -> [CodexUsageWindow] in
            guard let bucket = buckets[id] as? [String: Any] else { return [] }
            let displayName = (bucket["limitName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return ["primary", "secondary"].compactMap { key in
                guard let window = bucket[key] as? [String: Any],
                      let percent = window["usedPercent"] as? NSNumber else { return nil }
                let raw = percent.intValue
                guard (0...100).contains(raw) else { return nil }
                let reset = (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                let label = key == "primary" ? displayName : "\(displayName) · secondary"
                return CodexUsageWindow(id: "\(id).\(key)", label: label,
                                        usedPercent: raw, resetsAt: reset)
            }
        }
        let credits = (result["rateLimitResetCredits"] as? [String: Any])?["availableCount"] as? Int
        let creditSummaries = buckets.keys.sorted().compactMap { id -> String? in
            guard let bucket = buckets[id] as? [String: Any],
                  let credit = bucket["credits"] as? [String: Any],
                  let hasCredits = credit["hasCredits"] as? Bool,
                  let unlimited = credit["unlimited"] as? Bool else { return nil }
            let label = (bucket["limitName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            if unlimited { return "\(label) credits: unlimited" }
            if let balance = credit["balance"] as? String { return "\(label) credits: \(balance)" }
            return hasCredits ? "\(label) credits available" : "\(label) credits depleted"
        }
        return CodexAccountUsage(windows: windows, lifetimeTokens: nil, peakDailyTokens: nil,
                                 resetCredits: credits, creditSummaries: creditSummaries,
                                 updatedAt: updatedAt)
    }

    public static func usage(from object: Any, into current: CodexAccountUsage) -> CodexAccountUsage {
        guard let root = object as? [String: Any],
              let result = root["result"] as? [String: Any],
              let summary = result["summary"] as? [String: Any] else { return current }
        return CodexAccountUsage(
            windows: current.windows,
            lifetimeTokens: (summary["lifetimeTokens"] as? NSNumber)?.int64Value,
            peakDailyTokens: (summary["peakDailyTokens"] as? NSNumber)?.int64Value,
            resetCredits: current.resetCredits,
            creditSummaries: current.creditSummaries,
            updatedAt: current.updatedAt
        )
    }
}
