import Carbon.HIToolbox
import Foundation

/// One row of the only shortcut table (T53): the Carbon hot key, the command it
/// runs, where it appears in the catalog and the rule it belongs to.
///
/// Rows with no key are informational (`⌥` + drag, the peek hold) and are not
/// registered: they explain a gesture the panels already handle.
struct ShortcutDefinition: Identifiable {
    let id: String
    let title: String
    let section: String
    let note: String?
    let keyCode: Int?
    let modifiers: Int
    let action: WindowController.ShortcutAction?
    let displayOverride: String?

    var display: String {
        if let displayOverride { return displayOverride }
        guard let keyCode else { return "" }
        return ShortcutDisplay.string(keyCode: keyCode, modifiers: modifiers)
    }

    var isGlobal: Bool { action != nil && keyCode != nil }
}

struct ShortcutSectionDefinition {
    let title: String
    let note: String?
    let definitions: [ShortcutDefinition]
}

/// Renders Carbon key codes and modifier masks for the menus and the catalog.
enum ShortcutDisplay {
    static func string(keyCode: Int, modifiers: Int) -> String {
        modifiersString(modifiers) + keyString(keyCode)
    }

    static func modifiersString(_ modifiers: Int) -> String {
        var text = ""
        if modifiers & controlKey != 0 { text += "⌃" }
        if modifiers & optionKey != 0 { text += "⌥" }
        if modifiers & shiftKey != 0 { text += "⇧" }
        if modifiers & cmdKey != 0 { text += "⌘" }
        return text
    }

    static func keyString(_ keyCode: Int) -> String {
        switch keyCode {
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Escape: return "Esc"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_Grave: return "`"
        case kVK_ANSI_KeypadEnter: return "⌤"
        default:
            return letters[keyCode] ?? digits[keyCode] ?? "Key \(keyCode)"
        }
    }

    private static let letters: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
    ]

    private static let digits: [Int: String] = [
        kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8",
        kVK_ANSI_9: "9", kVK_ANSI_0: "0",
    ]
}

/// The default table. Every global row is registered from here; the catalog is
/// generated from the same rows, so the two cannot drift (T53).
enum ShortcutDefinitions {
    static let ctrlOpt = controlKey | optionKey
    static let ctrlOptShift = ctrlOpt | shiftKey
    static let ctrlOptCmd = ctrlOpt | cmdKey

    static let sections: [ShortcutSectionDefinition] = [
        ShortcutSectionDefinition(title: "Window", note: "The menu also has the selected-window layouts.", definitions: window),
        ShortcutSectionDefinition(title: "Layouts", note: nil, definitions: layouts),
        ShortcutSectionDefinition(title: "Panels", note: "⌥ opens a panel; ⌃⌥ acts on windows and the desktop.", definitions: panels),
        ShortcutSectionDefinition(title: "Focus", note: "What leaves the screen is per window, and undoable.", definitions: focus),
        ShortcutSectionDefinition(title: "Groups", note: "⇧ recalls a group; ⌘ adds or removes the front window.", definitions: groups),
        ShortcutSectionDefinition(title: "Timers", note: "A length with a unit, or a time of day with a colon.", definitions: timers),
        ShortcutSectionDefinition(title: "Peek", note: "The designated window is put away; the hold brings it back.", definitions: peek),
        ShortcutSectionDefinition(title: "Text & colour", note: nil, definitions: capture),
        ShortcutSectionDefinition(title: "Screenshots", note: "The capture goes to the shelf.", definitions: screenshots),
        ShortcutSectionDefinition(title: "Measure", note: "Or drag with ⌥ from the centre; the pinned badge copies the values.", definitions: measure),
        ShortcutSectionDefinition(title: "App", note: "No global Quit: ⌥⇧Q stays inside the window switcher.", definitions: app),
    ]

    static let all: [ShortcutDefinition] = sections.flatMap(\.definitions)

    /// The rows that own a Carbon hot key; the others explain a gesture.
    static let global: [ShortcutDefinition] = all.filter(\.isGlobal)

    /// Lookup by stable id, used by the remapping table and the recorder. Built
    /// without `uniqueKeysWithValues` so a duplicate id can never crash at
    /// launch; a test still fails on duplicates.
    static func definition(id: String) -> ShortcutDefinition? {
        byID[id]
    }

    private static let byID: [String: ShortcutDefinition] = {
        var table: [String: ShortcutDefinition] = [:]
        for definition in all where table[definition.id] == nil {
            table[definition.id] = definition
        }
        return table
    }()

    private static func def(_ id: String, _ title: String, section: String,
                            key: Int, modifiers: Int = ctrlOpt,
                            action: WindowController.ShortcutAction,
                            note: String? = nil) -> ShortcutDefinition {
        ShortcutDefinition(id: id, title: title, section: section, note: note,
                           keyCode: key, modifiers: modifiers, action: action,
                           displayOverride: nil)
    }

    private static func info(_ id: String, _ title: String, section: String,
                             keys: String, note: String? = nil) -> ShortcutDefinition {
        ShortcutDefinition(id: id, title: title, section: section, note: note,
                           keyCode: nil, modifiers: 0, action: nil,
                           displayOverride: keys)
    }

    private static let window: [ShortcutDefinition] = [
        def("window.left", "Left column", section: "Window", key: kVK_LeftArrow, action: .leftHalf),
        def("window.right", "Right column", section: "Window", key: kVK_RightArrow, action: .rightHalf),
        def("window.top", "Top row", section: "Window", key: kVK_UpArrow, action: .topHalf),
        def("window.bottom", "Bottom row", section: "Window", key: kVK_DownArrow, action: .bottomHalf),
        def("window.topLeft", "Top-left quarter", section: "Window", key: kVK_ANSI_U, action: .topLeft),
        def("window.topRight", "Top-right quarter", section: "Window", key: kVK_ANSI_I, action: .topRight),
        def("window.bottomLeft", "Bottom-left quarter", section: "Window", key: kVK_ANSI_J, action: .bottomLeft),
        def("window.bottomRight", "Bottom-right quarter", section: "Window", key: kVK_ANSI_K, action: .bottomRight),
        def("window.cycle", "Center / full / golden — cycle", section: "Window", key: kVK_Return, action: .centerCycle),
        def("window.center", "Center", section: "Window", key: kVK_ANSI_C, action: .center),
        def("window.phi", "Golden ratio (φ)", section: "Window", key: kVK_ANSI_P, action: .phi),
        def("window.fullScreen", "Toggle full screen", section: "Window", key: kVK_ANSI_F, action: .toggleFullScreen),
        def("window.minimize", "Minimize", section: "Window", key: kVK_ANSI_M, action: .minimize),
        info("window.snap", "Snap while dragging", section: "Window", keys: "⌥ + drag",
             note: "The key is chosen in Settings ▸ Placement; ⌥ is the default. The gesture can be turned off there."),
    ]

    private static let layouts: [ShortcutDefinition] = [
        def("layout.grid", "Grid — every window in view", section: "Layouts", key: kVK_ANSI_G, action: .gridLayout),
        def("layout.spiral", "Golden spiral — every window in view", section: "Layouts", key: kVK_ANSI_S, action: .spiralLayout),
        def("layout.suggest", "Suggested layout", section: "Layouts", key: kVK_ANSI_A, action: .suggestLayout,
            note: "With “Ask before using” on, the advice waits for a second press."),
        def("layout.content", "Content-weighted — areas follow the content", section: "Layouts", key: kVK_ANSI_W,
            action: .contentLayout,
            note: "Needs at least three windows. Without Screen Recording it follows the app-kind weights from Settings."),
    ]

    private static let panels: [ShortcutDefinition] = [
        def("panel.switcher", "Window switcher", section: "Panels", key: kVK_Tab, modifiers: optionKey, action: .switchWindows),
        def("panel.switcherBack", "Window switcher — backwards", section: "Panels", key: kVK_Tab,
            modifiers: optionKey | shiftKey, action: .switchWindowsBack),
        def("panel.search", "Search windows and applications", section: "Panels", key: kVK_Space,
            modifiers: optionKey, action: .searchWindows),
        def("panel.notes", "Notes", section: "Panels", key: kVK_ANSI_N, modifiers: optionKey, action: .toggleNotes),
        def("panel.clipboard", "Clipboard history", section: "Panels", key: kVK_ANSI_V, modifiers: optionKey, action: .clipboardHistory),
        def("panel.shelf", "Shelf", section: "Panels", key: kVK_ANSI_D, action: .toggleShelf),
        def("panel.checklist", "Checklist", section: "Panels", key: kVK_ANSI_L, action: .toggleChecklist,
            note: "A small card with the items you tick off; it stays over the other apps."),
    ]

    private static let focus: [ShortcutDefinition] = [
        def("focus.putAway", "Send the front window away", section: "Focus", key: kVK_ANSI_V,
            modifiers: ctrlOptShift, action: .putAwayFront),
        def("focus.everythingBack", "Everything back", section: "Focus", key: kVK_ANSI_A,
            modifiers: ctrlOptShift, action: .showEverything),
        def("focus.undo", "Undo one step", section: "Focus", key: kVK_ANSI_Z, action: .undoStep),
    ]

    private static let groups: [ShortcutDefinition] = (1...9).flatMap { slot -> [ShortcutDefinition] in
        let key = kVK_ANSI_1 + (slot - 1)
        return [
            def("group.recall.\(slot)", "Recall group \(slot)", section: "Groups", key: key,
                action: .recallGroup(slot)),
            def("group.assign.\(slot)", "Add / remove the front window from group \(slot)", section: "Groups",
                key: key, modifiers: ctrlOptCmd, action: .assignToGroup(slot)),
        ]
    }

    private static let timers: [ShortcutDefinition] = [
        def("timer.new", "New timer…", section: "Timers", key: kVK_ANSI_T,
            modifiers: ctrlOptShift, action: .newTimer,
            note: "25m, 1h 30m or 8:30 for the next half past eight; Ret starts, Esc closes."),
    ]

    private static let peek: [ShortcutDefinition] = [
        def("peek.designate", "Designate / undesignate the front window", section: "Peek",
            key: kVK_ANSI_P, modifiers: ctrlOptCmd, action: .peekDesignate),
        info("peek.hold", "Peek at it while held", section: "Peek", keys: "hold ⌃⌥H",
             note: "Press and hold; release puts it back."),
    ]

    private static let capture: [ShortcutDefinition] = [
        def("capture.recognizeText", "Recognize text from a selected area", section: "Text & colour",
            key: kVK_ANSI_O, action: .recognizeText,
            note: "Esc cancels. The text goes to the clipboard; recognition runs locally."),
        def("capture.colour", "Pick a colour from the screen", section: "Text & colour",
            key: kVK_ANSI_E, action: .sampleColor,
            note: "Click a point to copy its colour in the format chosen in Settings ▸ Panels; Esc cancels."),
    ]

    private static let screenshots: [ShortcutDefinition] = [
        def("capture.annotate", "Annotate a screenshot", section: "Screenshots",
            key: kVK_ANSI_S, modifiers: ctrlOptShift, action: .captureScreenshot,
            note: "Drag an area, mark it up, and it lands on the shelf; Ret saves, Esc cancels."),
    ]

    private static let measure: [ShortcutDefinition] = [
        def("measure.area", "Measure an area", section: "Measure", key: kVK_ANSI_R, action: .measureArea,
            note: "Drag over any app; Esc cancels. The pinned badge copies the values."),
        info("measure.square", "Keep a square", section: "Measure", keys: "⇧ + drag"),
        info("measure.centre", "Measure from the centre", section: "Measure", keys: "⌥ + drag"),
        info("measure.snap", "Snap to windows and displays", section: "Measure", keys: "auto",
             note: "Within 6 pt of an edge or a centre."),
    ]

    private static let app: [ShortcutDefinition] = [
        def("app.settings", "Settings…", section: "App", key: kVK_ANSI_Comma, action: .openSettings),
        def("app.shortcuts", "Keyboard Shortcuts…", section: "App", key: kVK_ANSI_Slash, action: .openKeyboardShortcuts),
        def("app.screenshots", "Screenshots", section: "App", key: kVK_ANSI_Y, action: .openScreenshots),
        def("app.focusBorder", "Show / hide the focus border", section: "App", key: kVK_ANSI_B,
            modifiers: ctrlOptShift, action: .toggleFocusBorder),
        def("app.focusDim", "Dim everything but the focused window", section: "App", key: kVK_ANSI_D,
            modifiers: ctrlOptShift, action: .toggleFocusDim,
            note: "The veil sits below the focused window; menu bar, Dock and MakiDesk's panels stay above it."),
        def("app.focusSelection", "Focus the selected windows", section: "App", key: kVK_ANSI_F,
            modifiers: ctrlOptShift, action: .focusSelection),
        def("app.leaveGroup", "Leave the group in use", section: "App", key: kVK_ANSI_L,
            modifiers: ctrlOptShift, action: .leaveGroup),
        def("app.clearPeek", "Clear the peek designation", section: "App", key: kVK_ANSI_H,
            modifiers: ctrlOptShift, action: .clearPeek),
        def("app.applyAdvice", "Apply the suggested layout", section: "App", key: kVK_Return,
            modifiers: ctrlOptShift, action: .applySuggestedLayout),
        def("app.miniMap", "Show / hide the mini map", section: "App", key: kVK_ANSI_M,
            modifiers: ctrlOptShift, action: .toggleMiniMap),
    ]
}
