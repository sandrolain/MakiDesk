import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Where the recognized text goes (T54). There is deliberately no "nowhere":
/// the text is the whole result, and losing it would waste the selection.
enum TextRecognitionOutput: String, CaseIterable, Identifiable, Sendable {
    case pasteboard
    case pasteboardAndHistory
    case historyOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pasteboard: return "Clipboard"
        case .pasteboardAndHistory: return "Clipboard and history"
        case .historyOnly: return "History only"
        }
    }

    var writesPasteboard: Bool { self != .historyOnly }
    var writesHistory: Bool { self != .pasteboard }
}

/// When the clipboard panel opens after OCR (T54), if ever.
enum OCRRevealHistory: String, CaseIterable, Identifiable, Sendable {
    case never
    case historyOnly
    case always

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: return "Never"
        case .historyOnly: return "Only when the text is not copied"
        case .always: return "Always"
        }
    }

    func shouldReveal(for output: TextRecognitionOutput) -> Bool {
        switch self {
        case .never: return false
        case .always: return true
        case .historyOnly: return output == .historyOnly
        }
    }
}

/// Where the picture to read comes from (T41). The area is the command; the
/// others are the menu's fallbacks for when dragging is in the way.
enum TextRecognitionSource: String, CaseIterable, Identifiable, Sendable {
    case area
    case windowUnderPointer
    case frontmostWindow
    case wholeScreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .area: return "from the Selected Area"
        case .windowUnderPointer: return "from the Window Under the Pointer"
        case .frontmostWindow: return "from the Frontmost Window"
        case .wholeScreen: return "from the Whole Screen"
        }
    }

    /// The sources that take a picture, and so need Screen Recording.
    var needsScreenRecording: Bool { true }
}

/// The OCR command (T41): take a picture of an area, a window or a screen —
/// or read an image the user already has — recognize its text with Vision,
/// deliver it to the clipboard or the in-memory history and report the result.
/// Nothing leaves the process and nothing is written to disk.
@MainActor
final class TextRecognitionController {
    enum Feedback: Equatable {
        case copied(TextRecognitionResult, TextRecognitionOutput)
        case noText
        case cancelled
        case permissionDenied
        case busy
        case failed(String)
    }

    typealias RegionSelector = @MainActor () async throws -> ScreenRegionSelector.Selection
    typealias SourceCapture = @MainActor (TextRecognitionSource) async throws -> CGImage
    /// Says whether the "reading" notice is up: true when the work starts, false
    /// when it ends. Injected so the tests never build a panel.
    typealias ProgressHandler = @MainActor (_ running: Bool) -> Void
    typealias FeedbackHandler = @MainActor (Feedback) -> Void
    typealias PIDProvider = @MainActor () -> pid_t?
    typealias HistoryPresenter = @MainActor () -> Void

    static let shared = TextRecognitionController()

    private let recognizer: TextRecognizing
    private let pasteboard: NSPasteboard
    private let history: ClipboardHistory
    private let selectRegion: RegionSelector
    private let captureSource: SourceCapture
    private let progress: ProgressHandler
    private let frontmostPID: PIDProvider
    private let secureInput: () -> Bool
    private let showHistory: HistoryPresenter
    private let feedback: FeedbackHandler

    /// Bumped on every accepted request; a completion whose generation no
    /// longer matches is discarded instead of overwriting a newer result.
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var isSelecting = false

    init(recognizer: TextRecognizing = TextRecognizer(),
         pasteboard: NSPasteboard = .general,
         history: ClipboardHistory? = nil,
         selectRegion: @escaping RegionSelector = { try await ScreenRegionSelector.shared.select() },
         captureSource: @escaping SourceCapture = TextRecognitionController.capture,
         progress: @escaping ProgressHandler = TextRecognitionController.showProgressNotice,
         frontmostPID: @escaping PIDProvider = {
             NSWorkspace.shared.frontmostApplication?.processIdentifier
         },
         secureInput: @escaping () -> Bool = { IsSecureEventInputEnabled() },
         showHistory: @escaping HistoryPresenter = { ClipboardController.shared.show() },
         feedback: @escaping FeedbackHandler = { TextRecognitionController.present($0) }) {
        self.recognizer = recognizer
        self.pasteboard = pasteboard
        self.history = history ?? .shared
        self.selectRegion = selectRegion
        self.captureSource = captureSource
        self.progress = progress
        self.frontmostPID = frontmostPID
        self.secureInput = secureInput
        self.showHistory = showHistory
        self.feedback = feedback
    }

    /// Opens the area selector and delivers the recognized text. Calling it
    /// while the selector is already open is a no-op with a notice: reopening
    /// would cancel and restart the user's drag.
    func recognizeArea(options: TextRecognitionOptions = .standard,
                       output: TextRecognitionOutput = .pasteboardAndHistory,
                       reveal: OCRRevealHistory = .never) {
        recognize(.area, options: options, output: output, reveal: reveal)
    }

    /// The command the menu uses: the store's settings decide where the text
    /// goes, as they do for the area shortcut.
    func recognize(_ source: TextRecognitionSource) {
        let store = WorkspaceStore.shared
        recognize(source, options: store.textRecognitionOptions,
                  output: store.ocrOutput, reveal: store.ocrRevealHistory)
    }

    /// Text from an image the user already has — a shelf row, a screenshot in
    /// the library: no capture and no permission at all (T41).
    func recognize(image: CGImage) {
        let store = WorkspaceStore.shared
        start(capture: nil, image: image, options: store.textRecognitionOptions,
              output: store.ocrOutput, reveal: store.ocrRevealHistory)
    }

    func recognize(_ source: TextRecognitionSource,
                   options: TextRecognitionOptions,
                   output: TextRecognitionOutput,
                   reveal: OCRRevealHistory) {
        // The area keeps its own seam: the selector, with its snapping and its
        // cancellation. The other sources go through the capture provider.
        let capture: @MainActor () async throws -> CGImage
        if source == .area {
            capture = { [selectRegion] in
                guard let image = try await selectRegion().image else {
                    throw TextRecognitionError.captureFailed
                }
                return image
            }
        } else {
            capture = { [captureSource] in try await captureSource(source) }
        }
        start(capture: capture, image: nil, options: options, output: output, reveal: reveal)
    }

    func recognizeImage(_ image: CGImage,
                        options: TextRecognitionOptions = .standard,
                        output: TextRecognitionOutput = .pasteboardAndHistory,
                        reveal: OCRRevealHistory = .never) {
        start(capture: nil, image: image, options: options, output: output, reveal: reveal)
    }

    /// The one pipeline: a picture (taken or given), recognized once, delivered
    /// once, with the generation checked at publication.
    private func start(capture: (@MainActor () async throws -> CGImage)?,
                       image: CGImage?,
                       options: TextRecognitionOptions,
                       output: TextRecognitionOutput,
                       reveal: OCRRevealHistory) {
        guard isSelecting == false else {
            feedback(.busy)
            return
        }
        // The selector captures the display: a notice still on screen would be
        // part of the loupe and possibly of the recognized area.
        HUDController.shared.hide()
        generation &+= 1
        let generation = generation
        task?.cancel()
        isSelecting = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.finish(generation) }
            // The notice belongs to this request: a superseded task must not
            // take down the notice of the one that replaced it.
            var showingProgress = false
            defer {
                if showingProgress, self.generation == generation { self.progress(false) }
            }
            do {
                try Task.checkCancellation()
                let picture: CGImage
                if let image {
                    picture = image
                } else if let capture {
                    picture = try await capture()
                } else {
                    self.publish(.failed("Nothing to read."), generation: generation)
                    return
                }
                self.isSelecting = false
                // Reading a large capture takes a moment: say so, instead of
                // leaving an empty screen after the selection (T41).
                self.progress(true)
                showingProgress = true
                // The selector restores the previous app: remember who that is,
                // so the history panel never steals focus after a switch (T54).
                let foregroundPID = self.frontmostPID()
                try Task.checkCancellation()
                let result = try await self.recognizer.recognize(picture, options: options)
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                self.progress(false)
                showingProgress = false
                self.deliver(result, output: output, reveal: reveal,
                             generation: generation, foregroundPID: foregroundPID)
            } catch is CancellationError {
                // Superseded by a newer request: stay quiet.
            } catch ScreenRegionError.cancelled {
                // Esc or a click without a drag: the user asked for nothing.
            } catch ScreenRegionError.alreadySelecting {
                self.publish(.busy, generation: generation)
            } catch ScreenRegionError.permissionDenied {
                self.publish(.permissionDenied, generation: generation)
            } catch TextRecognitionError.noText {
                self.publish(.noText, generation: generation)
            } catch {
                self.publish(.failed(error.localizedDescription), generation: generation)
            }
        }
    }

    /// Where the text goes, once it exists. The only place the pasteboard, the
    /// history and the optional history reveal are decided.
    private func deliver(_ result: TextRecognitionResult,
                         output: TextRecognitionOutput,
                         reveal: OCRRevealHistory,
                         generation: UInt64,
                         foregroundPID: pid_t?) {
        switch output {
        case .pasteboard:
            guard copy(result.text) else {
                feedback(.failed("The text could not be copied."))
                return
            }
            // The poll must not add a second entry for our own copy.
            history.markPasteboardSeen()
        case .pasteboardAndHistory:
            guard copy(result.text) else {
                feedback(.failed("The text could not be copied."))
                return
            }
            history.insert(result.text)
            history.markPasteboardSeen()
        case .historyOnly:
            // An explicit OCR request wins over the poll's secure-input guard:
            // the user asked for this text. The history panel still refuses to
            // open while secure input is active.
            history.insert(result.text)
        }
        feedback(.copied(result, output))
        if reveal.shouldReveal(for: output),
           self.generation == generation,
           frontmostPID() == foregroundPID {
            showHistory()
        }
    }

    /// The "reading" notice, one at a time like the work itself. A second
    /// request replaces the first notice, which is why the id is kept.
    private static var progressID: UUID?

    static func showProgressNotice(_ running: Bool) {
        if running {
            progressID = HUDController.shared.showProgress("Reading text…",
                                                           symbol: "text.viewfinder")
        } else if let id = progressID {
            HUDController.shared.finishProgress(id)
            progressID = nil
        }
    }

    // MARK: - Capturing a source

    /// Takes the picture for a source: the selector for an area, a window
    /// capture for a window, one display for the whole screen (T41).
    @MainActor
    static func capture(_ source: TextRecognitionSource) async throws -> CGImage {
        switch source {
        case .area:
            let selection = try await ScreenRegionSelector.shared.select()
            guard let image = selection.image else { throw TextRecognitionError.captureFailed }
            return image
        case .windowUnderPointer, .frontmostWindow:
            let target: (pid: pid_t, frame: CGRect)
            switch source {
            case .frontmostWindow:
                guard let window = WindowController.frontmostWindow() else {
                    throw TextRecognitionError.noWindow
                }
                target = (window.pid, window.frame)
            default:
                let point = CGPoint(x: NSEvent.mouseLocation.x,
                                    y: WindowController.primaryHeight - NSEvent.mouseLocation.y)
                guard let entry = windowUnderPointer(in: WindowController.onScreenStack(),
                                                     at: point,
                                                     ownPID: ProcessInfo.processInfo.processIdentifier) else {
                    throw TextRecognitionError.noWindow
                }
                target = (entry.pid, entry.frame)
            }
            guard let image = await WindowCapture.captureWindow(pid: target.pid, near: target.frame,
                                                                maxDimension: 3000),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw TextRecognitionError.captureFailed
            }
            return cgImage
        case .wholeScreen:
            guard let screen = pointerScreen() else { throw TextRecognitionError.captureFailed }
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { throw TextRecognitionError.captureFailed }
            let display = ScreenRegionDisplay(
                id: CGDirectDisplayID(number.uint32Value),
                frame: WindowController.flip(screen.frame),
                scale: screen.backingScaleFactor
            )
            return try await ScreenRegionCapture.capture(display: display)
        }
    }

    /// The frontmost ordinary window under a point, in window-server
    /// coordinates. Pure, so the rule can be checked without a desktop.
    static func windowUnderPointer(in stack: [WindowController.CGWindowEntry],
                                   at point: CGPoint,
                                   ownPID: pid_t) -> WindowController.CGWindowEntry? {
        stack.first { entry in
            entry.pid != ownPID
                && entry.layer == 0
                && entry.alpha > 0.01
                && entry.frame.width >= 40
                && entry.frame.height >= 40
                && entry.frame.contains(point)
        }
    }

    private static func pointerScreen() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func publish(_ feedback: Feedback, generation: UInt64) {
        guard self.generation == generation else { return }
        self.feedback(feedback)
    }

    /// Secure input means a password field has the keyboard, so the text read
    /// from the screen may be a secret: the pasteboard entry is marked
    /// concealed and clipboard managers that honour the convention skip it.
    private func copy(_ text: String) -> Bool {
        let concealed = secureInput()
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        if concealed {
            pasteboard.setData(Data(), forType: ClipboardHistory.concealedMarker)
        }
        return true
    }

    private func finish(_ generation: UInt64) {
        guard self.generation == generation else { return }
        isSelecting = false
        task = nil
    }

    // MARK: - Default presentation

    private static func present(_ feedback: Feedback) {
        switch feedback {
        case let .copied(result, output):
            let size = result.characterCount == 1
                ? "1 character" : "\(result.characterCount) characters"
            let title: String
            switch output {
            case .pasteboard:
                title = "Text copied · \(size)"
            case .pasteboardAndHistory:
                title = "Text copied · \(size) · ⌥V keeps it"
            case .historyOnly:
                title = "Text in clipboard history · \(size) · ⌥V"
            }
            // The text is in the clipboard (or the history); these are the two
            // places it is usually wanted next, plus a copy for the case where
            // it was not copied at all (T41).
            var actions: [HUDAction] = [
                HUDAction(title: "Send to Note") { NotesController.shared.insertText(result.text) },
                HUDAction(title: "Send to Shelf") { ShelfController.shared.add(text: result.text) }
            ]
            if output == .historyOnly {
                actions.append(HUDAction(title: "Copy") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(result.text, forType: .string)
                })
            }
            HUDController.shared.show(title, symbol: "text.viewfinder",
                                      detail: result.preview, actions: actions)
            WorkspaceStore.shared.status = title
        case .noText:
            HUDController.shared.show("No text found", symbol: "text.magnifyingglass")
            WorkspaceStore.shared.status = "No text found"
        case .cancelled:
            break
        case .permissionDenied:
            HUDController.shared.show(
                "Screen Recording permission required",
                symbol: "exclamationmark.triangle.fill",
                detail: "Grant it in Settings ▸ General, then try again."
            )
            WorkspaceStore.shared.status = "Screen Recording permission required"
        case .busy:
            HUDController.shared.show("A selection is already open",
                                      symbol: "hand.raised.fill")
        case let .failed(message):
            let short = message.count > 80 ? String(message.prefix(80)) + "…" : message
            HUDController.shared.show("Text recognition failed: \(short)",
                                      symbol: "exclamationmark.triangle.fill")
            WorkspaceStore.shared.status = "Text recognition failed"
        }
    }
}
