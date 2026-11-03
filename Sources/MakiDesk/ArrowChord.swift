import AppKit
import Carbon.HIToolbox

/// The chord that spans a window on one axis (S03): hold ⌃⌥ and both arrows of
/// a pair — ↑+↓ for the full height, ←+→ for the full width.
///
/// A Carbon hot key carries one key, so the chord is completed by the second
/// arrow of the pair: when the command fires, the partner's physical key is
/// already down. The two rows of the pair must still carry their default
/// combinations; a remapped or disabled arrow turns the chord off, so a key
/// nobody expects can never stretch a window.
enum ArrowChord {
    struct Member {
        /// The row the incoming command belongs to.
        let rowID: String
        /// The physical key that, held down, completes the chord.
        let partnerKey: Int
        let axis: TilingEngine.Axis
    }

    static func member(for action: WindowController.ShortcutAction) -> Member? {
        switch action {
        case .leftHalf:
            return Member(rowID: "window.left", partnerKey: kVK_RightArrow,
                          axis: .horizontal)
        case .rightHalf:
            return Member(rowID: "window.right", partnerKey: kVK_LeftArrow,
                          axis: .horizontal)
        case .topHalf:
            return Member(rowID: "window.top", partnerKey: kVK_DownArrow,
                          axis: .vertical)
        case .bottomHalf:
            return Member(rowID: "window.bottom", partnerKey: kVK_UpArrow,
                          axis: .vertical)
        default:
            return nil
        }
    }

    /// The pair's rows, in table order.
    static func rowIDs(for axis: TilingEngine.Axis) -> [String] {
        axis == .horizontal ? ["window.left", "window.right"]
                            : ["window.top", "window.bottom"]
    }

    /// Both rows of the pair still carry their default combination.
    static func isIntact(_ axis: TilingEngine.Axis, in bindings: ShortcutBindings) -> Bool {
        rowIDs(for: axis).allSatisfy { id in
            guard let wanted = ShortcutBindings.defaultTable[id] else { return false }
            return bindings.binding(for: id)?.normalized == wanted.normalized
        }
    }

    /// The axis to span, or `nil` when this is an ordinary arrow command.
    /// `isKeyDown` is injected so the rule is tested without a keyboard.
    static func axis(for action: WindowController.ShortcutAction,
                     bindings: ShortcutBindings,
                     isKeyDown: (Int) -> Bool = systemKeyIsDown) -> TilingEngine.Axis? {
        guard let member = member(for: action),
              isIntact(member.axis, in: bindings),
              isKeyDown(member.partnerKey) else { return nil }
        return member.axis
    }

    /// The keyboard's own state: no event tap, no Input Monitoring permission.
    static func systemKeyIsDown(_ key: Int) -> Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key))
    }
}
