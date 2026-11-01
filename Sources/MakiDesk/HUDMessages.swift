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

    // MARK: - Shelf

    static let shelfFull = HUDMessage(
        title: "Shelf limit reached (100 items)",
        symbol: "exclamationmark.triangle.fill"
    )

    static let shelfTextTooLarge = HUDMessage(
        title: "Text exceeds the shelf memory limit",
        symbol: "exclamationmark.triangle.fill"
    )

    static let shelfImageTooLarge = HUDMessage(
        title: "Image exceeds the shelf memory limit",
        symbol: "exclamationmark.triangle.fill"
    )

    static let shelfImageNotPrepared = HUDMessage(
        title: "An image could not be prepared for transfer",
        symbol: "exclamationmark.triangle.fill"
    )

    static let nothingToPreview = HUDMessage(title: "Nothing to preview", symbol: "eye.slash")

    static let shelfSomeFilesGone = HUDMessage(
        title: "Some files are no longer available",
        symbol: "exclamationmark.triangle"
    )

    /// The keyboard route to the shelf is only reachable once it is open.
    static let shelfNotOpen = HUDMessage(
        title: "Open the Shelf and select something first",
        symbol: "tray"
    )

    static let shelfSelectSomething = HUDMessage(
        title: "Select something in the Shelf first",
        symbol: "cursorarrow"
    )

    static let nothingRunnableInSelection = HUDMessage(
        title: "Nothing runnable in the selection",
        symbol: "nosign"
    )

    static let noTextInSelection = HUDMessage(
        title: "No text in the selection",
        symbol: "note.text"
    )

    static let insertedInNotes = HUDMessage(title: "Inserted in Notes", symbol: "note.text")

    // MARK: - Transfer

    static func transferCancelled(copied: Int, of total: Int) -> HUDMessage {
        HUDMessage(title: "Transfer cancelled after \(copied) of \(total) items",
                   symbol: "xmark.circle")
    }

    static func transferFinished(moved: Bool, count: Int) -> HUDMessage {
        HUDMessage(title: "\(moved ? "Moved" : "Copied") \(count) items", symbol: "folder")
    }

    static func filesNotReceived(reason: String) -> HUDMessage {
        HUDMessage(title: "Could not receive the files: \(reason)",
                   symbol: "exclamationmark.triangle")
    }

    // MARK: - Dropzones

    static let noDropzoneAccepts = HUDMessage(
        title: "No dropzone accepts these items",
        symbol: "nosign"
    )

    static let dropzoneRejectsItems = HUDMessage(
        title: "This dropzone does not accept these items",
        symbol: "nosign"
    )

    static let dropzoneStripHint = HUDMessage(
        title: "← → choose · ↩ run · Esc back",
        symbol: "bolt.square"
    )

    static func dropzoneStripUnavailable(noneAccept: Bool) -> HUDMessage {
        HUDMessage(title: noneAccept ? "No dropzone accepts these items"
                                     : "Drop on a dropzone tile",
                   symbol: "arrow.up.left")
    }

    static func dropzoneRejected(reason: String) -> HUDMessage {
        HUDMessage(title: reason, symbol: "nosign")
    }

    static func dropzoneCancelled(name: String) -> HUDMessage {
        HUDMessage(title: "\(name) cancelled", symbol: "xmark.circle")
    }

    static func dropzoneTimedOut(name: String) -> HUDMessage {
        HUDMessage(title: "\(name) timed out", symbol: "clock.badge.exclamationmark")
    }

    static func dropzoneFailed(name: String, reason: String) -> HUDMessage {
        HUDMessage(title: reason.isEmpty ? "\(name) failed" : "\(name) failed: \(reason)",
                   symbol: "exclamationmark.triangle")
    }

    static func dropzoneDone(name: String) -> HUDMessage {
        HUDMessage(title: "\(name) done", symbol: "checkmark.circle.fill")
    }

    static func dropzoneChangedDuringConfirmation(name: String) -> HUDMessage {
        HUDMessage(title: "\(name) changed during confirmation; try again",
                   symbol: "exclamationmark.triangle")
    }

    static func dropzoneUnavailable(name: String) -> HUDMessage {
        HUDMessage(title: "\(name) is no longer available", symbol: "questionmark.circle")
    }

    static func dropzoneConfirmationNotSaved(name: String, reason: String) -> HUDMessage {
        HUDMessage(title: "Could not save the confirmation for \(name): \(reason)",
                   symbol: "externaldrive.badge.xmark")
    }

    // MARK: - Output

    static func filesOnClipboard(count: Int) -> HUDMessage {
        HUDMessage(title: count == 1 ? "1 file on the clipboard"
                                     : "\(count) files on the clipboard",
                   symbol: "doc.on.clipboard")
    }

    static let outputOnClipboard = HUDMessage(
        title: "Output on the clipboard",
        symbol: "doc.on.clipboard"
    )

    static func filesAddedToShelf(count: Int) -> HUDMessage {
        HUDMessage(title: count == 1 ? "1 file added to the Shelf"
                                     : "\(count) files added to the Shelf",
                   symbol: "tray.and.arrow.down.fill")
    }

    static let outputAddedToShelf = HUDMessage(
        title: "Output added to the Shelf",
        symbol: "tray.and.arrow.down.fill"
    )

    // MARK: - Shortcuts

    static func shortcutUpdated(title: String, keys: String?) -> HUDMessage {
        HUDMessage(title: "Shortcut updated · \(title)", symbol: "keyboard", detail: keys)
    }

    static func shortcutTurnedOff(title: String) -> HUDMessage {
        HUDMessage(title: "Shortcut turned off · \(title)", symbol: "keyboard")
    }

    static func shortcutRestored(title: String, keys: String?) -> HUDMessage {
        HUDMessage(title: "Shortcut restored · \(title)", symbol: "keyboard", detail: keys)
    }

    static let shortcutsRestored = HUDMessage(title: "Shortcuts restored", symbol: "keyboard")

    static func shortcutsMigrated(from: Int, to: Int, changed: Int) -> HUDMessage {
        HUDMessage(title: "Shortcuts updated · version \(from) → \(to)",
                   symbol: "keyboard",
                   detail: changed == 0 ? nil : "\(changed) row(s) adjusted to the new table")
    }

    static let switcherSnapHint = HUDMessage(
        title: "⌥-click windows in the switcher to keep them sharp",
        symbol: "rectangle.dashed"
    )

    // MARK: - Focus and window state

    static func focusDim(active: Bool) -> HUDMessage {
        HUDMessage(title: active ? "Dimming everything but the focus" : "Focus dim off",
                   symbol: "circle.lefthalf.filled")
    }

    static let accessibilityNotGranted = HUDMessage(
        title: "Accessibility not granted", symbol: "exclamationmark.triangle.fill")

    static let noWindow = HUDMessage(
        title: "No window", symbol: "exclamationmark.triangle.fill")

    static let nothingInUse = HUDMessage(title: "Nothing in use", symbol: "tray")
    static let nothingLeftInUse = HUDMessage(title: "Nothing left in use", symbol: "tray")
    static let nothingPutAway = HUDMessage(title: "Nothing put away", symbol: "eye")
    static let everythingBack = HUDMessage(
        title: "Everything back", symbol: "rectangle.on.rectangle")
    static let nothingToUndo = HUDMessage(
        title: "Nothing to undo", symbol: "arrow.uturn.backward")
    static let undone = HUDMessage(title: "Undone", symbol: "arrow.uturn.backward")

    static func windowNoLongerThere(title: String) -> HUDMessage {
        HUDMessage(title: "\(title) — no window left", symbol: "exclamationmark.triangle.fill")
    }

    static func windowKeepsItsSize(app: String, asked: String, got: String) -> HUDMessage {
        HUDMessage(title: "\(app) keeps its own size\nasked \(asked) · got \(got)",
                   symbol: "exclamationmark.triangle.fill")
    }

    // MARK: - Peek

    static func peekReady(app: String, putAway: Bool) -> HUDMessage {
        HUDMessage(title: "Peek · \(app) — hold ⌃⌥H",
                   symbol: putAway ? "eye.fill" : "exclamationmark.triangle.fill")
    }

    static let peekCleared = HUDMessage(title: "Peek cleared", symbol: "eye.slash")

    static let peekNotDesignated = HUDMessage(
        title: "No window designated — ⌃⌥⌘P on the one to peek at", symbol: "eye.slash")

    static let peekNeedsScreenRecording = HUDMessage(
        title: "Peek needs Screen Recording", symbol: "exclamationmark.triangle.fill")

    static func peekAlreadyOnScreen(app: String) -> HUDMessage {
        HUDMessage(title: "\(app) · already on screen", symbol: "eye")
    }

    static let peekNoLongerOpen = HUDMessage(
        title: "No longer open — ⌃⌥⌘P drops the designation", symbol: "eye.slash")

    // MARK: - Layouts

    static let nothingToArrange = HUDMessage(
        title: "No windows in view to arrange", symbol: "rectangle.on.rectangle.slash")

    static func layoutSuggested(layout: String, summary: String, reason: String) -> HUDMessage {
        HUDMessage(
            title: "Suggested: \(layout) · \(summary)\n\(reason)\nRun Auto again to apply",
            symbol: "wand.and.stars"
        )
    }

    static func layoutApplied(layout: String, summary: String, reason: String) -> HUDMessage {
        HUDMessage(title: "\(layout) · \(summary)\n\(reason)", symbol: "wand.and.stars")
    }

    static let contentNeedsThreeWindows = HUDMessage(
        title: "Content needs at least 3 windows", symbol: "rectangle.3.group")

    static func contentApplied(summary: String) -> HUDMessage {
        HUDMessage(title: "Content · \(summary)", symbol: "rectangle.3.group")
    }

    static func gridApplied(summary: String) -> HUDMessage {
        HUDMessage(title: "Grid · \(summary)", symbol: "square.grid.3x3.fill")
    }

    /// Every member a test can walk: the ones with no parameters. The
    /// factories are checked through their own tests.
    static let catalogue: [HUDMessage] = [
        selectionAlreadyOpen, screenRecordingRequired, noTextFound,
        colourPickerAlreadyOpen, noDisplayForMeasuring, measurementCopyFailed,
        areaCaptureFailed, noWindowToCapture, noDisplayToCapture,
        shelfFull, shelfTextTooLarge, shelfImageTooLarge, shelfImageNotPrepared,
        nothingToPreview, shelfSomeFilesGone, shelfNotOpen, shelfSelectSomething,
        nothingRunnableInSelection, noTextInSelection, insertedInNotes,
        noDropzoneAccepts, dropzoneRejectsItems, dropzoneStripHint,
        outputOnClipboard, outputAddedToShelf,
        shortcutsRestored, switcherSnapHint, accessibilityNotGranted, noWindow,
        nothingInUse, nothingLeftInUse, nothingPutAway, everythingBack,
        nothingToUndo, undone, peekCleared, peekNotDesignated,
        peekNeedsScreenRecording, peekNoLongerOpen, nothingToArrange,
    ]
}
