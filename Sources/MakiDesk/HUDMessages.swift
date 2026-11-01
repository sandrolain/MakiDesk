import Foundation

/// The notices of the capture family — text, colour, measure, screenshots —
/// written once (R04).
///
/// One member per situation, with its parameters typed. The title, the symbol
/// and the severity live here rather than at the call site, so the same
/// sentence cannot be written twice with two spellings, and a test can walk the
/// list.
extension HUDMessage {
    // MARK: - Shared by more than one tool

    /// Three tools can be busy with a selection at the same time.
    static let selectionAlreadyOpen = HUDMessage(
        title: "A selection is already open",
        symbol: "hand.raised.fill"
    )

    /// Window previews, text recognition, colour, measure and the peeks all
    /// need the same grant, and say so the same way.
    static let screenRecordingRequired = HUDMessage(
        title: "Screen Recording permission required",
        symbol: "exclamationmark.triangle.fill",
        detail: "Grant it in Settings ▸ General, then try again."
    )

    // MARK: - Text recognition

    static func textCopied(size: String, preview: String,
                           to output: TextRecognitionOutput) -> HUDMessage {
        let title: String
        switch output {
        case .pasteboard:
            title = "Text copied · \(size)"
        case .pasteboardAndHistory:
            title = "Text copied · \(size) · ⌥V keeps it"
        case .historyOnly:
            title = "Text in clipboard history · \(size) · ⌥V"
        }
        return HUDMessage(title: title, symbol: "text.viewfinder", detail: preview)
    }

    static let noTextFound = HUDMessage(
        title: "No text found",
        symbol: "text.magnifyingglass"
    )

    /// The detector itself can fail to load (Vision/E5RT), which is a different
    /// problem from a failed read and says so.
    static func textFailed(reason: String, detectorCouldNotStart: Bool) -> HUDMessage {
        HUDMessage(
            title: detectorCouldNotStart
                ? "The text detector could not start — restarting the Mac usually clears it"
                : "Text recognition failed",
            symbol: "exclamationmark.triangle.fill",
            detail: reason,
            kind: .warning
        )
    }

    // MARK: - Colour

    static let colourPickerAlreadyOpen = HUDMessage(
        title: "The colour picker is already open",
        symbol: "hand.raised.fill"
    )

    static func colourPicked(hex: String, detail: String) -> HUDMessage {
        HUDMessage(title: hex, symbol: "eyedropper", detail: detail)
    }

    static func colourNotCopied(reason: String) -> HUDMessage {
        HUDMessage(title: "Colour not copied: \(reason)",
                  symbol: "exclamationmark.triangle.fill")
    }

    // MARK: - Measure

    static let noDisplayForMeasuring = HUDMessage(
        title: "No display is available for measuring",
        symbol: "display.trianglebadge.exclamationmark"
    )

    static func measureFailed(reason: String) -> HUDMessage {
        HUDMessage(title: "Could not measure: \(reason)",
                  symbol: "exclamationmark.triangle.fill")
    }

    static let measurementCopyFailed = HUDMessage(
        title: "The measurement could not be copied",
        symbol: "exclamationmark.triangle.fill"
    )

    static func measurementCopied(detail: String) -> HUDMessage {
        HUDMessage(title: "Measurement copied", symbol: "ruler", detail: detail)
    }

    // MARK: - Annotated screenshots

    static let areaCaptureFailed = HUDMessage(
        title: "The area could not be captured",
        symbol: "exclamationmark.triangle.fill"
    )

    static let noWindowToCapture = HUDMessage(
        title: "No window to capture",
        symbol: "exclamationmark.triangle.fill",
        kind: .warning
    )

    static let noDisplayToCapture = HUDMessage(
        title: "No display to capture",
        symbol: "exclamationmark.triangle.fill",
        kind: .warning
    )

    /// What became of an image the user marked up and saved.
    static func screenshotSaved(onTheShelf: Bool) -> HUDMessage {
        HUDMessage(
            title: onTheShelf ? "Screenshot on the shelf" : "Screenshot annotated",
            symbol: onTheShelf ? "photo" : "exclamationmark.triangle.fill",
            kind: onTheShelf ? .success : .warning
        )
    }

    /// The notice that follows a screenshot macOS itself saved.
    static func systemScreenshotSaved(named name: String) -> HUDMessage {
        HUDMessage(title: "Screenshot saved", symbol: "camera.viewfinder",
                   detail: name, kind: .info)
    }

    /// Every member a test can walk: the ones with no parameters. The
    /// factories are checked through their own tests.
    static let catalogue: [HUDMessage] = [
        selectionAlreadyOpen, screenRecordingRequired, noTextFound,
        colourPickerAlreadyOpen, noDisplayForMeasuring, measurementCopyFailed,
        areaCaptureFailed, noWindowToCapture, noDisplayToCapture,
    ]
}
