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

    var nsColor: String {
        func component(_ value: UInt8) -> String {
            String(format: "%.3f", Double(value) / 255)
        }
        return "NSColor(srgbRed: \(component(red)), green: \(component(green)), "
            + "blue: \(component(blue)), alpha: \(component(alpha)))"
    }
}

/// What the colour picker puts on the clipboard (T36). Persisted by raw value
/// in Settings ▸ Panels.
enum ColorClipboardFormat: String, CaseIterable, Identifiable, Sendable {
    case hex
    case hexWithAlpha
    case rgb
    case nsColor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hex: return "Hex — #RRGGBB"
        case .hexWithAlpha: return "Hex with alpha — #RRGGBBAA"
        case .rgb: return "RGB — rgb(r, g, b)"
        case .nsColor: return "NSColor — Swift"
        }
    }

    func string(for color: SampledColor) -> String {
        switch self {
        case .hex: return color.hex
        case .hexWithAlpha: return color.hexWithAlpha
        case .rgb: return color.rgb
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
                guard let color = SampledColor(image: selection.image) else {
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
