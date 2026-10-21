import Foundation

/// How eager the shake gesture is (T31). The presets are tuned for a deliberate
/// shake, with a minimum travel between direction changes.
enum ShelfShakeSensitivity: String, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var preset: ShakePreset {
        switch self {
        case .low: return ShakePreset(window: 1.0, inversions: 6, minimumTravel: 25)
        case .medium: return ShakePreset(window: 1.2, inversions: 5, minimumTravel: 18)
        case .high: return ShakePreset(window: 1.5, inversions: 4, minimumTravel: 12)
        }
    }
}

struct ShakePreset: Equatable {
    /// The inversions must all happen inside this window.
    let window: TimeInterval
    /// How many direction changes make a shake.
    let inversions: Int
    /// The horizontal travel between two changes before they count.
    let minimumTravel: CGFloat
}

/// The shake inside a drag, as a pure state machine: same points and times,
/// same answer, so the gesture can be tested without a mouse (T31).
///
/// A direction change counts only after the pointer has travelled at least
/// `minimumTravel` in the current direction, and only if the changes fit inside
/// `window` seconds. A straight drag never triggers; a small jitter never does.
struct ShakeDetector {
    private var lastPoint: CGPoint?
    private var direction = 0
    private var leg: CGFloat = 0
    private var inversions: [TimeInterval] = []

    mutating func reset() {
        lastPoint = nil
        direction = 0
        leg = 0
        inversions.removeAll()
    }

    /// Feeds a drag point. Returns true exactly when the gesture has just
    /// completed; the detector resets itself for the next drag.
    mutating func drag(to point: CGPoint, at time: TimeInterval,
                       preset: ShakePreset) -> Bool {
        if let lastPoint {
            let dx = point.x - lastPoint.x
            let distance = abs(dx)
            if distance >= 0.5 {
                let newDirection = dx > 0 ? 1 : -1
                if direction == 0 {
                    direction = newDirection
                    leg = distance
                } else if newDirection == direction {
                    leg += distance
                } else {
                    if leg >= preset.minimumTravel {
                        inversions.append(time)
                    }
                    direction = newDirection
                    leg = distance
                }
            }
        }
        lastPoint = point

        inversions.removeAll { time - $0 > preset.window }
        guard inversions.count >= preset.inversions else { return false }
        reset()
        return true
    }
}
