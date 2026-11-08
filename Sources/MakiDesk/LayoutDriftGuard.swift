import CoreGraphics
import Foundation

/// The bounded answer to a window that stopped matching the layout a command
/// just accepted.
///
/// One moved frame is never enough: a window may still be settling, or the user
/// may be dragging it. Two readings have to agree before the guard asks for one
/// re-apply. If the app takes the frame back again straight away, the guard
/// stops instead of trading writes with it. Pure and clock-injected, so every
/// episode is a table test.
struct LayoutDriftGuard {
    enum Decision: Equatable {
        /// On target, or nothing to do.
        case idle
        /// One drifted reading; waiting for another that agrees.
        case seen
        /// Re-apply the layout once.
        case reapply
        /// The app took the frame back after a re-apply: stop.
        case abandon
    }

    /// Position and size away from the intended frame that count as drift.
    static let positionTolerance: CGFloat = 1
    static let sizeTolerance: CGFloat = 20
    /// Two readings agree on the drifted frame within this.
    static let sampleTolerance: CGFloat = 1

    private var lastSample: CGRect?
    private var reappliedAt: Date?
    private var abandoned = false
    private var reapplies = 0

    mutating func note(frame: CGRect, intended: CGRect, now: Date,
                       recurrenceWindow: TimeInterval) -> Decision {
        if abandoned { return .idle }

        if onTarget(frame, intended) {
            lastSample = nil
            reappliedAt = nil
            return .idle
        }

        guard drifted(frame, intended) else {
            lastSample = nil
            return .idle
        }

        if let lastSample, FrameMismatch.isAtTarget(frame, target: lastSample,
                                                    tolerance: Self.sampleTolerance) {
            if let reappliedAt {
                guard now.timeIntervalSince(reappliedAt) <= recurrenceWindow else {
                    // The layout held for a while: this is a new episode.
                    return requestReapply(now: now)
                }
                abandoned = true
                return .abandon
            }
            return requestReapply(now: now)
        }

        lastSample = frame
        return .seen
    }

    /// One re-apply per episode, and never more than two per layout: a window
    /// that touches its tile and falls back again must not loop forever.
    private mutating func requestReapply(now: Date) -> Decision {
        guard reapplies < 2 else {
            abandoned = true
            return .abandon
        }
        reapplies += 1
        reappliedAt = now
        lastSample = nil
        return .reapply
    }

    private func onTarget(_ frame: CGRect, _ intended: CGRect) -> Bool {
        FrameMismatch.isAtTarget(frame, target: intended, tolerance: 2)
    }

    private func drifted(_ frame: CGRect, _ intended: CGRect) -> Bool {
        abs(frame.minX - intended.minX) > Self.positionTolerance
            || abs(frame.minY - intended.minY) > Self.positionTolerance
            || abs(frame.width - intended.width) > Self.sizeTolerance
            || abs(frame.height - intended.height) > Self.sizeTolerance
    }
}
