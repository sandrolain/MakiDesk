import Foundation

/// The screen text a terminal shows to accessibility clients, plus the rules
/// for turning an accessibility write back into terminal input.
///
/// The value handed to `AXValue` is a short-lived snapshot: a client that reads
/// it before and after an insertion must see the new text, but repeated queries
/// in one burst should not copy the terminal grid each time. Dictation tools
/// also compare the text they read with the text they write: writing back the
/// whole screen plus their insertion must type only the insertion.
public final class TerminalAccessibilityText {
    /// How long one snapshot answers AX queries before the screen is read
    /// again.
    public static let snapshotLifetime: TimeInterval = 0.5
    /// How long a value handed to a client stays eligible for edit detection.
    public static let historyLifetime: TimeInterval = 30
    /// A bound on retained values, in UTF-8 bytes.
    public static let historyByteLimit = 1024 * 1024

    private struct VendedValue {
        let value: String
        var lastVendedAt: TimeInterval
        let byteCount: Int
    }

    private var snapshot: String?
    private var snapshotCapturedAt: TimeInterval = 0
    private var history: [VendedValue] = []

    public init() {}

    /// The current value, reading the screen only when the snapshot expired.
    /// Every returned value is remembered so an accessibility write can be
    /// diffed against what the client actually saw.
    public func value(now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                      read: () -> String?) -> String {
        let value: String
        if let snapshot, now - snapshotCapturedAt < Self.snapshotLifetime {
            value = snapshot
        } else {
            value = read() ?? ""
            snapshot = value
            snapshotCapturedAt = now
        }
        record(value, at: now)
        return value
    }

    /// Drops the snapshot so the next query reads the screen again.
    public func invalidate() {
        snapshot = nil
    }

    /// The text a client meant to insert when it sets the whole value.
    ///
    /// A client that writes the screen it read plus a phrase should type only
    /// the phrase. Anything that is not an edit of a recently vended value is
    /// taken literally, which is how a client that writes just its dictation
    /// has always worked.
    public func insertedText(settingValue newValue: String,
                             now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> String {
        prune(at: now)
        // An exact read anywhere in history beats a partial match against a
        // newer screen with a different tail.
        for allowsPartialMatch in [false, true] {
            for vended in history.reversed() {
                if let inserted = Self.insertedText(settingValue: newValue,
                                                   over: vended.value,
                                                   allowsPartialMatch: allowsPartialMatch) {
                    return inserted
                }
            }
        }
        return newValue
    }

    /// The edited middle of `newValue` when it keeps `currentValue` around one
    /// insertion, or `nil` when it is not an edit.
    ///
    /// A pure insertion (everything before or after survives) counts for any
    /// length. A replacement that also removed a selection counts only for a
    /// long current value, so a short literal that happens to end like a
    /// prompt is not trimmed.
    public static func insertedText(settingValue newValue: String,
                                    over currentValue: String,
                                    allowsPartialMatch: Bool = true) -> String? {
        let old = Array(currentValue.unicodeScalars)
        guard old.isEmpty == false else { return nil }
        let new = Array(newValue.unicodeScalars)
        let limit = min(old.count, new.count)
        var prefix = 0
        while prefix < limit, old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < limit - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        let kept = prefix + suffix
        guard kept == old.count
                || (allowsPartialMatch && old.count >= 64 && kept >= old.count / 2) else {
            return nil
        }
        var inserted = String.UnicodeScalarView()
        inserted.append(contentsOf: new[prefix..<(new.count - suffix)])
        return String(inserted)
    }

    /// Splits the newlines at the very end of a value from its body. A client
    /// that appends `\n` to dictation expects Return to be pressed; a line
    /// break in the middle is a multi-line paste.
    public static func splitTrailingLineBreaks(_ text: String) -> (body: String, breaks: Int) {
        var body = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var breaks = 0
        while body.hasSuffix("\n") {
            body.removeLast()
            breaks += 1
        }
        return (body, breaks)
    }

    public static func containsLineBreak(_ text: String) -> Bool {
        text.contains("\n") || text.contains("\r")
    }

    // MARK: - History

    private func record(_ value: String, at now: TimeInterval) {
        prune(at: now)
        guard value.isEmpty == false else { return }
        if history.last?.value == value {
            history[history.count - 1].lastVendedAt = now
            return
        }
        let byteCount = value.utf8.count
        guard byteCount <= Self.historyByteLimit else { return }
        history.removeAll { $0.value == value }
        history.append(VendedValue(value: value, lastVendedAt: now, byteCount: byteCount))
        var total = history.reduce(0) { $0 + $1.byteCount }
        while total > Self.historyByteLimit, history.isEmpty == false {
            total -= history.removeFirst().byteCount
        }
    }

    private func prune(at now: TimeInterval) {
        history.removeAll { now - $0.lastVendedAt >= Self.historyLifetime }
    }
}
