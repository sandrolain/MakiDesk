import AppKit

/// The modifier keys held while dragging a window to show the snap overlay.
///
/// `Control` is deliberately **excluded**: on macOS `⌃`-click is the secondary
/// click, so it opens context menus (e.g. on Finder windows). There is no clean
/// way to keep it for a drag gesture — suppressing the menu would need an active
/// event tap that breaks `⌃`-click everywhere.
///
/// The default is plain `⌥`, which is MakiDesk's replacement for the macOS
/// "Hold ⌥ while dragging windows to tile" behaviour (see `MacOSTiling`).
enum DragActivator: String, CaseIterable, Identifiable {
    case option
    case optionShift
    case optionCommand
    case commandShift
    case shift
    case command

    /// Shown when nothing has been chosen yet.
    static let fallback: DragActivator = .option

    var id: String { rawValue }

    var label: String {
        switch self {
        case .option: return "⌥ Option"
        case .optionShift: return "⌥⇧ Option + Shift"
        case .optionCommand: return "⌥⌘ Option + Command"
        case .commandShift: return "⌘⇧ Command + Shift"
        case .shift: return "⇧ Shift"
        case .command: return "⌘ Command"
        }
    }

    /// `true` for the activators that use `⌥` and therefore overlap with the
    /// macOS "hold ⌥ to tile" accelerator unless that is turned off.
    var usesOption: Bool {
        switch self {
        case .option, .optionShift, .optionCommand: return true
        case .commandShift, .shift, .command: return false
        }
    }

    /// `true` when the given modifiers satisfy this activator. Extra modifiers
    /// are allowed, but `⌃` is **never** accepted: with Control held the click
    /// would open a context menu anyway, so we must not treat it as a drag.
    func matches(_ flags: NSEvent.ModifierFlags) -> Bool {
        guard !flags.contains(.control) else { return false }
        switch self {
        case .option: return flags.contains(.option)
        case .optionShift: return flags.contains(.option) && flags.contains(.shift)
        case .optionCommand: return flags.contains(.option) && flags.contains(.command)
        case .commandShift: return flags.contains(.command) && flags.contains(.shift)
        case .shift: return flags.contains(.shift)
        case .command: return flags.contains(.command)
        }
    }
}
