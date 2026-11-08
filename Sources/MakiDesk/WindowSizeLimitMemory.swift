import CoreGraphics
import Foundation

/// A length a window keeps on one axis whatever it is asked: Raycast's
/// Settings stays 960 wide, a Screen Sharing window keeps its aspect ratio.
struct FixedAxis: Equatable, Sendable {
    enum Axis: String, Sendable {
        case width, height
    }

    let axis: Axis
    let length: CGFloat

    /// Same axis, same length within a point of rounding.
    func matches(_ other: FixedAxis) -> Bool {
        axis == other.axis && abs(length - other.length) <= 2
    }

    func matches(_ size: CGSize) -> Bool {
        abs((axis == .width ? size.width : size.height) - length) <= 2
    }
}

/// What a layout may ask of one window: a floor per axis, and a length the app
/// keeps regardless. A zero length means "nothing known" on that axis.
struct WindowSizeLimits: Equatable, Sendable {
    var minimum: CGSize = .zero
    var fixed: FixedAxis?

    var isEmpty: Bool { minimum == .zero && fixed == nil }

    /// Whether the frame is smaller than a floor the app has already shown.
    func isTooSmall(_ size: CGSize, tolerance: CGFloat = 0) -> Bool {
        (minimum.width > 0 && size.width + tolerance < minimum.width)
            || (minimum.height > 0 && size.height + tolerance < minimum.height)
    }

    /// The frame with a known floor applied. A floor is a minimum: it never
    /// shrinks a frame the app already accepted.
    func clamped(_ size: CGSize) -> CGSize {
        CGSize(width: max(size.width, minimum.width),
               height: max(size.height, minimum.height))
    }
}

/// Session memory of the size floors and fixed lengths apps have shown.
///
/// macOS does not expose a reliable minimum size: `AXMinimumSize` is often
/// missing or wrong, and the real floor depends on what the window is showing.
/// This memory learns only from a refusal that passed the guards in
/// `observeRefusal`, and deliberately forgets on restart: a floor is a property
/// of the window's current interface, not of the app forever.
///
/// Main-actor only: it is read and written by the frame-verification path.
@MainActor
final class WindowSizeLimitMemory {
    private struct Entry {
        var minimum: CGSize = .zero
        var fixed: FixedAxis?
    }

    /// An oversize smaller than this is rounding, not a floor.
    static let overshoot: CGFloat = 20
    /// A size has to come down by this much before the floor is relaxed. A
    /// sub-pixel accept cannot ratchet a bound away.
    static let lowerDelta: CGFloat = 10
    static let positionTolerance: CGFloat = 1
    static let sizeTolerance: CGFloat = 2
    /// Real lengths above this are AX sentinels, not UI.
    static let usableMaximum: CGFloat = 10_000

    private var entries: [String: Entry] = [:]
    /// Per-axis maximum a bundle's windows have refused, for a new window of
    /// the same app that has no evidence of its own.
    private var appMinimums: [String: CGSize] = [:]
    /// A fixed length seen once; confirmed by the next identical refusal.
    private var fixedSuspects: [String: FixedAxis] = [:]

    /// What is known about a window: its own evidence first, then its app's
    /// hint. A hint is never stored as the window's own entry, so real
    /// evidence can replace it instead of inheriting a guess.
    func limits(for identity: String, bundleId: String?) -> WindowSizeLimits {
        if let entry = entries[identity] {
            return WindowSizeLimits(minimum: entry.minimum, fixed: entry.fixed)
        }
        if let bundleId, bundleId.isEmpty == false, let hint = appMinimums[bundleId] {
            return WindowSizeLimits(minimum: hint)
        }
        return WindowSizeLimits()
    }

    /// Whether this window has already proved it keeps that length, so a
    /// size-first retry cannot change anything.
    func knowsFixed(_ axis: FixedAxis, identity: String) -> Bool {
        guard let entry = entries[identity], let fixed = entry.fixed else { return false }
        return fixed.matches(axis)
    }

    /// Learns from a refused frame. The guards are deliberate: only a frame
    /// that landed at the requested origin, arrived at by a real write and
    /// read back, can teach a floor. An animation or a stale read teaches
    /// nothing. Returns true when something was recorded.
    @discardableResult
    func observeRefusal(identity: String, bundleId: String?,
                        wanted: CGRect, previous: CGRect, actual: CGRect,
                        recordMinimum: Bool = true) -> Bool {
        guard identity.isEmpty == false, isUsableFrame(actual) else { return false }
        guard abs(actual.minX - wanted.minX) <= Self.positionTolerance,
              abs(actual.minY - wanted.minY) <= Self.positionTolerance else { return false }

        var learned = false
        if recordMinimum {
            var minimum = entries[identity]?.minimum ?? .zero
            if actual.width > wanted.width + Self.overshoot,
               usable(actual.width), actual.width > minimum.width {
                minimum.width = actual.width
                learned = true
            }
            if actual.height > wanted.height + Self.overshoot,
               usable(actual.height), actual.height > minimum.height {
                minimum.height = actual.height
                learned = true
            }
            if learned {
                var entry = entries[identity] ?? Entry()
                entry.minimum = minimum
                entries[identity] = entry
                raiseAppHint(bundleId, minimum: minimum)
            }
        }

        // A fixed axis is one whose length did not move while the other axis
        // reached the target. One reading is a suspect; the next identical
        // refusal confirms it, so a slow app is not declared fixed.
        let keptWidth = abs(actual.width - previous.width) <= Self.sizeTolerance
            && abs(actual.width - wanted.width) > Self.overshoot
        let keptHeight = abs(actual.height - previous.height) <= Self.sizeTolerance
            && abs(actual.height - wanted.height) > Self.overshoot
        if keptWidth, abs(actual.height - wanted.height) <= Self.sizeTolerance {
            learned = recordFixed(FixedAxis(axis: .width, length: actual.width),
                                  identity: identity) || learned
        }
        if keptHeight, abs(actual.width - wanted.width) <= Self.sizeTolerance {
            learned = recordFixed(FixedAxis(axis: .height, length: actual.height),
                                  identity: identity) || learned
        }
        return learned
    }

    /// Lowers a floor when the app accepts a smaller frame, and clears a fixed
    /// record the app just contradicted. Returns true when something changed.
    @discardableResult
    func observeAccepted(identity: String, bundleId: String?, actual: CGSize) -> Bool {
        guard identity.isEmpty == false, isUsableSize(actual) else { return false }
        fixedSuspects.removeValue(forKey: identity)

        guard var entry = entries[identity] else {
            lowerAppHint(bundleId, accepted: actual)
            return false
        }

        var changed = false
        if let fixed = entry.fixed, fixed.matches(actual) == false {
            entry.fixed = nil
            changed = true
        }
        if entry.minimum.width > 0,
           actual.width < entry.minimum.width - Self.lowerDelta {
            entry.minimum.width = actual.width
            changed = true
        }
        if entry.minimum.height > 0,
           actual.height < entry.minimum.height - Self.lowerDelta {
            entry.minimum.height = actual.height
            changed = true
        }
        if changed { entries[identity] = entry }
        lowerAppHint(bundleId, accepted: actual)
        return changed
    }

    func forget(identity: String) {
        entries.removeValue(forKey: identity)
        fixedSuspects.removeValue(forKey: identity)
    }

    /// A terminated app's windows are gone. A CG window number can be reused,
    /// so the floor one of them proved must not outlive the process. The app
    /// hint stays: it is evidence about the bundle, not about a window.
    func forget(pid: pid_t) {
        let prefix = "\(pid)-"
        entries = entries.filter { $0.key.hasPrefix(prefix) == false }
        fixedSuspects = fixedSuspects.filter { $0.key.hasPrefix(prefix) == false }
    }

    func reset() {
        entries.removeAll()
        appMinimums.removeAll()
        fixedSuspects.removeAll()
    }

    // MARK: - Private

    /// `true` only on the second identical refusal. The first stores a
    /// suspect, which the size-first retry is expected to confirm.
    private func recordFixed(_ axis: FixedAxis, identity: String) -> Bool {
        guard usable(axis.length) else { return false }
        if let suspect = fixedSuspects[identity], suspect.matches(axis) {
            fixedSuspects.removeValue(forKey: identity)
        } else if fixedSuspects[identity]?.matches(axis) != true {
            fixedSuspects[identity] = axis
            return false
        }
        guard var entry = entries[identity] else {
            entries[identity] = Entry(fixed: axis)
            return true
        }
        guard entry.fixed?.matches(axis) != true else { return false }
        entry.fixed = axis
        entries[identity] = entry
        return true
    }

    private func raiseAppHint(_ bundleId: String?, minimum: CGSize) {
        guard let bundleId, bundleId.isEmpty == false else { return }
        let existing = appMinimums[bundleId] ?? .zero
        let raised = CGSize(width: max(existing.width, minimum.width),
                            height: max(existing.height, minimum.height))
        guard raised != existing else { return }
        appMinimums[bundleId] = raised
    }

    private func lowerAppHint(_ bundleId: String?, accepted: CGSize) {
        guard let bundleId, bundleId.isEmpty == false,
              let existing = appMinimums[bundleId] else { return }
        var lowered = existing
        if existing.width > 0, accepted.width > 0,
           accepted.width < existing.width - Self.lowerDelta {
            lowered.width = accepted.width
        }
        if existing.height > 0, accepted.height > 0,
           accepted.height < existing.height - Self.lowerDelta {
            lowered.height = accepted.height
        }
        guard lowered != existing else { return }
        if lowered.width == 0 && lowered.height == 0 {
            appMinimums.removeValue(forKey: bundleId)
        } else {
            appMinimums[bundleId] = lowered
        }
    }

    private func isUsableFrame(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite
            && isUsableSize(frame.size)
    }

    private func isUsableSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite
            && size.width > 0 && size.height > 0
            && usable(size.width) && usable(size.height)
    }

    /// Zero means "nothing known" and is allowed; a negative, infinite or
    /// sentinel length is not evidence.
    private func usable(_ value: CGFloat) -> Bool {
        value.isFinite && value > 0 && value < Self.usableMaximum
    }
}
