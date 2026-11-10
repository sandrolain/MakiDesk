import CoreGraphics
import Foundation

/// The questions the command dispatcher asks about a shortcut, answered
/// without a window (R01).
///
/// They used to live in the middle of `WorkspaceStore`, three of its five
/// `switch` statements over the same enum. Being private and surrounded by
/// state, they could only be tested by driving the whole store — so they were
/// not tested at all, and a new command silently landed in the `default` arm.
/// Here they are pure: a command goes in, a number or a rectangle comes out.
enum CommandRouter {
    /// Which way a ladder command moves: `.leftHalf` is the horizontal axis,
    /// backwards. `nil` for a command that is not a half.
    static func axisAndDirection(
        for action: WindowController.ShortcutAction
    ) -> (TilingEngine.Axis, Int)? {
        switch action {
        case .leftHalf: return (.horizontal, -1)
        case .rightHalf: return (.horizontal, 1)
        case .topHalf: return (.vertical, -1)
        case .bottomHalf: return (.vertical, 1)
        default: return nil
        }
    }

    /// The frame a command wants, or `nil` when the command is not about
    /// geometry. The halves are `nil` on purpose: they are a ladder, and the
    /// ladder owns them.
    static func logicalFrame(
        for action: WindowController.ShortcutAction,
        area: CGRect,
        current: CGRect
    ) -> CGRect? {
        switch action {
        case .topLeft:
            return TilingEngine.regionRect(area: area,
                                           relative: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        case .topRight:
            return TilingEngine.regionRect(area: area,
                                           relative: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        case .bottomLeft:
            return TilingEngine.regionRect(area: area,
                                           relative: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
        case .bottomRight:
            return TilingEngine.regionRect(area: area,
                                           relative: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        case .centerCycle:
            // Two states only: full screen ↔ golden-centred.
            return framesMatch(current, area) ? cycleGoldenFrame(area: area) : area
        case .center:
            let width = min(current.width, area.width)
            let height = min(current.height, area.height)
            return CGRect(x: area.midX - width / 2, y: area.midY - height / 2,
                          width: width, height: height)
        case .phi:
            return goldenFrame(area: area)
        default:
            return nil
        }
    }

    /// The golden rectangle inside `area`, centred and kept square-ish by φ.
    static func goldenFrame(area: CGRect) -> CGRect {
        let width = min(area.width, area.height * TilingEngine.phi)
        let height = min(area.height, area.width / TilingEngine.phi)
        return CGRect(x: area.midX - width / 2, y: area.midY - height / 2,
                      width: width, height: height)
    }

    /// Golden-ratio reduction of the full-screen size, centred (0.618 × 0.618).
    static func cycleGoldenFrame(area: CGRect) -> CGRect {
        let width = area.width / TilingEngine.phi
        let height = area.height / TilingEngine.phi
        return CGRect(x: area.midX - width / 2, y: area.midY - height / 2,
                      width: width, height: height)
    }

    /// AX writes are rounded by the app and by the display: within 12 pt the two
    /// frames are the same arrangement, which is what the cycle must not undo.
    static func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 12 && abs(a.minY - b.minY) < 12
            && abs(a.width - b.width) < 12 && abs(a.height - b.height) < 12
    }

    /// The word that goes into the status line and the frame log. Not a UI
    /// string: it is the shortest name the command has.
    static func label(for action: WindowController.ShortcutAction) -> String {
        switch action {
        case .leftHalf: return "left column"
        case .rightHalf: return "right column"
        case .topHalf: return "top row"
        case .bottomHalf: return "bottom row"
        case .topLeft: return "top-left quarter"
        case .topRight: return "top-right quarter"
        case .bottomLeft: return "bottom-left quarter"
        case .bottomRight: return "bottom-right quarter"
        case .centerCycle: return "center cycle"
        case .center: return "centered"
        case .phi: return "golden ratio"
        case .toggleFullScreen: return "full screen"
        case .minimize: return "minimized"
        case .switchWindows, .switchWindowsBack: return "switch"
        case .searchWindows: return "search"
        case .assignToGroup, .recallGroup: return "group"
        case .toggleNotes: return "notes"
        case .clipboardHistory: return "clipboard"
        case .toggleShelf: return "shelf"
        case .recognizeText: return "text"
        case .sampleColor: return "colour"
        case .measureArea: return "measure"
        case .openSettings: return "settings"
        case .openKeyboardShortcuts: return "shortcuts"
        case .openScreenshots: return "screenshots"
        case .openPorts: return "ports"
        case .toggleFocusBorder: return "focus border"
        case .toggleFocusDim: return "focus dim"
        case .toggleChecklist: return "checklist"
        case .toggleUtilityBar: return "utility bar"
        case .openTerminal: return "terminal"
        case .toggleTerminalQuake: return "terminal quake"
        case .openDocker: return "docker"
        case .newTimer: return "timer"
        case .captureScreenshot: return "screenshot"
        case .captureWindow: return "window"
        case .captureScreen: return "screen"
        case .recordArea: return "recording"
        case .runCommand: return "command"
        case .toggleMiniMap: return "mini map"
        case .locatePointer: return "pointer"
        case .togglePointerEffects: return "pointer effects"
        case .focusSelection: return "focus selection"
        case .leaveGroup: return "left group"
        case .clearPeek: return "peek cleared"
        case .applySuggestedLayout: return "suggested layout"
        case .peekDesignate: return "peek"
        case .putAwayFront: return "sent away"
        case .showEverything: return "everything back"
        case .undoStep: return "undone"
        case .gridLayout: return "grid layout"
        case .spiralLayout: return "golden spiral"
        case .suggestLayout: return "suggested layout"
        case .contentLayout: return "content layout"
        }
    }
}
