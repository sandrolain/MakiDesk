import CoreGraphics
import Foundation

/// Which way a keyboard shortcut asks the focus to move (F4 keyboard polish).
public enum PaneFocusDirection: String, CaseIterable, Sendable {
    case left
    case right
    case up
    case down
}

/// Directional focus for split panes, independent of the split tree.
///
/// The window controller already knows every visible pane's frame, so the
/// neighbour is the closest pane whose centre lies in the requested half-plane.
/// Sorting by the gap along the axis first and the offset across it second
/// makes a 2×2 layout behave the way the eye expects: moving right from the
/// top-left pane reaches the top-right one, not the diagonally opposite one.
public enum TerminalPaneNavigation {
    public static func neighbor(of pane: PaneID,
                                in frames: [PaneID: CGRect],
                                direction: PaneFocusDirection) -> PaneID? {
        guard let current = frames[pane], current.width > 0, current.height > 0 else {
            return nil
        }
        let origin = CGPoint(x: current.midX, y: current.midY)
        var best: (pane: PaneID, gap: CGFloat, offAxis: CGFloat)?

        for (candidate, frame) in frames where candidate != pane {
            guard frame.width > 0, frame.height > 0 else { continue }
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            let gap: CGFloat
            let offAxis: CGFloat
            switch direction {
            case .left:
                gap = origin.x - centre.x
                offAxis = abs(origin.y - centre.y)
            case .right:
                gap = centre.x - origin.x
                offAxis = abs(origin.y - centre.y)
            case .up:
                gap = centre.y - origin.y
                offAxis = abs(origin.x - centre.x)
            case .down:
                gap = origin.y - centre.y
                offAxis = abs(origin.x - centre.x)
            }
            guard gap > 0 else { continue }
            if let best {
                if (gap, offAxis) > (best.gap, best.offAxis) { continue }
                if (gap, offAxis) == (best.gap, best.offAxis),
                   candidate.description >= best.pane.description {
                    continue
                }
            }
            best = (candidate, gap, offAxis)
        }
        return best?.pane
    }
}
