import CoreGraphics
import Foundation

/// Policy for the focus dim (T62): which displays are veiled and which window
/// the veil anchors under.
///
/// The veil is a full-display panel ordered **below** the window that must stay
/// sharp. Nothing is measured per window, so moving or resizing that window
/// needs no update at all: the relationship is the stacking order, not a set of
/// coordinates. These rules are plain values so they can be checked without a
/// window server.
enum FocusDim {
    /// What stays sharp.
    enum Source: String, CaseIterable, Identifiable {
        /// The focused window alone.
        case window
        /// Every window of the frontmost app, anchored below its lowest one.
        case application

        var id: String { rawValue }

        var label: String {
            switch self {
            case .window: return "Focused window"
            case .application: return "Whole app"
            }
        }
    }

    /// Which displays stay lit.
    enum DisplayMode: String, CaseIterable, Identifiable {
        /// Each display highlights the topmost window it holds.
        case independent
        /// Only the display of the focused window is lit; the others go dark.
        case single

        var id: String { rawValue }

        var label: String {
            switch self {
            case .independent: return "Every display"
            case .single: return "Only the active display"
            }
        }
    }

    /// The veil only ever takes light away, so every choice is dark.
    enum Colour: String, CaseIterable, Identifiable {
        case black
        case graphite
        case slate

        var id: String { rawValue }

        var label: String {
            switch self {
            case .black: return "Black"
            case .graphite: return "Graphite"
            case .slate: return "Slate"
            }
        }

        /// sRGB components, 0…1.
        var components: (red: CGFloat, green: CGFloat, blue: CGFloat) {
            switch self {
            case .black: return (0, 0, 0)
            case .graphite: return (0.11, 0.11, 0.12)
            case .slate: return (0.07, 0.10, 0.14)
            }
        }
    }

    /// One display, in the window server's top-left coordinates.
    struct Screen: Equatable {
        let id: CGDirectDisplayID
        let frame: CGRect
    }

    /// Where one display's veil goes: `anchor` is the window it is ordered
    /// below, `nil` when the whole display is dimmed.
    struct Placement: Equatable {
        let display: CGDirectDisplayID
        let anchor: CGWindowID?
    }

    static let opacityRange: ClosedRange<Double> = 0.1...0.8
    static let defaultOpacity = 0.55
    static let fadeRange: ClosedRange<Double> = 0...0.5
    static let defaultFade = 0.15

    /// Below this, a window is a status item, a drag image or a shadow helper,
    /// not something to keep sharp.
    static let minimumWindowSize = CGSize(width: 40, height: 40)

    static func clampedOpacity(_ value: Double) -> Double {
        min(max(value, opacityRange.lowerBound), opacityRange.upperBound)
    }

    static func clampedFade(_ value: Double) -> Double {
        min(max(value, fadeRange.lowerBound), fadeRange.upperBound)
    }

    /// The panel's alpha. Reduce Transparency turns the veil into a solid
    /// surface, as the system does with its own materials.
    static func alpha(opacity: Double, reduceTransparency: Bool) -> CGFloat {
        reduceTransparency ? 1 : CGFloat(clampedOpacity(opacity))
    }

    /// Whether the veil sits **above** its anchor and must be moved back under
    /// it. A panel that drifted further down only dims more windows, which is
    /// the intended result, so it is left alone.
    static func needsReorder(panel: Int, anchor: Int) -> Bool {
        panel < anchor
    }

    /// The display a frame belongs to: the largest intersection, so a window
    /// straddling two displays keeps the one it mostly covers.
    static func display(of frame: CGRect, in screens: [Screen]) -> CGDirectDisplayID? {
        var best: (area: CGFloat, id: CGDirectDisplayID)?
        for screen in screens {
            let overlap = screen.frame.intersection(frame)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            let area = overlap.width * overlap.height
            if best == nil || area > best!.area {
                best = (area, screen.id)
            }
        }
        return best?.id
    }

    /// The window a display's veil goes under: its topmost ordinary window,
    /// which is what the user is looking at there.
    static func topmostWindow(on display: CGRect, stack: [WindowController.CGWindowEntry],
                              ownPID: pid_t) -> CGWindowID? {
        topmostIndex(on: display, stack: stack, ownPID: ownPID).map { stack[$0].number }
    }

    /// The stacking index of the topmost ordinary window on a display, for the
    /// drift check that keeps a fully dimmed display above its windows.
    static func topmostIndex(on display: CGRect, stack: [WindowController.CGWindowEntry],
                             ownPID: pid_t) -> Int? {
        stack.firstIndex { isCandidate($0, ownPID: ownPID) && overlaps($0.frame, display) }
    }

    /// The lowest window of `pid` on a display: anchoring under it keeps the
    /// whole app sharp.
    static func lowestWindow(of pid: pid_t, on display: CGRect,
                             stack: [WindowController.CGWindowEntry],
                             ownPID: pid_t) -> CGWindowID? {
        var found: CGWindowID?
        for entry in stack where entry.pid == pid && isCandidate(entry, ownPID: ownPID) {
            guard overlaps(entry.frame, display) else { continue }
            found = entry.number
        }
        return found
    }

    /// The frontmost window of `pid`, used when Accessibility cannot name the
    /// focused one.
    static func topmostWindow(of pid: pid_t, in stack: [WindowController.CGWindowEntry]) -> CGWindowID? {
        stack.first { $0.pid == pid && $0.layer == 0
            && $0.frame.width >= minimumWindowSize.width
            && $0.frame.height >= minimumWindowSize.height }?.number
    }

    /// One placement per display.
    ///
    /// `focused` is the window to keep sharp (the focused one, or the
    /// window-server fallback); `focusedPID` is the app it belongs to.
    static func plan(screens: [Screen], stack: [WindowController.CGWindowEntry],
                     focused: CGWindowID?, focusedPID: pid_t?,
                     source: Source, mode: DisplayMode, ownPID: pid_t) -> [Placement] {
        guard !screens.isEmpty else { return [] }
        let focusedFrame = focused.flatMap { id in
            stack.first { $0.number == id }?.frame
        }
        let lit: Set<CGDirectDisplayID>
        switch mode {
        case .independent:
            lit = Set(screens.map(\.id))
        case .single:
            if let focusedFrame {
                let touching = screens.filter { overlaps($0.frame, focusedFrame) }.map(\.id)
                if touching.isEmpty {
                    lit = display(of: focusedFrame, in: screens).map { [$0] } ?? []
                } else {
                    lit = Set(touching)
                }
            } else {
                lit = []
            }
        }

        return screens.map { screen in
            guard lit.contains(screen.id) else {
                return Placement(display: screen.id, anchor: nil)
            }
            let anchor: CGWindowID?
            switch source {
            case .window:
                if mode == .independent {
                    anchor = topmostWindow(on: screen.frame, stack: stack, ownPID: ownPID)
                } else {
                    anchor = focused ?? focusedPID.flatMap { topmostWindow(of: $0, in: stack) }
                }
            case .application:
                anchor = focusedPID.flatMap {
                    lowestWindow(of: $0, on: screen.frame, stack: stack, ownPID: ownPID)
                }
            }
            return Placement(display: screen.id, anchor: anchor)
        }
    }

    private static func isCandidate(_ entry: WindowController.CGWindowEntry, ownPID: pid_t) -> Bool {
        entry.pid != ownPID
            && entry.layer == 0
            && entry.alpha > 0.01
            && entry.frame.width >= minimumWindowSize.width
            && entry.frame.height >= minimumWindowSize.height
    }

    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = a.intersection(b)
        return !overlap.isNull && overlap.width >= 1 && overlap.height >= 1
    }
}
