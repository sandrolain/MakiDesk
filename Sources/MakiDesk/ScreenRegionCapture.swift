import CoreGraphics
import ScreenCaptureKit

/// Failures of the shared region selector (T49). Each case is something the
/// caller must tell the user about, so they stay distinct instead of collapsing
/// into `nil`.
enum ScreenRegionError: Error, Equatable, LocalizedError {
    case cancelled
    case alreadySelecting
    case permissionDenied
    case displayUnavailable
    case emptySelection
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Selection cancelled."
        case .alreadySelecting:
            return "Another selection is already open."
        case .permissionDenied:
            return "Screen Recording is required to read the screen."
        case .displayUnavailable:
            return "The display is not available for capture."
        case .emptySelection:
            return "The selected area is empty."
        case let .captureFailed(message):
            return "Could not capture the screen: \(message)"
        }
    }
}

/// Still capture of one display, shared by the region selector, the OCR source
/// (T41) and the capture/annotation source (T40).
///
/// The selector captures the whole display and crops locally: a `sourceRect`
/// on the stream configuration would save memory, but it needs the display's
/// own pixel grid and is the part most likely to be off by a pixel or a flipped
/// origin. One full image and pure geometry is easier to verify.
enum ScreenRegionCapture {
    /// The same permission probe the palette uses, so the app has one answer.
    static var isAuthorized: Bool { WindowCapture.isAuthorized }

    @discardableResult
    static func requestAuthorization() -> Bool { WindowCapture.requestAuthorization() }

    /// Captures `display` at its native pixel size, leaving out the app's own
    /// windows: the selection overlay is on screen while the capture happens,
    /// and must not appear in the image, the loupe or the cropped result.
    static func capture(display: ScreenRegionDisplay,
                        excluding windowNumbers: [CGWindowID] = []) async throws -> CGImage {
        guard isAuthorized else { throw ScreenRegionError.permissionDenied }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            throw ScreenRegionError.captureFailed(error.localizedDescription)
        }

        guard let screen = content.displays.first(where: { $0.displayID == display.id }) else {
            throw ScreenRegionError.displayUnavailable
        }
        let excluded = Set(windowNumbers)
        let windows = excluded.isEmpty ? [] : content.windows.filter { excluded.contains($0.windowID) }
        let filter = SCContentFilter(display: screen, excludingWindows: windows)

        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((display.frame.width * display.scale).rounded()))
        configuration.height = max(1, Int((display.frame.height * display.scale).rounded()))
        configuration.showsCursor = false
        configuration.capturesAudio = false

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration
            )
        } catch {
            throw ScreenRegionError.captureFailed(error.localizedDescription)
        }
    }

    /// The crop of a global rectangle, at native pixel size.
    static func image(of rect: CGRect, in display: ScreenRegionDisplay,
                      from source: CGImage) throws -> CGImage {
        let local = ScreenRegionGeometry.displayLocalRect(rect, in: display)
        let pixels = ScreenRegionGeometry.pixelRect(
            for: local,
            imageSize: CGSize(width: source.width, height: source.height),
            displaySize: display.frame.size
        )
        guard pixels.width >= 1, pixels.height >= 1,
              let cropped = source.cropping(to: pixels) else {
            throw ScreenRegionError.emptySelection
        }
        return cropped
    }
}
