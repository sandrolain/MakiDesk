import CoreGraphics
import Foundation

/// How long a notice stays and how it is announced (T52). The symbol picked by
/// the call site is the fallback when no kind is given.
enum HUDKind: String, Equatable, Sendable {
    case confirmation
    case warning
    case error
    case progress

    var label: String {
        switch self {
        case .confirmation: return "Confirmation"
        case .warning: return "Warning"
        case .error: return "Error"
        case .progress: return "Progress"
        }
    }

    /// Symbols used across the app already carry the severity; infer it so 90
    /// call sites do not need a new argument just to keep their look.
    static func inferred(for symbol: String) -> HUDKind {
        let errors = ["exclamationmark", "nosign", "externaldrive.badge.xmark"]
        if errors.contains(where: symbol.contains) { return .error }
        let warnings = ["xmark", "hand.raised", "lock", "questionmark",
                        "clock", "eye.slash", "cursorarrow"]
        if warnings.contains(where: symbol.contains) { return .warning }
        return .confirmation
    }
}

/// Where notices sit on the chosen display.
enum HUDPosition: String, CaseIterable, Identifiable, Sendable {
    case bottomCenter
    case bottomRight
    case topCenter
    case topRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bottomCenter: return "Bottom centre"
        case .bottomRight: return "Bottom right"
        case .topCenter: return "Top centre"
        case .topRight: return "Top right"
        }
    }
}

/// One notice, as shown and as kept in the in-memory history.
struct HUDNotice: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let symbol: String
    let detail: String?
    let kind: HUDKind
    let date: Date
    /// Only for notices tied to a timed offer (the layout suggestion); normal
    /// call sites use the severity policy instead of a number (T52).
    var overrideDuration: TimeInterval?
}

/// Notices, screen and timing preferences. Defaults reproduce the pre-T52
/// behaviour: bottom centre, 1.4 s, history on (memory only), VoiceOver on.
enum HUDSettings {
    static let positionKey = "hudPosition"
    static let screenKey = "hudScreenLocation"
    static let baseDurationKey = "hudBaseDuration"
    static let historyEnabledKey = "hudHistoryEnabled"
    static let voiceOverKey = "hudVoiceOver"
    static let compactKey = "hudCompact"
    static let textSizeKey = "hudTextSize"

    static let defaultBaseDuration: TimeInterval = 1.4
    static let defaultTextSize: CGFloat = 14

    static func position(defaults: UserDefaults = .standard) -> HUDPosition {
        defaults.string(forKey: positionKey).flatMap(HUDPosition.init(rawValue:))
            ?? .bottomCenter
    }

    static func screenLocation(defaults: UserDefaults = .standard) -> PaletteScreenLocation {
        defaults.string(forKey: screenKey).flatMap(PaletteScreenLocation.init(rawValue:))
            ?? .focusedWindow
    }

    static func baseDuration(defaults: UserDefaults = .standard) -> TimeInterval {
        let value = defaults.double(forKey: baseDurationKey)
        return value > 0 ? value : defaultBaseDuration
    }

    static func historyEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: historyEnabledKey) != nil else { return true }
        return defaults.bool(forKey: historyEnabledKey)
    }

    static func voiceOverEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: voiceOverKey) != nil else { return true }
        return defaults.bool(forKey: voiceOverKey)
    }

    static func compact(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: compactKey)
    }

    /// Title size in points; the icon, detail and padding follow proportionally.
    static func textSize(defaults: UserDefaults = .standard) -> CGFloat {
        let value = defaults.double(forKey: textSizeKey)
        let resolved = value > 0 ? value : Double(defaultTextSize)
        return CGFloat(min(22, max(11, resolved)))
    }
}

/// Sizes derived from one text size, so the whole notice grows together (T52).
struct HUDTypography: Equatable {
    let textSize: CGFloat
    let compact: Bool

    init(textSize: CGFloat, compact: Bool) {
        self.textSize = min(22, max(11, textSize))
        self.compact = compact
    }

    var titleSize: CGFloat { compact ? max(11, textSize - 1) : textSize }
    var detailSize: CGFloat { max(9, textSize - 2.5) }
    var iconSize: CGFloat { max(12, textSize + 1) }
    var horizontalPadding: CGFloat { compact ? max(10, textSize * 0.85) : max(12, textSize * 1.15) }
    var verticalPadding: CGFloat { compact ? max(6, textSize * 0.55) : max(8, textSize * 0.8) }
    var cornerRadius: CGFloat { min(16, 13 * textSize / 14) }
    var spacing: CGFloat { compact ? 3 : 6 }
}

/// Base duration plus the multipliers by severity: confirmations get the base,
/// warnings a little more, errors twice with a floor; progress never expires.
enum HUDTiming {
    static func duration(for kind: HUDKind, base: TimeInterval) -> TimeInterval? {
        switch kind {
        case .progress:
            return nil
        case .confirmation:
            return max(0.8, base)
        case .warning:
            return max(2.0, base * 1.5)
        case .error:
            return max(3.0, base * 2)
        }
    }
}

/// Frames for a vertical stack of notices. `sizes[0]` sits nearest the chosen
/// corner, each following one further away; every frame stays inside the
/// display, including displays with a negative origin.
enum HUDLayout {
    static func frames(anchor: HUDPosition, screen: CGRect, sizes: [CGSize],
                       gap: CGFloat = 8, margin: CGFloat = 24) -> [CGRect] {
        var result: [CGRect] = []
        var offset: CGFloat = 0
        for size in sizes {
            guard size.width > 1, size.height > 1 else {
                result.append(.zero)
                continue
            }
            let x: CGFloat
            switch anchor {
            case .bottomCenter, .topCenter:
                x = screen.midX - size.width / 2
            case .bottomRight, .topRight:
                x = screen.maxX - margin - size.width
            }
            let y: CGFloat
            switch anchor {
            case .bottomCenter, .bottomRight:
                y = screen.minY + margin + offset
            case .topCenter, .topRight:
                y = screen.maxY - margin - offset - size.height
            }
            let clampedX = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
            result.append(CGRect(x: clampedX.rounded(), y: y.rounded(),
                                 width: size.width.rounded(), height: size.height.rounded()))
            offset += size.height + gap
        }
        return result
    }
}

/// The last notices, newest first, in memory only: messages can name windows,
/// zones and paths, which the app never writes to disk.
struct HUDHistory {
    private(set) var notices: [HUDNotice] = []
    let limit: Int

    init(limit: Int = 50) {
        self.limit = limit
    }

    mutating func add(_ notice: HUDNotice) {
        notices.removeAll { $0.id == notice.id }
        notices.insert(notice, at: 0)
        if notices.count > limit { notices.removeLast(notices.count - limit) }
    }

    mutating func clear() {
        notices.removeAll()
    }
}
