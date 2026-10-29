import Foundation

/// A command the box can run (T38).
///
/// The catalogue is the one place the phrases live. Everything it offers maps on
/// to a MakiDesk action that already exists — the same dispatch the menu and the
/// keyboard use — so a command and a menu row cannot drift apart.
struct CommandEntry: Identifiable, Equatable {
    /// What the user types, and the identity: "tile left", "group".
    let id: String
    /// One line for the suggestion list.
    let summary: String
    let action: CommandAction
    let argument: Argument?

    /// The values an entry accepts after its phrase.
    enum Argument: Equatable {
        /// A group slot, 1…9.
        case groupSlot
        /// A length or a time of day, read by `TimerText` ("25m", "8:30").
        case timer

        var hint: String {
            switch self {
            case .groupSlot: return "1…9"
            case .timer: return "25m · 8:30"
            }
        }
    }
}

/// What a phrase does. Values, so the catalogue can be checked without running
/// anything.
enum CommandAction: Equatable {
    case shortcut(WindowController.ShortcutAction)
    case recallGroup
    case toggleGroupMembership
    case timer
    case dismissNotices
}

/// Parsing and suggestions, kept pure: typing a command and choosing from the
/// list are decisions that can be tested without a panel.
enum CommandCatalog {
    static let entries: [CommandEntry] = [
        // The window in front
        entry("tile left", "Put the front window in the left column", .shortcut(.leftHalf)),
        entry("tile right", "Put the front window in the right column", .shortcut(.rightHalf)),
        entry("tile top", "Put the front window in the top row", .shortcut(.topHalf)),
        entry("tile bottom", "Put the front window in the bottom row", .shortcut(.bottomHalf)),
        entry("tile top left", "Front window in the top-left quarter", .shortcut(.topLeft)),
        entry("tile top right", "Front window in the top-right quarter", .shortcut(.topRight)),
        entry("tile bottom left", "Front window in the bottom-left quarter", .shortcut(.bottomLeft)),
        entry("tile bottom right", "Front window in the bottom-right quarter", .shortcut(.bottomRight)),
        entry("center", "Centre the front window", .shortcut(.center)),
        entry("golden", "Golden-ratio position", .shortcut(.phi)),
        entry("full screen", "Toggle full screen", .shortcut(.toggleFullScreen)),
        entry("minimize", "Minimise the front window", .shortcut(.minimize)),
        // Layouts
        entry("layout grid", "Grid with every window in view", .shortcut(.gridLayout)),
        entry("layout spiral", "Golden spiral with every window in view", .shortcut(.spiralLayout)),
        entry("layout suggested", "Let the advisor choose and explain", .shortcut(.suggestLayout)),
        entry("layout content", "Areas follow what each window shows", .shortcut(.contentLayout)),
        // Groups
        entry("group", "Recall a group", .recallGroup, argument: .groupSlot),
        entry("add group", "Add or remove the front window from a group",
              .toggleGroupMembership, argument: .groupSlot),
        entry("leave group", "Leave the group in use", .shortcut(.leaveGroup)),
        entry("everything back", "Bring back what was put away", .shortcut(.showEverything)),
        entry("undo", "Undo one focus step", .shortcut(.undoStep)),
        entry("focus selection", "Focus the windows ticked in the switcher", .shortcut(.focusSelection)),
        // Panels
        entry("notes", "Open the notes panel", .shortcut(.toggleNotes)),
        entry("clipboard", "Open the clipboard history", .shortcut(.clipboardHistory)),
        entry("shelf", "Open the shelf", .shortcut(.toggleShelf)),
        entry("switcher", "Open the window switcher", .shortcut(.switchWindows)),
        entry("search", "Search windows and applications", .shortcut(.searchWindows)),
        entry("checklist", "Show or hide the checklist", .shortcut(.toggleChecklist)),
        entry("settings", "Open Settings", .shortcut(.openSettings)),
        entry("shortcuts", "Open the keyboard shortcuts", .shortcut(.openKeyboardShortcuts)),
        entry("screenshots", "Open the screenshot library", .shortcut(.openScreenshots)),
        // Capture and measuring
        entry("screenshot", "Capture an area and annotate it", .shortcut(.captureScreenshot)),
        entry("ocr", "Read text from a selected area", .shortcut(.recognizeText)),
        entry("measure", "Measure an area of the screen", .shortcut(.measureArea)),
        entry("colour", "Pick a colour from the screen", .shortcut(.sampleColor)),
        // Presentation
        entry("minimap", "Show or hide the mini map", .shortcut(.toggleMiniMap)),
        entry("focus border", "Show or hide the focus border", .shortcut(.toggleFocusBorder)),
        entry("focus dim", "Dim everything outside the front window", .shortcut(.toggleFocusDim)),
        // Peek
        entry("peek", "Designate the front window for the peek", .shortcut(.peekDesignate)),
        entry("clear peek", "Remove the peek designation", .shortcut(.clearPeek)),
        // Timers and notices
        entry("timer", "Start a countdown or a timer until a time", .timer, argument: .timer),
        entry("dismiss notices", "Take every notice away", .dismissNotices)
    ]

    private static func entry(_ phrase: String, _ summary: String,
                              _ action: CommandAction,
                              argument: CommandEntry.Argument? = nil) -> CommandEntry {
        CommandEntry(id: phrase, summary: summary, action: action, argument: argument)
    }

    /// Lowercase, one space between words, no ends.
    static func normalized(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .joined(separator: " ")
    }

    /// The command `text` names and the argument that follows it, if any.
    ///
    /// The longest phrase that matches wins, so "tile left" is not read as "tile"
    /// with a stray word, and a phrase that takes no argument refuses one.
    static func match(_ text: String) -> (entry: CommandEntry, argument: String)? {
        let typed = normalized(text)
        guard typed.isEmpty == false else { return nil }
        var best: (entry: CommandEntry, argument: String)?
        for entry in entries {
            let phrase = normalized(entry.id)
            guard typed == phrase || typed.hasPrefix(phrase + " ") else { continue }
            let rest = String(typed.dropFirst(phrase.count))
                .trimmingCharacters(in: .whitespaces)
            if entry.argument == nil, rest.isEmpty == false { continue }
            if best == nil || phrase.count > normalized(best!.entry.id).count {
                best = (entry, rest)
            }
        }
        return best
    }

    /// The entries worth showing for what has been typed: phrase starts first,
    /// then any phrase whose words all match.
    ///
    /// Each group keeps the catalogue's own order, which follows the menu —
    /// left, right, top, bottom — instead of the alphabet or the length, so the
    /// list does not shuffle while a word is being typed.
    static func suggestions(for text: String, limit: Int = 7) -> [CommandEntry] {
        let typed = normalized(text)
        guard typed.isEmpty == false else { return Array(entries.prefix(limit)) }
        let words = typed.split(separator: " ").map(String.init)
        let prefixed = entries.filter { normalized($0.id).hasPrefix(typed) }
        let rest = entries.filter { entry in
            let phrase = normalized(entry.id)
            guard phrase.hasPrefix(typed) == false else { return false }
            return words.allSatisfy { word in
                phrase.split(separator: " ").contains { $0.hasPrefix(word) }
            }
        }
        return Array((prefixed + rest).prefix(limit))
    }

    /// Whether the argument can be used, and the value to hand the action.
    static func validated(_ entry: CommandEntry, argument: String) -> String? {
        guard let rule = entry.argument else {
            return argument.isEmpty ? "" : nil
        }
        switch rule {
        case .groupSlot:
            guard let slot = Int(argument), (1...9).contains(slot) else { return nil }
            return String(slot)
        case .timer:
            guard TimerText.parse(argument) != nil else { return nil }
            return argument
        }
    }

    /// The phrase completed with its argument hint, for the suggestion list.
    static func display(_ entry: CommandEntry) -> String {
        guard let argument = entry.argument else { return entry.id }
        return "\(entry.id) \(argument.hint)"
    }
}
