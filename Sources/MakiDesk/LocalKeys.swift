import Foundation

/// A key that works inside a panel, named by what it does (S03).
///
/// These are not Carbon hot keys and are never remapped: they belong to the
/// panel that owns the keyboard. The point of naming them is the vocabulary —
/// the same verb always means the same combination, so the catalog cannot say
/// `Esc` for one panel and something else for another, and a test can check
/// that every panel can be dismissed.
enum LocalKey: String, CaseIterable, Sendable {
    /// Open, paste, run: the key that commits the highlight.
    case accept
    /// The same, in a new instance or a new window.
    case acceptNew
    /// Close and give the keyboard back.
    case cancel
    /// Take the selected item out of the panel.
    case remove
    /// Look at the item without leaving.
    case preview
    /// Take every item at once.
    case selectAll
    /// Jump to slot 1…9.
    case chooseSlot
    /// Add or remove slot 1…9.
    case toggleSlot

    var keys: String {
        switch self {
        case .accept: return "↩"
        case .acceptNew: return "⌘↩"
        case .cancel: return "Esc"
        case .remove: return "⌫"
        case .preview: return "Space"
        case .selectAll: return "⌘A"
        case .chooseSlot: return "⌘1…9"
        case .toggleSlot: return "⌥1…9"
        }
    }
}
