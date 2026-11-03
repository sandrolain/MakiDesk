import CoreGraphics
import Foundation

/// When the utility bar opens and when it goes away (F2).
///
/// Pure on purpose: the pointer arrives as a value and the answer is an action,
/// so the timings and the awkward cases — a drag, a dismissal while the pointer
/// is still in the trigger band, a pointer that leaves and comes back, a pinned
/// bar — are tests instead of a manual inspection of a moving panel.
///
/// The bar never reserves space: it is a panel that appears over the top of the
/// screen and retreats. Nothing here touches windows or Accessibility.
struct BarReveal: Equatable {
    struct Timings: Equatable {
        /// How long the pointer rests in the trigger band before the bar appears.
        var dwell: TimeInterval = 0.25
        /// How long it may stay outside the bar before the bar retreats.
        var linger: TimeInterval = 0.4
        /// The smallest trigger band, used where there is no menu bar.
        var zoneHeight: CGFloat = 12
    }

    enum Action: Equatable {
        case show
        case hide
        case none
    }

    var timings = Timings()
    private(set) var isVisible = false
    private(set) var isPinned = false

    private var enteredZoneAt: TimeInterval?
    private var leftBarAt: TimeInterval?
    /// After a dismissal the pointer may still be inside the trigger band — or
    /// inside the area the bar just left. Without this the bar would come
    /// straight back on the next tick.
    private var waitsForExit = false
    /// A command or the menu asked for the bar while the pointer was elsewhere:
    /// it stays until the pointer arrives (and the ordinary linger takes over).
    private var sticky = false

    // MARK: - Geometry

    /// The band just under the menu bar, in AppKit coordinates (origin
    /// bottom-left). `area` is the desktop area of a display — `visibleFrame`,
    /// not `frame`: the bar must not sit behind the menu bar.
    static func barFrame(in area: CGRect, height: CGFloat) -> CGRect {
        let height = max(1, height)
        return CGRect(x: area.minX, y: area.maxY - height,
                      width: area.width, height: height)
    }

    /// The band that starts the reveal: the whole menu bar where the display
    /// has one — the easiest edge to reach, and it never overlaps a window's
    /// buttons — or the top `minimum` points of the screen elsewhere.
    static func zone(for screen: CGRect, desktop: CGRect, minimum: CGFloat) -> CGRect {
        let menuBar = max(0, screen.maxY - desktop.maxY)
        let height = max(1, max(menuBar, minimum))
        return CGRect(x: screen.minX, y: screen.maxY - height,
                      width: screen.width, height: height)
    }

    // MARK: - State

    mutating func setPinned(_ pinned: Bool) {
        isPinned = pinned
        if pinned { leftBarAt = nil }
    }

    /// The user closed it (Esc, a click elsewhere, a command that opened a
    /// panel). If the pointer is still in the trigger band, wait for it to
    /// leave.
    mutating func dismiss(pointer: CGPoint, area: CGRect, zone: CGRect,
                          barHeight: CGFloat) {
        let bar = Self.barFrame(in: area, height: barHeight)
        waitsForExit = bar.contains(pointer) || zone.contains(pointer)
        isVisible = false
        enteredZoneAt = nil
        leftBarAt = nil
        sticky = false
    }

    /// A command or the menu asked for the bar: it is visible now, and it
    /// stays until the pointer has been on it once, after which the ordinary
    /// linger applies again.
    mutating func showNow() {
        isVisible = true
        enteredZoneAt = nil
        leftBarAt = nil
        waitsForExit = false
        sticky = true
    }

    /// A screen change, a full-screen space, the display going away: the bar
    /// cannot stay where it was.
    mutating func reset() {
        isVisible = false
        enteredZoneAt = nil
        leftBarAt = nil
        waitsForExit = false
        sticky = false
    }

    // MARK: - The decision

    mutating func update(pointer: CGPoint, area: CGRect, zone: CGRect,
                         barHeight: CGFloat,
                         pressed: Bool, suppressed: Bool, now: TimeInterval) -> Action {
        if suppressed {
            enteredZoneAt = nil
            leftBarAt = nil
            return isVisible ? hide() : .none
        }

        let bar = Self.barFrame(in: area, height: barHeight)
        let inZone = zone.contains(pointer)
        let inBar = bar.contains(pointer)

        if waitsForExit, !inZone, !inBar { waitsForExit = false }

        if isVisible {
            guard !isPinned else { return .none }
            // The trigger band counts as "on the bar": the pointer can rest in
            // the menu bar, decide, and only then move down onto the bar.
            if inBar || inZone {
                leftBarAt = nil
                sticky = false
            } else if sticky {
                return .none
            } else if let leftBarAt {
                if now - leftBarAt >= timings.linger { return hide() }
            } else {
                leftBarAt = now
            }
            return .none
        }

        // Hidden: a press is a drag or a click in progress, never a request.
        guard !pressed, !waitsForExit else {
            enteredZoneAt = nil
            return .none
        }

        guard inZone else {
            enteredZoneAt = nil
            return .none
        }
        guard let enteredZoneAt else {
            self.enteredZoneAt = now
            return .none
        }
        guard now - enteredZoneAt >= timings.dwell else { return .none }

        self.enteredZoneAt = nil
        leftBarAt = nil
        isVisible = true
        return .show
    }

    private mutating func hide() -> Action {
        isVisible = false
        enteredZoneAt = nil
        leftBarAt = nil
        sticky = false
        return .hide
    }
}

/// The text of the info values, kept away from the view so the formatting is
/// tested without a bar on screen (F3).
enum BarInfoText {
    static let empty = "—"

    static func disk(_ menuBarText: String?) -> String {
        guard let text = menuBarText, text.isEmpty == false else { return empty }
        return text
    }

    static func cpu(_ percent: Double?) -> String {
        guard let percent, percent.isFinite else { return empty }
        return "\(Int(percent.rounded()))%"
    }

    /// The nearest timer that is still running, as the overlay shows it.
    /// Paused timers are not "running" and stay out of the bar.
    static func timer(_ timers: [AppTimer], now: Date) -> String? {
        let running = timers
            .filter { $0.isPaused == false && $0.isDue(at: now) == false }
            .min { $0.remaining(at: now) < $1.remaining(at: now) }
        guard let running else { return nil }
        return TimerText.countdown(running.remaining(at: now))
    }

    static func windows(_ count: Int) -> String {
        "\(max(0, count))"
    }
}
