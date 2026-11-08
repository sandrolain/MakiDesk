import Foundation

/// The state behind the helper's find bar (F3 L2).
///
/// Ghostty owns the matching. The host sends a `search:` binding action and
/// receives the total and the selected match back as surface actions; this
/// value only formats that state and names the actions, so the wording and the
/// clamping stay testable without a live surface.
public struct TerminalSearchState: Equatable, Sendable {
    /// What the user typed. Sent as `search:<needle>`.
    public var needle: String
    /// Matches in the scrollback, as reported by Ghostty. Nil while unknown.
    public var total: Int?
    /// The selected match, one-based. Nil while unknown.
    public var selected: Int?

    public init(needle: String = "", total: Int? = nil, selected: Int? = nil) {
        self.needle = needle
        self.total = Self.sanitized(total)
        self.selected = Self.sanitized(selected)
    }

    public var hasResults: Bool { (total ?? 0) > 0 }

    /// A short label for the bar: "3 of 17", "No results", or nothing before
    /// the first report.
    public var countText: String {
        guard let total else { return "" }
        guard total > 0 else { return "No results" }
        let current = min(max(selected ?? 1, 1), total)
        return "\(current) of \(total)"
    }

    public mutating func apply(total: Int?) {
        self.total = Self.sanitized(total)
        guard let total else {
            selected = nil
            return
        }
        if total == 0 {
            selected = nil
        } else if let selected {
            self.selected = min(max(selected, 1), total)
        }
    }

    public mutating func apply(selected: Int?) {
        guard let selected = Self.sanitized(selected) else {
            self.selected = nil
            return
        }
        guard let total else {
            self.selected = selected
            return
        }
        self.selected = total == 0 ? nil : min(max(selected, 1), total)
    }

    /// Ghostty reports -1 for "no value"; treat it and anything negative as
    /// unknown rather than a count.
    private static func sanitized(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }
}

/// The two directions of the find bar, with the binding actions Ghostty
/// understands.
public enum TerminalSearchNavigation: String, CaseIterable, Sendable {
    case next
    case previous

    public var bindingAction: String { "navigate_search:\(rawValue)" }
    public static let startAction = "start_search"
    public static let endAction = "end_search"

    public static func needleAction(_ needle: String) -> String {
        "search:\(needle)"
    }
}
