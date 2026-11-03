import AppKit

/// The utility bar's window (F1).
///
/// `passive` in `FloatingPanel`'s vocabulary, with one exception: when the user
/// opens it from the keyboard it has to take the keys, so the panel says so
/// explicitly instead of relying on a second style.
final class UtilityBarPanel: FloatingPanel {
    override class var style: FloatingPanel.Style { .passive }

    /// Set only while the bar was opened with ⌃⌥B.
    var isKeyboardDriven = false

    override var canBecomeKey: Bool { isKeyboardDriven }
    override var canBecomeMain: Bool { false }
}
