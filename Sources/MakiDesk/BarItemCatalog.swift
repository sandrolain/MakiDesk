import Foundation

/// How the bar decides whether to show the words beside the icons.
enum BarLabelMode: String, CaseIterable, Identifiable, Sendable {
    case auto
    case always
    case never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .always: return "Always"
        case .never: return "Never"
        }
    }
}

/// One control in the utility bar (F1).
///
/// The catalog is the single source: a command appears in the bar only because
/// it is here, and every entry names an action that already exists — the bar
/// adds presentation, not behaviour. That is what keeps it from growing a
/// second, subtly different copy of the menu.
struct BarItem: Identifiable, Equatable {
    enum Zone: String, CaseIterable, Sendable {
        case utility
        case toggle
        case info
        case right
    }

    enum Kind: Equatable, Sendable {
        /// Runs the same action the shortcut and the menu run.
        case shortcut(WindowController.ShortcutAction)
        case info(Info)
        case pin
        case overflow
        case customize
    }

    enum Info: String, CaseIterable, Identifiable, Sendable {
        case disk
        case cpu
        case timers
        case windows

        var id: String { rawValue }
    }

    let id: String
    let title: String
    let symbol: String
    let zone: Zone
    let kind: Kind
    /// 1 is kept longest; larger numbers overflow first. The right-hand
    /// controls are never planned and keep 0.
    let priority: Int

    var shortcutAction: WindowController.ShortcutAction? {
        guard case let .shortcut(action) = kind else { return nil }
        return action
    }

    /// A stable estimate for `BarLayout`; the view uses the same numbers for
    /// its own buttons, so the plan and the pixels agree.
    func width(labels: Bool) -> CGFloat {
        switch kind {
        case .info:
            return labels ? 74 : 56
        case .pin, .overflow, .customize:
            return 26
        case .shortcut:
            guard labels else { return 26 }
            return 26 + CGFloat(title.count) * 6.2 + 8
        }
    }
}

/// The bar's contents (F1), in display order.
enum BarItemCatalog {
    static let utility: [BarItem] = [
        BarItem(id: "notes", title: "Notes", symbol: "note.text",
                zone: .utility, kind: .shortcut(.toggleNotes), priority: 1),
        BarItem(id: "clipboard", title: "Clipboard", symbol: "doc.on.clipboard",
                zone: .utility, kind: .shortcut(.clipboardHistory), priority: 1),
        BarItem(id: "shelf", title: "Shelf", symbol: "tray",
                zone: .utility, kind: .shortcut(.toggleShelf), priority: 1),
        BarItem(id: "checklist", title: "Checklist", symbol: "checklist",
                zone: .utility, kind: .shortcut(.toggleChecklist), priority: 2),
        BarItem(id: "timer", title: "Timer", symbol: "timer",
                zone: .utility, kind: .shortcut(.newTimer), priority: 1),
        BarItem(id: "screenshot", title: "Screenshot", symbol: "camera.viewfinder",
                zone: .utility, kind: .shortcut(.captureScreenshot), priority: 2),
        BarItem(id: "text", title: "Text from screen", symbol: "text.viewfinder",
                zone: .utility, kind: .shortcut(.recognizeText), priority: 2),
        BarItem(id: "colour", title: "Colour", symbol: "eyedropper",
                zone: .utility, kind: .shortcut(.sampleColor), priority: 3),
        BarItem(id: "measure", title: "Measure", symbol: "ruler",
                zone: .utility, kind: .shortcut(.measureArea), priority: 3),
        BarItem(id: "ports", title: "Ports", symbol: "network",
                zone: .utility, kind: .shortcut(.openPorts), priority: 3),
        BarItem(id: "command", title: "Command box", symbol: "command",
                zone: .utility, kind: .shortcut(.runCommand), priority: 2),
    ]

    static let toggles: [BarItem] = [
        BarItem(id: "focusBorder", title: "Focus border", symbol: "rectangle.dashed",
                zone: .toggle, kind: .shortcut(.toggleFocusBorder), priority: 1),
        BarItem(id: "focusDim", title: "Focus dim", symbol: "circle.lefthalf.filled",
                zone: .toggle, kind: .shortcut(.toggleFocusDim), priority: 1),
        BarItem(id: "miniMap", title: "Mini map", symbol: "map",
                zone: .toggle, kind: .shortcut(.toggleMiniMap), priority: 3),
    ]

    static let info: [BarItem] = [
        BarItem(id: "disk", title: "Free disk", symbol: "internaldrive",
                zone: .info, kind: .info(.disk), priority: 2),
        BarItem(id: "cpu", title: "CPU", symbol: "cpu",
                zone: .info, kind: .info(.cpu), priority: 2),
        BarItem(id: "timers", title: "Timer", symbol: "hourglass",
                zone: .info, kind: .info(.timers), priority: 3),
        BarItem(id: "windows", title: "Windows", symbol: "macwindow",
                zone: .info, kind: .info(.windows), priority: 3),
    ]

    static let right: [BarItem] = [
        BarItem(id: "pin", title: "Keep the bar open", symbol: "pin",
                zone: .right, kind: .pin, priority: 0),
        BarItem(id: "overflow", title: "More", symbol: "chevron.down",
                zone: .right, kind: .overflow, priority: 0),
        BarItem(id: "customize", title: "Utility bar settings", symbol: "slider.horizontal.3",
                zone: .right, kind: .customize, priority: 0),
    ]

    static let planned: [BarItem] = utility + toggles + info
    static let all: [BarItem] = planned + right

    static func item(id: String) -> BarItem? {
        all.first { $0.id == id }
    }
}
