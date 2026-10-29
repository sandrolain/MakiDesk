import CoreGraphics
import Foundation

/// How long a notice stays and how it is announced (T52). The symbol picked by
/// the call site is the fallback when no kind is given.
///
/// Five states, five looks (T60): neutral `info`, the app's accent for
/// `confirmation` (an answer to what was asked), green `success` (it worked),
/// orange `warning`, red `error`.
enum HUDKind: String, Equatable, Sendable, CaseIterable {
    case info
    case confirmation
    case success
    case warning
    case error
    case progress

    var label: String {
        switch self {
        case .info: return "Info"
        case .confirmation: return "Confirmation"
        case .success: return "Success"
        case .warning: return "Warning"
        case .error: return "Error"
        case .progress: return "Progress"
        }
    }

    /// Symbols used across the app already carry the severity; infer it so 90
    /// call sites do not need a new argument just to keep their look. A tick is
    /// `success` and an information symbol is `info`; everything else stays a
    /// confirmation, so no call site changed its text to gain a state.
    static func inferred(for symbol: String) -> HUDKind {
        let errors = ["exclamationmark", "nosign", "externaldrive.badge.xmark"]
        if errors.contains(where: symbol.contains) { return .error }
        let warnings = ["xmark", "hand.raised", "lock", "questionmark",
                        "clock", "eye.slash", "cursorarrow"]
        if warnings.contains(where: symbol.contains) { return .warning }
        if symbol.contains("checkmark") { return .success }
        if symbol.contains("info") || symbol.contains("bell") { return .info }
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
    /// A notice the user must take away: no timer, and a ✕ in its corner
    /// (T60). Errors become sticky only when the option is on.
    var sticky: Bool = false
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
    /// Keep errors on screen until the user dismisses them (T60). Off by
    /// default, so the behaviour of every existing notice is unchanged.
    static let errorsStickyKey = "hudKeepErrors"

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

    /// Whether an error waits for the user instead of timing out (T60).
    static func errorsSticky(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: errorsStickyKey)
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
        case .info, .confirmation, .success:
            return max(0.8, base)
        case .warning:
            return max(2.0, base * 1.5)
        case .error:
            return max(3.0, base * 2)
        }
    }

    /// How long this notice stays, or `nil` when only the user can take it
    /// away: sticky notices never expire, and an explicit duration still loses
    /// to the ✕ (T60).
    static func duration(for notice: HUDNotice, base: TimeInterval) -> TimeInterval? {
        if notice.sticky { return nil }
        return notice.overrideDuration ?? duration(for: notice.kind, base: base)
    }
}

/// Which notices wait for the user (T60). Nothing is sticky by default: the
/// option switches errors, and a call site can always ask for one.
enum HUDStickyPolicy {
    static func isSticky(kind: HUDKind, keepErrors: Bool) -> Bool {
        kind == .error && keepErrors
    }
}

/// One sample notice per state, for the Preview buttons in Settings (T60).
/// The content is a value so the buttons and what they show are checked
/// together, without a screen.
struct HUDPreview: Equatable {
    let text: String
    let symbol: String
    let detail: String

    static func sample(for kind: HUDKind) -> HUDPreview {
        switch kind {
        case .info:
            return HUDPreview(text: "Information",
                              symbol: "info.circle",
                              detail: "The icon and the border take the colour of the state.")
        case .confirmation:
            return HUDPreview(text: "Window moved",
                              symbol: "rectangle.on.rectangle",
                              detail: "Left column · 720 × 900")
        case .success:
            return HUDPreview(text: "Screenshot saved",
                              symbol: "checkmark.circle.fill",
                              detail: "Desktop · 1.2 MB")
        case .warning:
            return HUDPreview(text: "Taking longer than usual",
                              symbol: "clock",
                              detail: "MakiDesk is waiting for the app to answer.")
        case .error:
            return HUDPreview(text: "Window cannot be closed",
                              symbol: "exclamationmark.triangle.fill",
                              detail: "Terminal opened a sheet · close it first")
        case .progress:
            return HUDPreview(text: "Transferring shelf items…",
                              symbol: "hourglass",
                              detail: "2 of 5")
        }
    }
}

/// What is on screen, in two lanes (T60): sticky notices the user must take
/// away, and transients that expire on their own.
///
/// The separate budgets are the point: a sticky notice, which nothing removes
/// but a click, never blocks the queue behind it, and a burst of notices can
/// never push an unread error away. Each lane is newest first.
struct HUDStack: Equatable {
    private(set) var sticky: [UUID] = []
    private(set) var transient: [UUID] = []
    let maxSticky: Int
    let maxTransient: Int

    init(maxSticky: Int = 3, maxTransient: Int = 2) {
        self.maxSticky = maxSticky
        self.maxTransient = maxTransient
    }

    /// Adds a sticky id, returning the id evicted when the lane was full. The
    /// evicted notice stays in the history.
    mutating func addSticky(_ id: UUID) -> UUID? {
        sticky.insert(id, at: 0)
        guard sticky.count > maxSticky else { return nil }
        return sticky.removeLast()
    }

    /// Adds a transient id; `false` when it has to wait in the queue.
    mutating func addTransient(_ id: UUID) -> Bool {
        guard transient.count < maxTransient else { return false }
        transient.insert(id, at: 0)
        return true
    }

    /// Removes an id from either lane; `false` when it was not showing.
    @discardableResult
    mutating func remove(_ id: UUID) -> Bool {
        if let index = sticky.firstIndex(of: id) {
            sticky.remove(at: index)
            return true
        }
        if let index = transient.firstIndex(of: id) {
            transient.remove(at: index)
            return true
        }
        return false
    }

    /// The ids in the order they stack on screen: sticky notices nearest the
    /// anchor, then the transients.
    var ordered: [UUID] { sticky + transient }

    var hasTransientRoom: Bool { transient.count < maxTransient }
    var isEmpty: Bool { sticky.isEmpty && transient.isEmpty }

    func contains(_ id: UUID) -> Bool {
        sticky.contains(id) || transient.contains(id)
    }

    mutating func clear() {
        sticky.removeAll()
        transient.removeAll()
    }
}

/// Frames for a vertical stack of notices. `sizes[0]` sits nearest the chosen
/// corner, each following one further away; every frame stays inside the
/// display, including displays with a negative origin.
enum HUDLayout {
    static func frames(anchor: HUDPosition, screen: CGRect, sizes: [CGSize],
                       gap: CGFloat = 8, margin: CGFloat = 24,
                       minimumEdge: CGFloat = 8) -> [CGRect] {
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
            let clampedX = min(max(x, screen.minX + minimumEdge),
                               screen.maxX - size.width - minimumEdge)
            result.append(CGRect(x: clampedX.rounded(), y: y.rounded(),
                                 width: size.width.rounded(), height: size.height.rounded()))
            offset += size.height + gap
        }
        return result
    }

    /// The ✕ hit area. Small enough to sit inside the notice, large enough to
    /// hit without aiming.
    static let closeControlSize: CGFloat = 24

    /// The ✕ of a sticky notice: a small square centred on the notice's right
    /// edge, inside the rounded shape. The corner is no place for it — the
    /// notice is a rounded rectangle, so a control near the corner sits on the
    /// curve and looks like it is outside the notice. It is the only
    /// interactive part of a notice, and it lives in its own click-taking
    /// panel, so the rest of the notice stays click-through (T60).
    static func closeFrame(for notice: CGRect, size: CGFloat = closeControlSize,
                           inset: CGFloat = 6) -> CGRect {
        CGRect(x: notice.maxX - size - inset,
               y: notice.midY - size / 2,
               width: size, height: size)
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
