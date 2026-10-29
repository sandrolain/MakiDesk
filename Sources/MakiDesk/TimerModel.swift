import CoreGraphics
import Foundation

/// One timer on the board (T61).
///
/// A countdown and an "until 8:30" timer are the same thing once started: a
/// wall-clock deadline. The origin is kept only so the list can say which one
/// it was and so a paused clock timer can still be named after its hour.
struct AppTimer: Identifiable, Equatable, Sendable {
    enum Origin: String, Sendable {
        case countdown
        case clockTime
    }

    let id: UUID
    var label: String
    var origin: Origin
    /// The moment it is due, absolute, so a sleep, a clock change or a time
    /// zone change only re-reads the same instant instead of adding up ticks.
    /// Nil while paused.
    var deadline: Date?
    /// What was left when paused; nil while running.
    var pausedRemaining: TimeInterval?
    /// The wall-clock moment a `.clockTime` timer is meant for.
    var clockTarget: Date?

    init(id: UUID = UUID(), label: String, origin: Origin, deadline: Date?,
         pausedRemaining: TimeInterval? = nil, clockTarget: Date? = nil) {
        self.id = id
        self.label = label
        self.origin = origin
        self.deadline = deadline
        self.pausedRemaining = pausedRemaining
        self.clockTarget = clockTarget
    }

    var isPaused: Bool { pausedRemaining != nil }

    func remaining(at now: Date) -> TimeInterval {
        if let pausedRemaining { return max(0, pausedRemaining) }
        guard let deadline else { return 0 }
        return max(0, deadline.timeIntervalSince(now))
    }

    /// A timer that has passed its deadline. A paused one never is: the user
    /// stopped it.
    func isDue(at now: Date) -> Bool {
        guard pausedRemaining == nil, let deadline else { return false }
        return now >= deadline
    }
}

/// What the input field understood (T61): a length, or a time of day.
enum TimerInput: Equatable, Sendable {
    case countdown(TimeInterval)
    case clock(hour: Int, minute: Int)
}

/// Text for the timers: the formats the menu and the overlay show, and the
/// parser for what the user types.
///
/// The rule that has to be learned once: a **duration** is written with a unit
/// (`40s`, `25m`, `1h 30m`) or as a bare number of minutes, while a **time of
/// day** is written with a colon (`8:30`, `20:15`). `1:30` is therefore half
/// past one at night, not ninety minutes; for ninety minutes there is `1h 30m`.
enum TimerText {
    // MARK: - Showing

    /// "40s", "1m 30s", "45m", "1h 20m": as few units as the value needs.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return rest > 0 ? "\(minutes)m \(rest)s" : "\(minutes)m"
        }
        return "\(rest)s"
    }

    /// The overlay's line: "24:31", or "1:05:12" once there is an hour.
    static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, rest)
        }
        return String(format: "%d:%02d", minutes, rest)
    }

    /// A label as it will be shown: trimmed, on one line, and short enough not
    /// to push the time off the card. Empty means "use the default".
    static func cleanLabel(_ text: String?) -> String? {
        guard let text else { return nil }
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.isEmpty == false else { return nil }
        return flat.count > 40 ? String(flat.prefix(40)) : flat
    }

    /// "8:30" — the hour without a leading zero, the minutes with one.
    static func clock(hour: Int, minute: Int) -> String {
        String(format: "%d:%02d", hour, minute)
    }

    /// Where a clock target sits relative to `now`: "8:30", or "domani alle
    /// 8:30" when it is not today.
    static func clockDay(_ target: Date, now: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("Hm")
        let time = formatter.string(from: target)
        if calendar.isDate(target, inSameDayAs: now) { return time }
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale.current
        dayFormatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return "\(dayFormatter.string(from: target)) · \(time)"
    }

    /// One row of the menu and the overlay label: what it is and what is left.
    static func row(_ timer: AppTimer, now: Date, calendar: Calendar = .current) -> String {
        let left = duration(timer.remaining(at: now))
        if timer.origin == .clockTime, let target = timer.clockTarget, !timer.isPaused {
            return "\(clockDay(target, now: now, calendar: calendar)) · tra \(left)"
        }
        return "\(timer.label) · \(left)"
    }

    // MARK: - Reading

    static func parse(_ raw: String) -> TimerInput? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard text.isEmpty == false else { return nil }
        for prefix in ["fino alle ", "fino a ", "until ", "till ", "alle ", "at "]
        where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
        text = text.trimmingCharacters(in: .whitespaces)
        guard text.isEmpty == false else { return nil }
        if let clockValue = clockValue(text) { return .clock(hour: clockValue.0, minute: clockValue.1) }
        if let duration = durationValue(text), duration > 0 { return .countdown(duration) }
        return nil
    }

    /// A bare number is minutes: "25" is the same as "25m".
    private static func clockValue(_ text: String) -> (Int, Int)? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute),
              parts[0].count <= 2, parts[1].count == 2,
              parts[0].allSatisfy(\.isNumber), parts[1].allSatisfy(\.isNumber) else {
            return nil
        }
        return (hour, minute)
    }

    /// "40s", "1m 30s", "45m", "1h 20m", "1h30m", or a bare number of minutes.
    private static func durationValue(_ text: String) -> TimeInterval? {
        if text.allSatisfy(\.isNumber) {
            guard let minutes = Double(text) else { return nil }
            return minutes * 60
        }
        var index = text.startIndex
        var total: TimeInterval = 0
        var seen: Set<Character> = []
        var readSomething = false
        while index < text.endIndex {
            while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
            guard index < text.endIndex else { break }
            var digits = ""
            while index < text.endIndex, text[index].isNumber {
                digits.append(text[index])
                index = text.index(after: index)
            }
            // "25 min" is as readable as "25min".
            while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
            guard digits.isEmpty == false, index < text.endIndex,
                  let value = Double(digits) else { return nil }
            // The unit may be the letter alone or the whole word: "25m" and
            // "25 minutes" are the same thing.
            let unitStart = index
            index = text.index(after: index)
            while index < text.endIndex, text[index].isLetter {
                index = text.index(after: index)
            }
            let unit = String(text[unitStart..<index])
            let seconds: TimeInterval
            switch unit {
            case "h", "hr", "hrs", "hour", "hours":
                seconds = value * 3600
            case "m", "min", "mins", "minute", "minutes":
                seconds = value * 60
            case "s", "sec", "secs", "second", "seconds":
                seconds = value
            default:
                return nil
            }
            // "1h 1h" is a typo, not two hours.
            guard let kind = unit.first, seen.insert(kind).inserted else { return nil }
            total += seconds
            readSomething = true
        }
        return readSomething ? total : nil
    }
}

/// The timers themselves: several at once, each pausable, each a deadline.
struct TimerBoard: Equatable, Sendable {
    private(set) var timers: [AppTimer] = []

    /// Past this the overlay and the menu stop being readable at a glance.
    static let maxTimers = 8

    var isEmpty: Bool { timers.isEmpty }
    var hasRunning: Bool { timers.contains { !$0.isPaused } }

    /// The list the overlay and the menu show: the nearest deadline first.
    func sorted(at now: Date) -> [AppTimer] {
        timers.sorted { lhs, rhs in
            let left = lhs.remaining(at: now)
            let right = rhs.remaining(at: now)
            return left == right ? lhs.label < rhs.label : left < right
        }
    }

    @discardableResult
    mutating func startCountdown(_ duration: TimeInterval, label: String? = nil,
                                 now: Date) -> AppTimer? {
        guard timers.count < Self.maxTimers, duration > 0 else { return nil }
        let timer = AppTimer(label: label ?? TimerText.duration(duration),
                             origin: .countdown,
                             deadline: now.addingTimeInterval(duration))
        timers.append(timer)
        return timer
    }

    @discardableResult
    mutating func startClock(hour: Int, minute: Int, now: Date,
                             calendar: Calendar = .current,
                             label: String? = nil) -> AppTimer? {
        guard timers.count < Self.maxTimers,
              let target = Self.nextOccurrence(hour: hour, minute: minute, after: now,
                                               calendar: calendar) else { return nil }
        let timer = AppTimer(label: label ?? TimerText.clock(hour: hour, minute: minute),
                             origin: .clockTime,
                             deadline: target,
                             clockTarget: target)
        timers.append(timer)
        return timer
    }

    /// The next time the clock says `hour:minute`: today when it is still
    /// ahead, otherwise tomorrow. Read through the calendar, so a change of
    /// hour or of time zone lands on the wall clock the user named.
    static func nextOccurrence(hour: Int, minute: Int, after now: Date,
                               calendar: Calendar = .current) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard let today = calendar.date(from: components) else { return nil }
        if today > now { return today }
        return calendar.date(byAdding: .day, value: 1, to: today)
    }

    mutating func pause(_ id: UUID, now: Date) {
        guard let index = timers.firstIndex(where: { $0.id == id }),
              let deadline = timers[index].deadline else { return }
        timers[index].pausedRemaining = max(0, deadline.timeIntervalSince(now))
        timers[index].deadline = nil
    }

    mutating func resume(_ id: UUID, now: Date) {
        guard let index = timers.firstIndex(where: { $0.id == id }),
              let remaining = timers[index].pausedRemaining else { return }
        timers[index].deadline = now.addingTimeInterval(remaining)
        timers[index].pausedRemaining = nil
    }

    mutating func remove(_ id: UUID) {
        timers.removeAll { $0.id == id }
    }

    mutating func removeAll() {
        timers.removeAll()
    }

    /// Takes the timers that ran out and says which they were, so the caller
    /// can announce each one exactly once.
    mutating func expire(at now: Date) -> [AppTimer] {
        let due = timers.filter { $0.isDue(at: now) }
        guard due.isEmpty == false else { return [] }
        timers.removeAll { $0.isDue(at: now) }
        return due
    }
}

/// Whether the overlay should be out of the way (T61).
///
/// The pointer coming close hides it; it comes back only once the pointer is
/// twice as far away, and only after a short delay, so a pointer resting on the
/// boundary cannot make it flicker. Pure, so the thresholds are tested without
/// a mouse.
struct TimerProximity: Equatable {
    /// Closer than this and the overlay steps out of the way.
    static let hideRadius: CGFloat = 70
    /// Further than this and it may come back (about twice as far).
    static let showRadius: CGFloat = 140
    /// How long the pointer must stay outside before it returns.
    static let delay: TimeInterval = 0.4

    private(set) var isHidden = false
    /// When the reveal becomes due, while the pointer waits outside.
    private(set) var revealAt: Date?

    /// Says whether the overlay must be hidden now. `revealAt` tells the caller
    /// when to ask again while the pointer is still.
    mutating func update(pointer: CGPoint, overlay: CGRect, now: Date) -> Bool {
        let distance = Self.distance(from: pointer, to: overlay)
        if isHidden {
            guard distance > Self.showRadius else {
                revealAt = nil
                return isHidden
            }
            if let deadline = revealAt {
                if now >= deadline {
                    isHidden = false
                    revealAt = nil
                }
            } else {
                revealAt = now.addingTimeInterval(Self.delay)
            }
        } else if distance < Self.hideRadius {
            isHidden = true
            revealAt = nil
        }
        return isHidden
    }

    /// Forgets the pointer, for a hide that is not about proximity.
    mutating func reset() {
        isHidden = false
        revealAt = nil
    }

    static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Limits and defaults for the countdown overlay (T61).
enum TimerSettings {
    static let overlayVisibleKey = "timerOverlayVisible"
    static let overlayOpacityKey = "timerOverlayOpacity"
    static let overlayPositionKey = "timerOverlayPosition"
    static let overlayScreenKey = "timerOverlayScreen"

    static let soundEnabledKey = "timerSoundEnabled"
    static let soundNameKey = "timerSoundName"

    /// The system sounds offered in Settings. They are files in
    /// `/System/Library/Sounds`, so nothing new is installed or downloaded.
    static let soundNames = ["Glass", "Ping", "Pop", "Submarine",
                             "Tink", "Funk", "Hero", "Morse"]
    static let defaultSound = "Glass"

    static let opacityRange: ClosedRange<Double> = 0.3...1
    static let defaultOpacity = 0.6
    /// Top centre by default: the checklist and the mini map live top right.
    static let defaultPosition = HUDPosition.topCenter
    static let defaultScreen = PaletteScreenLocation.focusedWindow

    /// The quick starts in the menu.
    static let quickStarts: [QuickStart] = [
        QuickStart(title: "1 minute", seconds: 60),
        QuickStart(title: "5 minutes", seconds: 300),
        QuickStart(title: "10 minutes", seconds: 600),
        QuickStart(title: "25 minutes", seconds: 1500)
    ]

    struct QuickStart: Identifiable, Sendable {
        var id: String { title }
        let title: String
        let seconds: TimeInterval
    }

    /// A name from the list, or the default when the stored one is gone.
    static func resolvedSound(_ name: String?) -> String {
        guard let name, soundNames.contains(name) else { return defaultSound }
        return name
    }

    static func clampedOpacity(_ value: Double) -> Double {
        min(max(value, opacityRange.lowerBound), opacityRange.upperBound)
    }

    /// The overlay's alpha: the setting, solid when the system asks for it.
    static func alpha(opacity: Double, reduceTransparency: Bool) -> CGFloat {
        reduceTransparency ? 1 : CGFloat(clampedOpacity(opacity))
    }
}
