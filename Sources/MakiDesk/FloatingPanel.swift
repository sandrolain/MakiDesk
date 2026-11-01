import AppKit

/// The panel behaviours the app kept spelling out (R03).
///
/// Every `NSPanel` subclass here answered the same three questions — does it
/// take the keyboard, may AppKit move it, does Esc reach anything — and answered
/// them by overriding the same members. Written that way, a line someone forgot
/// looks exactly like a line someone chose to leave out: `canBecomeKey` false on
/// a panel that needs typing is a silent bug, not a compile error.
///
/// A subclass now names its style and nothing else; anything else it overrides
/// is a deliberate difference.
class FloatingPanel: NSPanel {
    struct Style {
        /// Takes the keyboard: it can be typed in.
        var becomesKey: Bool
        /// AppKit may keep the panel inside the visible frame. Off for overlays
        /// that are placed deliberately, across displays.
        var confinesToScreen: Bool

        /// A card the user types in, kept on screen.
        static let utility = Style(becomesKey: true, confinesToScreen: true)
        /// Takes the keyboard, but is placed by its own controller.
        static let keyOverlay = Style(becomesKey: true, confinesToScreen: false)
        /// Never takes the keyboard: a veil, or a read-only card.
        static let passive = Style(becomesKey: false, confinesToScreen: false)
        /// Never takes the keyboard, but stays on screen.
        static let readOnly = Style(becomesKey: false, confinesToScreen: true)
    }

    /// The panel's style. The one thing a subclass states.
    class var style: Style { .utility }

    /// Esc: set by the panels that close on it. `nil` leaves Esc to AppKit,
    /// which is what a panel with nothing to cancel wants.
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { Self.style.becomesKey }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        Self.style.confinesToScreen ? super.constrainFrameRect(frameRect, to: screen) : frameRect
    }

    override func cancelOperation(_ sender: Any?) {
        if let onCancel {
            onCancel()
            return
        }
        super.cancelOperation(sender)
    }
}
