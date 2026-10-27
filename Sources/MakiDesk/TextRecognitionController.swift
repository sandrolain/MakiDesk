import AppKit
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

/// The OCR command (T41): select an area with the shared selector, recognize
/// its text with Vision, deliver it to the clipboard or the in-memory history
/// and report the result. The image never leaves the process and is not written
/// to disk.
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
    typealias FeedbackHandler = @MainActor (Feedback) -> Void
    typealias PIDProvider = @MainActor () -> pid_t?
    typealias HistoryPresenter = @MainActor () -> Void

    static let shared = TextRecognitionController()

    private let recognizer: TextRecognizing
    private let pasteboard: NSPasteboard
    private let history: ClipboardHistory
    private let selectRegion: RegionSelector
    private let frontmostPID: PIDProvider
    private let showHistory: HistoryPresenter
    private let feedback: FeedbackHandler

    /// Bumped on every accepted request; a completion whose generation no
    /// longer matches is discarded instead of overwriting a newer result.
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var isSelecting = false

    init(recognizer: TextRecognizing = TextRecognizer(),
         pasteboard: NSPasteboard = .general,
         history: ClipboardHistory = .shared,
         selectRegion: @escaping RegionSelector = { try await ScreenRegionSelector.shared.select() },
         frontmostPID: @escaping PIDProvider = {
             NSWorkspace.shared.frontmostApplication?.processIdentifier
         },
         showHistory: @escaping HistoryPresenter = { ClipboardController.shared.show() },
         feedback: @escaping FeedbackHandler = { TextRecognitionController.present($0) }) {
        self.recognizer = recognizer
        self.pasteboard = pasteboard
        self.history = history
        self.selectRegion = selectRegion
        self.frontmostPID = frontmostPID
        self.showHistory = showHistory
        self.feedback = feedback
    }

    /// Opens the area selector and delivers the recognized text. Calling it
    /// while the selector is already open is a no-op with a notice: reopening
    /// would cancel and restart the user's drag.
    func recognizeArea(options: TextRecognitionOptions = .standard,
                       output: TextRecognitionOutput = .pasteboardAndHistory,
                       reveal: OCRRevealHistory = .never) {
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
            do {
                try Task.checkCancellation()
                let selection = try await self.selectRegion()
                self.isSelecting = false
                // The selector restores the previous app: remember who that is,
                // so the history panel never steals focus after a switch (T54).
                let foregroundPID = self.frontmostPID()
                try Task.checkCancellation()
                guard let image = selection.image else {
                    self.publish(.failed("The area could not be captured."),
                                 generation: generation)
                    return
                }
                let result = try await self.recognizer.recognize(image, options: options)
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                switch output {
                case .pasteboard:
                    guard self.copy(result.text) else {
                        self.feedback(.failed("The text could not be copied."))
                        return
                    }
                    // The poll must not add a second entry for our own copy.
                    self.history.markPasteboardSeen()
                case .pasteboardAndHistory:
                    guard self.copy(result.text) else {
                        self.feedback(.failed("The text could not be copied."))
                        return
                    }
                    self.history.insert(result.text)
                    self.history.markPasteboardSeen()
                case .historyOnly:
                    // An explicit OCR request wins over the poll's secure-input
                    // guard: the user asked for this text. The history panel
                    // still refuses to open while secure input is active.
                    self.history.insert(result.text)
                }
                self.feedback(.copied(result, output))
                if reveal.shouldReveal(for: output),
                   self.generation == generation,
                   self.frontmostPID() == foregroundPID {
                    self.showHistory()
                }
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

    private func publish(_ feedback: Feedback, generation: UInt64) {
        guard self.generation == generation else { return }
        self.feedback(feedback)
    }

    private func copy(_ text: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
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
            HUDController.shared.show(title, symbol: "text.viewfinder",
                                      detail: result.preview)
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
