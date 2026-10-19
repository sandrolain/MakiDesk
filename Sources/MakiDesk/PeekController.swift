import Foundation

/// The peek's hold bookkeeping (T16): whether a hold is running and since when.
///
/// Kept apart from the store, the overlay and the capture so the awkward part —
/// a key press without its release — can be tested without a screen: the clock
/// is injected, and a lost release shows up as [`hasExpired`].
final class PeekController {
    private(set) var state: State = .idle

    enum State: Equatable {
        case idle
        case holding(since: Date)
    }

    /// Read once at construction, so tests can run the clock forward.
    var now: () -> Date = Date.init
    /// How long a hold may last before the release is assumed lost — the key
    /// released while another app had it, a lock screen, a stuck modifier. The
    /// overlay closes anyway: leaving it up with no key held would look like a
    /// window that cannot be dismissed.
    var holdWatchdog: TimeInterval = 10

    var isHolding: Bool {
        if case .holding = state { return true }
        return false
    }

    /// Starts a hold. Returns false when one is already running, so a repeated
    /// press (key repeat on a held key) neither restarts the clock nor captures
    /// again.
    @discardableResult
    func press() -> Bool {
        guard !isHolding else { return false }
        state = .holding(since: now())
        return true
    }

    /// Ends a hold, returning how long it lasted, or nil when none was running.
    @discardableResult
    func release() -> TimeInterval? {
        guard case let .holding(since) = state else { return nil }
        state = .idle
        return now().timeIntervalSince(since)
    }

    /// Whether the running hold has outlived the watchdog.
    var hasExpired: Bool {
        guard case let .holding(since) = state else { return false }
        return now().timeIntervalSince(since) >= holdWatchdog
    }

    /// Ends a hold outright (Esc, the watchdog, a screen lock or a sleep).
    func cancel() { state = .idle }
}
