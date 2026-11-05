import CoreGraphics
import Foundation

// The pointer effects' decisions, as values (E1–E7).
//
// A pulse, the ring that follows the pointer and the ripple of a click are
// geometry and timing: where the display is, how far the ring may grow before
// it leaves the screen, when the last of three rings has finished. None of
// that needs a window server, so it is checked with points and times instead
// of a desktop.

/// The styles the presentation ring can take (E3–E7). The pulse is not a
/// style: it is a one-shot gesture with its own shortcut.
enum PointerEffectStyle: String, CaseIterable, Identifiable, Sendable {
    /// A ring in the accent colour, with a soft glow (E3).
    case ring
    /// A short, tapered ribbon that follows the pointer (E4).
    case ribbon
    /// A small particle emitter at the pointer (E5).
    case particles
    /// Two or three dots orbiting the pointer (E6).
    case orbit
    /// The screen dimmed except for a hole around the pointer (E7).
    case spotlight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ring: return "Ring"
        case .ribbon: return "Ribbon"
        case .particles: return "Particles"
        case .orbit: return "Orbit"
        case .spotlight: return "Spotlight"
        }
    }

    /// One line for the Settings picker, so a style is not just a name.
    var summary: String {
        switch self {
        case .ring: return "A ring in the accent colour, with a soft glow."
        case .ribbon: return "A tapered trail that fades behind the pointer."
        case .particles: return "Small sparks around the pointer, brighter while it moves."
        case .orbit: return "Three dots circling the pointer."
        case .spotlight: return "The screen dimmed except around the pointer."
        }
    }
}

/// One sampled pointer position and when it was read. The ribbon's geometry is
/// built from a short, bounded history of these.
struct PointerSample: Equatable, Sendable {
    let point: CGPoint
    let time: TimeInterval
}

/// A bounded, deduplicated history of the pointer, and the two paths the ribbon
/// style draws from it. Pure: the same points and times give the same path.
struct PointerTrail: Equatable, Sendable {
    private(set) var samples: [PointerSample] = []

    static let maximumSamples = 26
    static let minimumDistance: CGFloat = 1.2

    var isEmpty: Bool { samples.isEmpty }

    mutating func append(_ point: CGPoint, at time: TimeInterval) {
        guard point.x.isFinite, point.y.isFinite else { return }
        if let last = samples.last {
            if time < last.time { samples.removeAll() }
        }
        if let last = samples.last {
            let distance = hypot(point.x - last.point.x, point.y - last.point.y)
            if distance < Self.minimumDistance { return }
        }
        samples.append(PointerSample(point: point, time: time))
        if samples.count > Self.maximumSamples {
            samples.removeFirst(samples.count - Self.maximumSamples)
        }
    }

    mutating func prune(before time: TimeInterval) {
        samples.removeAll { $0.time < time }
    }

    mutating func removeAll() {
        samples.removeAll()
    }

    func hasSamples(after time: TimeInterval) -> Bool {
        samples.contains { $0.time >= time }
    }

    /// The filled outline of a tapered ribbon: wide at the newest sample,
    /// disappearing at the oldest. `nil` with fewer than two points.
    func ribbonPath(maxWidth: CGFloat) -> CGPath? {
        guard samples.count >= 2 else { return nil }
        let points = samples.map(\.point)
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        left.reserveCapacity(points.count)
        right.reserveCapacity(points.count)

        for index in points.indices {
            let previous = points[max(0, index - 1)]
            let next = points[min(points.count - 1, index + 1)]
            let dx = next.x - previous.x
            let dy = next.y - previous.y
            let length = hypot(dx, dy)
            guard length > 0.0001 else { continue }
            let nx = -dy / length
            let ny = dx / length
            let phase = CGFloat(index) / CGFloat(points.count - 1)
            let half = max(0.4, maxWidth * pow(phase, 1.4)) / 2
            left.append(CGPoint(x: points[index].x + nx * half,
                                y: points[index].y + ny * half))
            right.append(CGPoint(x: points[index].x - nx * half,
                                 y: points[index].y - ny * half))
        }

        guard left.count >= 2, right.count == left.count else { return nil }
        let path = CGMutablePath()
        path.move(to: left[0])
        for point in left.dropFirst() { path.addLine(to: point) }
        for point in right.reversed() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    /// The centre line of the same history, drawn as a thin bright core.
    func corePath() -> CGPath? {
        guard samples.count >= 2 else { return nil }
        let path = CGMutablePath()
        path.move(to: samples[0].point)
        for sample in samples.dropFirst() {
            path.addLine(to: sample.point)
        }
        return path
    }
}

/// The settings the effects read. Everything is clamped on the way in, so an
/// old or hand-edited default cannot make an effect unexpectedly large.
struct PointerEffectSettings: Equatable, Sendable {
    var style: PointerEffectStyle
    var size: CGFloat
    var intensity: Double
    var pulseDuration: TimeInterval
    var presentationMinutes: Int
    var includesInCaptures: Bool
    var clickRipple: Bool

    static let defaultStyle = PointerEffectStyle.ring
    static let defaultSize: CGFloat = 44
    static let sizeRange: ClosedRange<CGFloat> = 24...80
    static let defaultIntensity: Double = 0.6
    static let intensityRange: ClosedRange<Double> = 0.2...1
    static let defaultPulseDuration: TimeInterval = 0.8
    static let pulseDurationRange: ClosedRange<TimeInterval> = 0.4...2
    static let defaultPresentationMinutes = 5
    static let presentationMinutesRange = 1...30
    static let defaultIncludesInCaptures = true
    static let defaultClickRipple = true

    static let standard = PointerEffectSettings(
        style: defaultStyle,
        size: defaultSize,
        intensity: defaultIntensity,
        pulseDuration: defaultPulseDuration,
        presentationMinutes: defaultPresentationMinutes,
        includesInCaptures: defaultIncludesInCaptures,
        clickRipple: defaultClickRipple
    )

    init(style: PointerEffectStyle, size: CGFloat, intensity: Double,
         pulseDuration: TimeInterval, presentationMinutes: Int,
         includesInCaptures: Bool, clickRipple: Bool) {
        self.style = style
        self.size = min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        self.intensity = min(max(intensity, Self.intensityRange.lowerBound),
                             Self.intensityRange.upperBound)
        self.pulseDuration = min(max(pulseDuration, Self.pulseDurationRange.lowerBound),
                                 Self.pulseDurationRange.upperBound)
        self.presentationMinutes = min(max(presentationMinutes,
                                           Self.presentationMinutesRange.lowerBound),
                                       Self.presentationMinutesRange.upperBound)
        self.includesInCaptures = includesInCaptures
        self.clickRipple = clickRipple
    }

    /// Reads the registered defaults. `Settings.registerDefaults()` runs before
    /// the app is built, so an unset key already answers with its default.
    static func load(from defaults: UserDefaults = .standard) -> PointerEffectSettings {
        let style = Settings.string(.pointerEffectStyle, in: defaults)
            .flatMap(PointerEffectStyle.init(rawValue:)) ?? defaultStyle
        return PointerEffectSettings(
            style: style,
            size: CGFloat(Settings.double(.pointerEffectSize, in: defaults)),
            intensity: Settings.double(.pointerEffectIntensity, in: defaults),
            pulseDuration: Settings.double(.pointerPulseDuration, in: defaults),
            presentationMinutes: Settings.int(.pointerPresentationMinutes, in: defaults),
            includesInCaptures: Settings.bool(.pointerEffectsInCaptures, in: defaults),
            clickRipple: Settings.bool(.pointerClickRipple, in: defaults)
        )
    }
}


/// The one-shot pulse's timeline (E1). Three rings start a little apart, so the
/// effect reads as a wave instead of a single expanding circle.
struct PointerPulse: Equatable, Sendable {
    let startedAt: TimeInterval
    let duration: TimeInterval

    static let ringCount = 3
    static let stagger: TimeInterval = 0.12
    /// The last ring ends after the first one; the surface stays alive until
    /// then and no longer.
    var visibleUntil: TimeInterval {
        startedAt + Self.stagger * Double(Self.ringCount - 1) + duration
    }

    func isActive(at now: TimeInterval) -> Bool {
        now >= startedAt && now < visibleUntil
    }

    /// 0…1 for the first ring, clamped, even once the pulse is over.
    func progress(at now: TimeInterval) -> Double {
        guard duration > 0 else { return 1 }
        return min(max((now - startedAt) / duration, 0), 1)
    }

    /// The progress of ring `index` at `now`, or `nil` when it has not started
    /// or has already gone.
    func ringPhase(index: Int, at now: TimeInterval) -> Double? {
        guard index >= 0, index < Self.ringCount else { return nil }
        let start = startedAt + Self.stagger * Double(index)
        let elapsed = now - start
        guard elapsed >= 0, duration > 0 else { return elapsed >= 0 ? 1 : nil }
        let phase = elapsed / duration
        return phase <= 1 ? phase : nil
    }
}

/// Pure display and radius rules. The app already has coordinate helpers, but
/// these three answers belong to the effect and are worth checking without a
/// screen: which display, where inside it, and how large it may be.
enum PointerEffectGeometry {
    /// The display that contains `point`, or the nearest one when the pointer
    /// sits in the gap between displays. `nil` only with no displays.
    static func screenIndex(for point: CGPoint, screens: [CGRect]) -> Int? {
        guard screens.isEmpty == false else { return nil }
        if let index = screens.firstIndex(where: { $0.contains(point) }) {
            return index
        }
        var best: (index: Int, distance: CGFloat)?
        for (index, frame) in screens.enumerated() {
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            let distance = hypot(dx, dy)
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    /// A global screen point in the panel's own coordinates. The panel covers
    /// exactly one display and has no title bar, so the frame's origin is the
    /// only offset involved.
    static func localPoint(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
    }

    /// How large the ring may be before it leaves the display. Never less than
    /// 4 pt, so a pointer in the very corner still shows something.
    static func clampedRadius(_ radius: CGFloat, at point: CGPoint,
                              in frame: CGRect, margin: CGFloat = 2) -> CGFloat {
        let horizontal = min(point.x - frame.minX, frame.maxX - point.x)
        let vertical = min(point.y - frame.minY, frame.maxY - point.y)
        let limit = max(0, min(horizontal, vertical) - margin)
        return max(4, min(radius, limit))
    }

    /// Whether two frames describe the same display. A resolution or scale
    /// change keeps the id but invalidates the surface, so the size is compared
    /// too.
    static func frameMatches(_ a: CGRect, _ b: CGRect) -> Bool {
        a.origin == b.origin && a.size == b.size
    }
}

/// A small spring-free follower: the ring moves a fraction of the way to the
/// pointer each frame, which reads as a soft trail without lagging behind it.
/// The factor is clamped, so a bad setting can neither freeze nor overshoot.
struct PointerFollow: Equatable, Sendable {
    private(set) var position: CGPoint

    init(_ position: CGPoint) {
        self.position = position
    }

    mutating func move(towards target: CGPoint, factor: Double) -> CGPoint {
        let f = CGFloat(min(max(factor, 0), 1))
        position = CGPoint(x: position.x + (target.x - position.x) * f,
                           y: position.y + (target.y - position.y) * f)
        return position
    }

    func distance(to target: CGPoint) -> CGFloat {
        hypot(target.x - position.x, target.y - position.y)
    }
}
