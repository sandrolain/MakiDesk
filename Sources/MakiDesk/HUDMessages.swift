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

    // MARK: - Calculation

    static func calculationCopied(_ result: String) -> HUDMessage {
        HUDMessage(title: "\(result) copied", symbol: "equal.circle")
    }

    // MARK: - Ports

    static func portTerminated(name: String, pid: Int32) -> HUDMessage {
        HUDMessage(title: "SIGTERM sent to \(name)", symbol: "xmark.circle",
                   detail: "pid \(pid)")
    }

    static func portTerminateFailed(reason: String) -> HUDMessage {
        HUDMessage(title: "Could not terminate the process",
                   symbol: "exclamationmark.triangle.fill",
                   detail: reason)
    }

    // MARK: - Utility bar

    static func utilityBarIsOff() -> HUDMessage {
        HUDMessage(title: "The utility bar is off",
                   symbol: "rectangle.topthird.inset.filled",
                   detail: "Turn it on in Settings ▸ Panels ▸ Utility bar.")
    }

    // MARK: - Terminal

    static func terminalNotification(title: String, detail: String?) -> HUDMessage {
        HUDMessage(title: title, symbol: "terminal", detail: detail)
    }

    static func terminalNotInstalled() -> HUDMessage {
        HUDMessage(title: "Terminal helper not found",
                   symbol: "terminal",
                   detail: "Build it with task terminal:bundle.")
    }

    static func terminalDidNotAnswer() -> HUDMessage {
        HUDMessage(title: "The terminal did not answer",
                   symbol: "exclamationmark.triangle.fill",
                   detail: "Try again; the helper may have stopped.")
    }

    static func terminalVersionMismatch() -> HUDMessage {
        HUDMessage(title: "Terminal version mismatch",
                   symbol: "exclamationmark.triangle.fill",
                   detail: "Quit the terminal and open it again.")
    }

    // MARK: - Docker

    static func dockerNotInstalled() -> HUDMessage {
        HUDMessage(title: "Docker helper not found",
                   symbol: "shippingbox",
                   detail: "Build it with task docker:bundle.")
    }

    static func dockerDidNotAnswer() -> HUDMessage {
        HUDMessage(title: "The Docker window did not answer",
                   symbol: "exclamationmark.triangle.fill",
                   detail: "Try again; the helper may have stopped.")
    }

    static func dockerVersionMismatch() -> HUDMessage {
        HUDMessage(title: "Docker helper version mismatch",
                   symbol: "exclamationmark.triangle.fill",
                   detail: "Quit the Docker window and open it again.")
    }

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

    static let noImageOnClipboard = HUDMessage(
        title: "No image on the clipboard",
        symbol: "photo.on.rectangle.angled"
    )

    static let clipboardImageConcealed = HUDMessage(
        title: "The copied image is marked private",
        symbol: "lock"
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

    static let insertedInNotes = HUDMessage(title: "Sent to a new note", symbol: "note.text")

    static let noteInsertionFailed = HUDMessage(
        title: "Could not add the text",
        symbol: "exclamationmark.triangle.fill",
        detail: "The note could not be loaded."
    )

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

    // MARK: - Pointer

    static func pointerEffects(active: Bool, minutes: Int? = nil) -> HUDMessage {
        let detail: String? = {
            guard active, let minutes else { return nil }
            let window = minutes > PointerEffectSettings.unlimitedPresentationMinutes
                ? "\(minutes) min"
                : "No time limit"
            return "\(window) · press the shortcut again to stop"
        }()
        return HUDMessage(title: active ? "Pointer effects on" : "Pointer effects off",
                          symbol: "circle.dashed", detail: detail)
    }

    static let pointerEffectsEnded = HUDMessage(
        title: "Pointer effects ended",
        symbol: "circle.dashed",
        detail: "The presentation window is over."
    )

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

    // MARK: - Recording

    static func recordingFailed(reason: String?) -> HUDMessage {
        HUDMessage(title: reason ?? "The recording could not be saved",
                   symbol: "exclamationmark.triangle.fill", kind: .warning)
    }

    static func recordingSaved(duration: String) -> HUDMessage {
        HUDMessage(title: "Recording on the shelf · \(duration)",
                   symbol: "record.circle", kind: .success)
    }

    static func recordingStarted(duration: String) -> HUDMessage {
        HUDMessage(title: "Recording \(duration)", symbol: "record.circle")
    }

    // MARK: - Progress

    static let readingText = HUDMessage(title: "Reading text…", symbol: "text.viewfinder")
    static let receivingFiles = HUDMessage(
        title: "Receiving files…", symbol: "arrow.down.circle")
    static let transferringItems = HUDMessage(
        title: "Transferring shelf items…", symbol: "folder")

    // MARK: - Panels

    static let clipboardSecureInput = HUDMessage(
        title: "Clipboard history is off while secure input is active", symbol: "lock.fill")

    static let clipboardWriteFailed = HUDMessage(
        title: "Could not write to the clipboard", symbol: "exclamationmark.triangle.fill")

    static let clipboardImageBudgetFull = HUDMessage(
        title: "Clipboard image not kept",
        symbol: "exclamationmark.triangle.fill",
        detail: "The image is larger than the budget, or pinned images fill it."
    )

    static let clipboardNeedsAccessibility = HUDMessage(
        title: "Accessibility not granted · the item is on the clipboard",
        symbol: "exclamationmark.triangle.fill")

    static func timerFinished(label: String, ranOutWhileClosed: String?) -> HUDMessage {
        HUDMessage(title: "Time's up · \(label)", symbol: "timer",
                   detail: ranOutWhileClosed, kind: .warning)
    }

    static func intervalRanOutWhileClosed(when: String?) -> String {
        when.map { "It ran out while MakiDesk was closed (\($0))." }
            ?? "It ran out while MakiDesk was closed."
    }

    static func timerNotStarted(reason: String) -> HUDMessage {
        HUDMessage(title: reason, symbol: "exclamationmark.triangle.fill")
    }

    static func applicationCouldNotOpen(name: String) -> HUDMessage {
        HUDMessage(title: "Could not open \(name)", symbol: "exclamationmark.triangle.fill")
    }

    // MARK: - System monitor

    static func diskSpaceLow(free: String, total: String, percent: String) -> HUDMessage {
        HUDMessage(
            title: "Low disk space · \(free) free",
            symbol: "externaldrive.badge.exclamationmark",
            detail: "The start-up disk has \(free) free of \(total) (\(percent)). Storage settings can free more.",
            kind: .warning
        )
    }

    static func processHighCPU(name: String, percent: String, cores: String,
                               sustained: String, top: [ProcessReading]) -> HUDMessage {
        HUDMessage(
            title: "\(name) is using \(percent) CPU",
            symbol: "gauge.with.dots.needle.67percent",
            detail: detailLine("Sustained for \(sustained) (\(cores)).", top: top),
            kind: .warning
        )
    }

    static func systemHighCPU(percent: String, sustained: String,
                              top: [ProcessReading]) -> HUDMessage {
        HUDMessage(
            title: "System processes are using \(percent) CPU",
            symbol: "gauge.with.dots.needle.67percent",
            detail: detailLine("Sustained for \(sustained) with no single app to blame.", top: top),
            kind: .warning
        )
    }

    static func cpuAlertSnoozed(name: String) -> HUDMessage {
        HUDMessage(title: "CPU alerts for \(name) snoozed for an hour", symbol: "bell.slash")
    }

    static let systemNotificationsDenied = HUDMessage(
        title: "System notifications are off for MakiDesk",
        symbol: "bell.slash",
        detail: "Allow them in System Settings ▸ Notifications, or keep the in-app notice.",
        kind: .warning
    )

    static let systemNotificationsUnavailable = HUDMessage(
        title: "System notifications need the app bundle",
        symbol: "bell.slash",
        detail: "Run MakiDesk as an app to use Notification Center; the in-app notice works everywhere.",
        kind: .warning
    )

    /// The line under a CPU notice: how long, and what else is busy. The
    /// process in the title is left out by the caller, so it is not repeated.
    private static func detailLine(_ sentence: String, top: [ProcessReading]) -> String {
        let others = top
            .filter { $0.cpuPercent >= 20 }
            .prefix(2)
            .map { "\($0.name) \($0.percentText)" }
        guard others.isEmpty == false else { return sentence }
        return "\(sentence) Also busy: \(others.joined(separator: " · "))."
    }

    /// Every member a test can walk: the ones with no parameters. The
    /// factories are checked through their own tests.
    static let catalogue: [HUDMessage] = [
        selectionAlreadyOpen, screenRecordingRequired, noTextFound,
        noImageOnClipboard, clipboardImageConcealed,
        colourPickerAlreadyOpen, noDisplayForMeasuring, measurementCopyFailed,
        areaCaptureFailed, noWindowToCapture, noDisplayToCapture,
        shelfFull, shelfTextTooLarge, shelfImageTooLarge, shelfImageNotPrepared,
        nothingToPreview, shelfSomeFilesGone, shelfNotOpen, shelfSelectSomething,
        nothingRunnableInSelection, noTextInSelection, insertedInNotes,
        noteInsertionFailed,
        noDropzoneAccepts, dropzoneRejectsItems, dropzoneStripHint,
        outputOnClipboard, outputAddedToShelf,
        shortcutsRestored, switcherSnapHint, accessibilityNotGranted, noWindow,
        nothingInUse, nothingLeftInUse, nothingPutAway, everythingBack,
        nothingToUndo, undone, peekCleared, peekNotDesignated,
        peekNeedsScreenRecording, peekNoLongerOpen, nothingToArrange,
        clipboardSecureInput, clipboardWriteFailed, clipboardNeedsAccessibility,
        clipboardImageBudgetFull,
        readingText, receivingFiles, transferringItems,
        systemNotificationsDenied, systemNotificationsUnavailable,
    ]
}
