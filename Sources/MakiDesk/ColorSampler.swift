import AppKit
import CoreGraphics

/// One colour sampled from the screen, in sRGB (T36).
///
/// The capture arrives in the display's colour space; reading it through a
/// 1×1 sRGB context makes the hex value match what other tools report on a
/// colour-managed display. Screen pixels are opaque, so alpha is normally 255.
struct SampledColor: Equatable, Sendable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Averages the capture into one sRGB pixel. A point on a Retina display
    /// arrives as a 2×2 crop, so the average is also what avoids picking one
    /// sub-pixel of an antialiased edge.
    init?(image: CGImage) {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixel, width: 1, height: 1,
                                      bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        self.init(red: pixel[0], green: pixel[1], blue: pixel[2], alpha: pixel[3])
    }

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    var hexWithAlpha: String { hex + String(format: "%02X", alpha) }
    var rgb: String { "rgb(\(red), \(green), \(blue))" }
    var rgba: String {
        "rgba(\(red), \(green), \(blue), \(Self.alphaComponent(alpha)))"
    }

    /// Hue in degrees, saturation and lightness in 0…1 (CSS HSL).
    var hslComponents: (hue: Double, saturation: Double, lightness: Double) {
        let r = Double(red) / 255
        let g = Double(green) / 255
        let b = Double(blue) / 255
        let maximum = max(r, g, b)
        let minimum = min(r, g, b)
        let lightness = (maximum + minimum) / 2
        guard maximum != minimum else { return (0, 0, lightness) }
        let delta = maximum - minimum
        let saturation = lightness > 0.5
            ? delta / (2 - maximum - minimum)
            : delta / (maximum + minimum)
        let hue: Double
        if maximum == r {
            hue = (g - b) / delta + (g < b ? 6 : 0)
        } else if maximum == g {
            hue = (b - r) / delta + 2
        } else {
            hue = (r - g) / delta + 4
        }
        return (hue * 60, saturation, lightness)
    }

    var hsl: String {
        let components = hslComponents
        return "hsl(\(Int(components.hue.rounded())), "
            + "\(Int((components.saturation * 100).rounded()))%, "
            + "\(Int((components.lightness * 100).rounded()))%)"
    }

    var hsla: String {
        let components = hslComponents
        return "hsla(\(Int(components.hue.rounded())), "
            + "\(Int((components.saturation * 100).rounded()))%, "
            + "\(Int((components.lightness * 100).rounded()))%, "
            + "\(Self.alphaComponent(alpha)))"
    }

    /// A CSS-style alpha value with two decimals, always using a point.
    private static func alphaComponent(_ alpha: UInt8) -> String {
        String(format: "%.2f", Double(alpha) / 255)
    }

    var nsColor: String {
        func component(_ value: UInt8) -> String {
            String(format: "%.3f", Double(value) / 255)
        }
        return "NSColor(srgbRed: \(component(red)), green: \(component(green)), "
            + "blue: \(component(blue)), alpha: \(component(alpha)))"
    }

    // MARK: - Parsing

    /// Reads a colour written the way people copy it: hex (3, 4, 6 or 8
    /// digits), `rgb()`/`rgba()` and `hsl()`/`hsla()`. Used by the clipboard
    /// history to show a swatch before pasting (T21/T36).
    init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let lowered = trimmed.lowercased()
        if trimmed.hasPrefix("#") {
            guard let color = Self.parseHex(trimmed.dropFirst()) else { return nil }
            self = color
            return
        }
        if lowered.hasPrefix("rgba(") || lowered.hasPrefix("rgb(") {
            guard let color = Self.parseFunctional(trimmed, alphaAllowed: true, hsl: false) else {
                return nil
            }
            self = color
            return
        }
        if lowered.hasPrefix("hsla(") || lowered.hasPrefix("hsl(") {
            guard let color = Self.parseFunctional(trimmed, alphaAllowed: true, hsl: true) else {
                return nil
            }
            self = color
            return
        }
        return nil
    }

    private static func parseHex(_ digits: Substring) -> SampledColor? {
        let hex = String(digits)
        guard hex.count == 3 || hex.count == 4 || hex.count == 6 || hex.count == 8,
              hex.allSatisfy(\.isHexDigit) else { return nil }
        func value(_ text: String) -> UInt8 {
            UInt8(text, radix: 16) ?? 0
        }
        switch hex.count {
        case 3, 4:
            let characters = Array(hex)
            let doubled = characters.map { "\($0)\($0)" }
            return SampledColor(red: value(doubled[0]), green: value(doubled[1]),
                                blue: value(doubled[2]),
                                alpha: doubled.count == 4 ? value(doubled[3]) : 255)
        default:
            let r = hex.prefix(2), g = hex.dropFirst(2).prefix(2), b = hex.dropFirst(4).prefix(2)
            let a = hex.count == 8 ? hex.dropFirst(6).prefix(2) : nil
            return SampledColor(red: value(String(r)), green: value(String(g)),
                                blue: value(String(b)),
                                alpha: a.map { value(String($0)) } ?? 255)
        }
    }

    private static func parseFunctional(_ text: String, alphaAllowed: Bool,
                                        hsl: Bool) -> SampledColor? {
        guard let open = text.firstIndex(of: "("), text.hasSuffix(")") else { return nil }
        let body = text[text.index(after: open)..<text.index(before: text.endIndex)]
        let parts = body.split(whereSeparator: { $0 == "," || $0.isWhitespace || $0 == "/" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3 || (alphaAllowed && parts.count == 4) else { return nil }

        func number(_ raw: String, percentScale: Double) -> Double? {
            if raw.hasSuffix("%") {
                guard let value = Double(raw.dropLast()) else { return nil }
                return value / 100 * percentScale
            }
            return Double(raw)
        }
        func alpha(_ raw: String) -> UInt8? {
            guard let value = number(raw, percentScale: 1) else { return nil }
            let fraction = raw.hasSuffix("%") ? value : (value <= 1 ? value : value / 255)
            return UInt8((max(0, min(1, fraction)) * 255).rounded())
        }

        if hsl {
            guard let hue = number(parts[0], percentScale: 1),
                  let saturation = number(parts[1], percentScale: 1),
                  let lightness = number(parts[2], percentScale: 1) else { return nil }
            let alphaValue = parts.count == 4 ? alpha(parts[3]) : 255
            guard let alphaValue else { return nil }
            return SampledColor(hue: hue, saturation: saturation, lightness: lightness,
                                alpha: alphaValue)
        }
        guard let r = number(parts[0], percentScale: 255),
              let g = number(parts[1], percentScale: 255),
              let b = number(parts[2], percentScale: 255) else { return nil }
        let alphaValue = parts.count == 4 ? alpha(parts[3]) : 255
        guard let alphaValue else { return nil }
        func byte(_ value: Double) -> UInt8 {
            UInt8(max(0, min(255, value)).rounded())
        }
        return SampledColor(red: byte(r), green: byte(g), blue: byte(b), alpha: alphaValue)
    }

    /// HSL to sRGB, for parsing `hsl()`/`hsla()`.
    init(hue: Double, saturation: Double, lightness: Double, alpha: UInt8 = 255) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / 360
        let s = max(0, min(1, saturation))
        let l = max(0, min(1, lightness))
        guard s > 0 else {
            let value = UInt8((l * 255).rounded())
            self.init(red: value, green: value, blue: value, alpha: alpha)
            return
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        let r = channel(h + 1 / 3)
        let g = channel(h)
        let b = channel(h - 1 / 3)
        self.init(red: UInt8((r * 255).rounded()),
                  green: UInt8((g * 255).rounded()),
                  blue: UInt8((b * 255).rounded()),
                  alpha: alpha)
    }
}

/// What the colour picker puts on the clipboard (T36). Persisted by raw value
/// in Settings ▸ Panels.
enum ColorClipboardFormat: String, CaseIterable, Identifiable, Sendable {
    case hex
    case hexWithAlpha
    case rgb
    case rgba
    case hsl
    case hsla
    case nsColor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hex: return "Hex — #RRGGBB"
        case .hexWithAlpha: return "Hex with alpha — #RRGGBBAA"
        case .rgb: return "RGB — rgb(r, g, b)"
        case .rgba: return "RGBA — rgba(r, g, b, a)"
        case .hsl: return "HSL — hsl(h, s%, l%)"
        case .hsla: return "HSLA — hsla(h, s%, l%, a)"
        case .nsColor: return "NSColor — Swift"
        }
    }

    func string(for color: SampledColor) -> String {
        switch self {
        case .hex: return color.hex
        case .hexWithAlpha: return color.hexWithAlpha
        case .rgb: return color.rgb
        case .rgba: return color.rgba
        case .hsl: return color.hsl
        case .hsla: return color.hsla
        case .nsColor: return color.nsColor
        }
    }
}

/// The colour picker command (T36): one click with the shared selector in point
/// mode, then the pixel is decoded, copied in the chosen format and shown in a
/// notice. The image never leaves the process and is not written to disk.
@MainActor
final class ColorSamplerController {
    enum Feedback: Equatable {
        case copied(SampledColor)
        case permissionDenied
        case busy
        case failed(String)
    }

    typealias PointSelector = @MainActor () async throws -> ScreenRegionSelector.Selection
    typealias FeedbackHandler = @MainActor (Feedback) -> Void

    static let shared = ColorSamplerController()
    nonisolated static let formatDefaultsKey = "colorPickerFormat"

    private let selectPoint: PointSelector
    private let pasteboard: NSPasteboard
    private let format: () -> ColorClipboardFormat
    private let feedback: FeedbackHandler

    /// Bumped on every accepted request; a completion whose generation no
    /// longer matches is discarded instead of overwriting a newer result.
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var isSampling = false

    init(selectPoint: @escaping PointSelector = {
             try await ScreenRegionSelector.shared.select(mode: .point)
         },
         pasteboard: NSPasteboard = .general,
         format: @escaping () -> ColorClipboardFormat = { ColorSamplerController.storedFormat() },
         feedback: @escaping FeedbackHandler = { ColorSamplerController.present($0) }) {
        self.selectPoint = selectPoint
        self.pasteboard = pasteboard
        self.format = format
        self.feedback = feedback
    }

    /// Opens the loupe and copies the colour under the click. A second call
    /// while the selector is open is a no-op with a notice: reopening would
    /// cancel the user's pick.
    func sample() {
        guard isSampling == false else {
            feedback(.busy)
            return
        }
        // The selector captures the screen: a notice still on it would end up in
        // the loupe.
        HUDController.shared.hide()
        generation &+= 1
        let generation = generation
        task?.cancel()
        isSampling = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.finish(generation) }
            do {
                try Task.checkCancellation()
                let selection = try await self.selectPoint()
                self.isSampling = false
                try Task.checkCancellation()
                guard let image = selection.image,
                      let color = SampledColor(image: image) else {
                    self.publish(.failed("The pixel could not be read."), generation: generation)
                    return
                }
                guard self.copy(self.format().string(for: color)) else {
                    self.publish(.failed("The colour could not be copied."), generation: generation)
                    return
                }
                self.publish(.copied(color), generation: generation)
            } catch is CancellationError {
                // Superseded by a newer request: stay quiet.
            } catch ScreenRegionError.cancelled {
                // Esc: the user asked for nothing.
            } catch ScreenRegionError.alreadySelecting {
                self.publish(.busy, generation: generation)
            } catch ScreenRegionError.permissionDenied {
                self.publish(.permissionDenied, generation: generation)
            } catch {
                self.publish(.failed(error.localizedDescription), generation: generation)
            }
        }
    }

    nonisolated static func storedFormat(defaults: UserDefaults = .standard) -> ColorClipboardFormat {
        defaults.string(forKey: formatDefaultsKey)
            .flatMap(ColorClipboardFormat.init(rawValue:)) ?? .hex
    }

    private func copy(_ text: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    private func publish(_ feedback: Feedback, generation: UInt64) {
        guard self.generation == generation else { return }
        self.feedback(feedback)
    }

    private func finish(_ generation: UInt64) {
        guard self.generation == generation else { return }
        isSampling = false
        task = nil
    }

    // MARK: - Default presentation

    private static func present(_ feedback: Feedback) {
        switch feedback {
        case let .copied(color):
            HUDController.shared.show(
                color.hex,
                symbol: "eyedropper",
                detail: "\(color.rgb) · \(color.hexWithAlpha)",
                duration: 2.5
            )
            WorkspaceStore.shared.status = "Colour \(color.hex) copied"
        case .permissionDenied:
            HUDController.shared.show(
                "Screen Recording permission required",
                symbol: "exclamationmark.triangle.fill",
                detail: "Grant it in Settings ▸ General, then try again.",
                duration: 3
            )
            WorkspaceStore.shared.status = "Screen Recording permission required"
        case .busy:
            HUDController.shared.show("The colour picker is already open",
                                      symbol: "hand.raised.fill")
        case let .failed(message):
            let short = message.count > 80 ? String(message.prefix(80)) + "…" : message
            HUDController.shared.show("Colour not copied: \(short)",
                                      symbol: "exclamationmark.triangle.fill",
                                      duration: 3)
        }
    }
}
