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
/// The catalog is the single source for button behavior and category. Commands
/// reuse existing actions; quick toggles call the controller that owns their
/// setting, so the bar does not grow a second implementation of either.
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
        /// A setting with a direct on/off state, shown as a toggle.
        case toggle(Toggle)
        case info(Info)
        case pin
        case overflow
        case customize
    }

    enum Toggle: Equatable, Sendable {
        case pointerEffects
        case clickRipple
        case keyboardSounds
    }

    enum Category: String, CaseIterable, Sendable {
        case panels
        case apps
        case tools
        case quickToggles
        case system

        var title: String {
            switch self {
            case .panels: return "Panels"
            case .apps: return "Apps"
            case .tools: return "Capture & tools"
            case .quickToggles: return "Quick toggles"
            case .system: return "System"
            }
        }
    }

    enum Info: String, CaseIterable, Identifiable, Sendable {
        case disk
        case cpu
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

    var category: Category? { BarItemCatalog.category(for: id) }

    var shortcutAction: WindowController.ShortcutAction? {
        guard case let .shortcut(action) = kind else { return nil }
        return action
    }

    /// A stable estimate for `BarLayout`; the view uses the same numbers for
    /// its own buttons, so the plan and the pixels agree. A badge is part of
    /// the width: a count is not free, and a plan that forgets it truncates the
    /// labels beside the icon.
    func width(labels: Bool, badge: String? = nil) -> CGFloat {
        let base: CGFloat
        switch kind {
        case .info:
            base = labels ? 92 : 68
        case .pin, .overflow, .customize:
            base = 40
        case .shortcut:
            base = labels ? 42 + CGFloat(title.count) * 7.0 : 42
        case .toggle:
            base = labels ? 42 + CGFloat(title.count) * 7.0 : 42
        }
        guard let badge, badge.isEmpty == false else { return base }
        // 9 pt semibold digits, 4 pt of side padding and the 5 pt gap after
        // the icon or the label.
        return base + CGFloat(badge.count) * 5.5 + 13
    }
}

/// The bar's contents (F1), in display order.
enum BarItemCatalog {
    static func category(for id: String) -> BarItem.Category? {
        switch id {
        case "notes", "clipboard", "shelf", "checklist", "timer": return .panels
        case "command", "terminal", "terminalQuake", "docker", "browser": return .apps
        case "screenshot", "text", "colour", "measure", "locatePointer", "ports": return .tools
        case "focusBorder", "focusDim", "miniMap", "pointerEffects", "clickRipple",
             "keyboardSounds": return .quickToggles
        case "disk", "cpu", "windows": return .system
        default: return nil
        }
    }

    static let utility: [BarItem] = [
        BarItem(id: "notes", title: "Notes", symbol: "note.text",
                zone: .utility, kind: .shortcut(.openNotes), priority: 1),
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
        BarItem(id: "locatePointer", title: "Locate pointer", symbol: "scope",
                zone: .utility, kind: .shortcut(.locatePointer), priority: 2),
        BarItem(id: "ports", title: "Ports", symbol: "network",
                zone: .utility, kind: .shortcut(.openPorts), priority: 3),
        BarItem(id: "command", title: "Command box", symbol: "command",
                zone: .utility, kind: .shortcut(.runCommand), priority: 2),
        BarItem(id: "terminal", title: "Terminal", symbol: "terminal",
                zone: .utility, kind: .shortcut(.openTerminal), priority: 1),
        BarItem(id: "terminalQuake", title: "Quake", symbol: "rectangle.topthird.inset.filled",
                zone: .utility, kind: .shortcut(.toggleTerminalQuake), priority: 2),
        BarItem(id: "docker", title: "Docker", symbol: "shippingbox",
                zone: .utility, kind: .shortcut(.openDocker), priority: 2),
        BarItem(id: "browser", title: "Browser", symbol: "safari",
                zone: .utility, kind: .shortcut(.openBrowser), priority: 2),
    ]

    static let toggles: [BarItem] = [
        BarItem(id: "focusBorder", title: "Focus border", symbol: "rectangle.dashed",
                zone: .toggle, kind: .shortcut(.toggleFocusBorder), priority: 1),
        BarItem(id: "focusDim", title: "Focus dim", symbol: "circle.lefthalf.filled",
                zone: .toggle, kind: .shortcut(.toggleFocusDim), priority: 1),
        BarItem(id: "miniMap", title: "Mini map", symbol: "map",
                zone: .toggle, kind: .shortcut(.toggleMiniMap), priority: 3),
        BarItem(id: "pointerEffects", title: "Pointer effects", symbol: "cursorarrow.rays",
                zone: .toggle, kind: .toggle(.pointerEffects), priority: 1),
        BarItem(id: "clickRipple", title: "Click ripple", symbol: "dot.circle.and.hand.point.up.left.fill",
                zone: .toggle, kind: .toggle(.clickRipple), priority: 2),
        BarItem(id: "keyboardSounds", title: "Keyboard sounds", symbol: "keyboard",
                zone: .toggle, kind: .toggle(.keyboardSounds), priority: 2),
    ]

    static let info: [BarItem] = [
        BarItem(id: "disk", title: "Free disk", symbol: "internaldrive",
                zone: .info, kind: .info(.disk), priority: 2),
        BarItem(id: "cpu", title: "CPU", symbol: "cpu",
                zone: .info, kind: .info(.cpu), priority: 2),
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

    /// Everything the user may hide. The right-hand controls stay: the bar
    /// would lose its pin and the way to Settings. Visibility itself lives in
    /// `BarConfiguration`, which also carries the order and the optional
    /// per-button title and symbol.
    static let hideable: [BarItem] = planned

    static func item(id: String) -> BarItem? {
        all.first { $0.id == id }
    }
}
