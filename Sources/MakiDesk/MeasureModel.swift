import AppKit
import CoreGraphics
import Foundation

/// The unit a measurement is shown and copied in (T39). Points are the exact
/// base; device pixels need the backing scale; millimetres and inches come from
/// the display's reported physical size and are therefore an estimate.
enum MeasurementUnit: String, CaseIterable, Identifiable, Sendable {
    case points
    case pixels
    case millimeters
    case inches

    var id: String { rawValue }

    var title: String {
        switch self {
        case .points: return "Points — pt"
        case .pixels: return "Device pixels — px"
        case .millimeters: return "Millimetres — mm (estimated)"
        case .inches: return "Inches — in (estimated)"
        }
    }

    var symbol: String {
        switch self {
        case .points: return "pt"
        case .pixels: return "px"
        case .millimeters: return "mm"
        case .inches: return "in"
        }
    }

    /// Whole points and pixels; millimetres and inches keep decimals because
    /// they are estimates anyway.
    var decimals: Int {
        switch self {
        case .points, .pixels: return 0
        case .millimeters: return 1
        case .inches: return 3
        }
    }

    var isEstimated: Bool {
        self == .millimeters || self == .inches
    }
}

/// The display a measurement belongs to: the exact backing scale and a
/// best-effort physical DPI. `hasPhysicalSize` is false when macOS reported no
/// physical size for the display, in which case 72 dpi is assumed.
struct MeasureDisplay: Equatable, Sendable {
    let id: CGDirectDisplayID
    let scale: CGFloat
    let dpi: CGFloat
    let hasPhysicalSize: Bool

    init(id: CGDirectDisplayID, scale: CGFloat, dpi: CGFloat, hasPhysicalSize: Bool) {
        self.id = id
        self.scale = scale
        self.dpi = dpi
        self.hasPhysicalSize = hasPhysicalSize
    }

    /// Uses `CGDisplayScreenSize` (millimetres) and the display's pixel width.
    init(display: ScreenRegionDisplay) {
        let millimetres = CGDisplayScreenSize(display.id)
        let pixelWidth = display.frame.width * display.scale
        if millimetres.width > 0, pixelWidth > 0 {
            self.init(id: display.id, scale: display.scale,
                      dpi: pixelWidth / (millimetres.width / 25.4),
                      hasPhysicalSize: true)
        } else {
            self.init(id: display.id, scale: display.scale, dpi: 72,
                      hasPhysicalSize: false)
        }
    }

    func value(fromPoints points: CGFloat, unit: MeasurementUnit) -> Double {
        switch unit {
        case .points:
            return Double(points)
        case .pixels:
            return Double(points * scale)
        case .millimeters:
            return Double(points) / Double(dpi) * 25.4
        case .inches:
            return Double(points) / Double(dpi)
        }
    }
}

/// One pinned measurement (T39). Pure value: no windows, no AppKit drawing.
struct ScreenMeasurement: Equatable, Sendable {
    /// AppKit global coordinates, y up; the rectangle produced by T49.
    let rect: CGRect
    let display: MeasureDisplay
    let snapped: ScreenRegionSelector.SnapInfo

    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
    var area: CGFloat { rect.width * rect.height }
    var diagonal: CGFloat { hypot(rect.width, rect.height) }

    /// Degrees from the horizontal, 0…90: a rectangle's diagonal has no
    /// meaningful direction beyond the quadrant, which width and height imply.
    var angle: Double {
        guard rect.width > 0 else { return 90 }
        return atan2(Double(rect.height), Double(rect.width)) * 180 / .pi
    }

    private func number(_ points: CGFloat, _ unit: MeasurementUnit) -> String {
        let value = display.value(fromPoints: points, unit: unit)
        switch unit.decimals {
        case 0: return String(Int(value.rounded()))
        case 1: return String(format: "%.1f", value)
        default: return String(format: "%.3f", value)
        }
    }

    func dimensions(_ unit: MeasurementUnit) -> String {
        "\(number(width, unit)) × \(number(height, unit)) \(unit.symbol)"
    }

    func widthText(_ unit: MeasurementUnit) -> String {
        "\(number(width, unit)) \(unit.symbol)"
    }

    func heightText(_ unit: MeasurementUnit) -> String {
        "\(number(height, unit)) \(unit.symbol)"
    }

    func areaText(_ unit: MeasurementUnit) -> String {
        let value = display.value(fromPoints: area, unit: unit)
        let text = unit.decimals == 0
            ? String(Int(value.rounded()))
            : String(format: "%.\(unit.decimals)f", value)
        return "\(text) \(unit.symbol)²"
    }

    /// The three lines of the badge and of the live readout.
    func lines(_ unit: MeasurementUnit) -> [String] {
        var first = dimensions(unit)
        if snapped.axisX || snapped.axisY {
            let axes = [snapped.axisX ? "X" : nil, snapped.axisY ? "Y" : nil]
                .compactMap { $0 }.joined(separator: "/")
            first += " · snapped \(axes)"
        }
        let deltaX = "ΔX \(number(width, unit))" + (snapped.axisX ? " ⇥" : "")
        let deltaY = "ΔY \(number(height, unit))" + (snapped.axisY ? " ⇥" : "")
        let diagonal = "⤢ \(number(diagonal, unit)) \(unit.symbol)"
        let angle = String(format: "%.1f°", self.angle)
        return [
            first,
            "\(deltaX) · \(deltaY)",
            "\(diagonal) · \(angle) · \(areaText(unit))",
        ]
    }

    /// The text copied from the badge: the chosen unit first, then pixels (or
    /// points when pixels are already the chosen unit).
    func copyText(_ unit: MeasurementUnit) -> String {
        let primary = "\(dimensions(unit)) · ΔX \(number(width, unit)) · ΔY \(number(height, unit))"
        let secondUnit: MeasurementUnit = unit == .pixels ? .points : .pixels
        var parts: [String] = []
        if secondUnit != unit {
            parts.append("\(number(width, secondUnit)) × \(number(height, secondUnit)) \(secondUnit.symbol)")
        }
        parts.append("diagonal \(number(diagonal, unit)) \(unit.symbol) (\(String(format: "%.1f", angle))°)")
        parts.append("area \(areaText(unit))")
        return primary + "\n" + parts.joined(separator: " · ")
    }
}

/// Where the badge goes: below the measurement when the screen leaves room,
/// above it otherwise, always inside the display's visible frame.
enum MeasureLayout {
    static func badgeFrame(measurement: ScreenMeasurement, size: CGSize,
                           visibleFrame: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let gap: CGFloat = 10
        let margin: CGFloat = 8
        var y = measurement.rect.minY - size.height - gap
        if y < visibleFrame.minY + margin {
            y = measurement.rect.maxY + gap
        }
        y = min(max(y, visibleFrame.minY + margin),
                visibleFrame.maxY - size.height - margin)
        var x = measurement.rect.minX
        x = min(max(x, visibleFrame.minX + margin),
                visibleFrame.maxX - size.width - margin)
        return CGRect(x: x.rounded(), y: y.rounded(),
                      width: size.width.rounded(), height: size.height.rounded())
    }
}

extension Notification.Name {
    /// Posted when the measurement unit changes: badges and labels refresh.
    static let makiDeskMeasureUnitChanged = Notification.Name("makiDeskMeasureUnitChanged")
}

/// The persisted unit, shared by the menu and Settings ▸ Panels.
enum MeasurementSettings {
    nonisolated static let unitKey = "measureUnit"

    nonisolated static func unit(defaults: UserDefaults = .standard) -> MeasurementUnit {
        defaults.string(forKey: unitKey).flatMap(MeasurementUnit.init(rawValue:)) ?? .points
    }

    static func setUnit(_ unit: MeasurementUnit) {
        UserDefaults.standard.set(unit.rawValue, forKey: unitKey)
        NotificationCenter.default.post(name: .makiDeskMeasureUnitChanged, object: nil)
    }
}
