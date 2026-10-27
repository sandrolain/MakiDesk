import AppKit
import CoreGraphics

/// The OCR command (T41): select an area with the shared selector, recognize
/// its text with Vision, copy it and report the result. The image never leaves
/// the process and is not written to disk.
@MainActor
final class TextRecognitionController {
    enum Feedback: Equatable {
        case copied(TextRecognitionResult)
        case noText
        case cancelled
        case permissionDenied
        case busy
        case failed(String)
    }

    typealias RegionSelector = @MainActor () async throws -> ScreenRegionSelector.Selection
    typealias FeedbackHandler = @MainActor (Feedback) -> Void

    static let shared = TextRecognitionController()

    private let recognizer: TextRecognizing
    private let pasteboard: NSPasteboard
    private let selectRegion: RegionSelector
    private let feedback: FeedbackHandler

    /// Bumped on every accepted request; a completion whose generation no
    /// longer matches is discarded instead of overwriting a newer result.
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var isSelecting = false

    init(recognizer: TextRecognizing = TextRecognizer(),
         pasteboard: NSPasteboard = .general,
         selectRegion: @escaping RegionSelector = { try await ScreenRegionSelector.shared.select() },
         feedback: @escaping FeedbackHandler = { TextRecognitionController.present($0) }) {
        self.recognizer = recognizer
        self.pasteboard = pasteboard
        self.selectRegion = selectRegion
        self.feedback = feedback
    }

    /// Opens the area selector and copies the recognized text. Calling it while
    /// the selector is already open is a no-op with a notice: reopening would
    /// cancel and restart the user's drag.
    func recognizeArea(options: TextRecognitionOptions = .standard) {
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
                try Task.checkCancellation()
                guard let image = selection.image else {
                    self.publish(.failed("The area could not be captured."),
                                 generation: generation)
                    return
                }
                let result = try await self.recognizer.recognize(image, options: options)
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                guard self.copy(result.text) else {
                    self.feedback(.failed("The text could not be copied."))
                    return
                }
                self.feedback(.copied(result))
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
        case let .copied(result):
            let size = result.characterCount == 1
                ? "1 character" : "\(result.characterCount) characters"
            HUDController.shared.show(
                "Text copied · \(size)",
                symbol: "text.viewfinder",
                detail: result.preview,
                duration: 3
            )
            WorkspaceStore.shared.status = "Text copied · \(size)"
        case .noText:
            HUDController.shared.show("No text found", symbol: "text.magnifyingglass",
                                      duration: 2)
            WorkspaceStore.shared.status = "No text found"
        case .cancelled:
            break
        case .permissionDenied:
            HUDController.shared.show(
                "Screen Recording permission required",
                symbol: "exclamationmark.triangle.fill",
                detail: "Grant it in Settings ▸ General, then try again.",
                duration: 3
            )
            WorkspaceStore.shared.status = "Screen Recording permission required"
        case .busy:
            HUDController.shared.show("A selection is already open",
                                      symbol: "hand.raised.fill")
        case let .failed(message):
            let short = message.count > 80 ? String(message.prefix(80)) + "…" : message
            HUDController.shared.show("Text recognition failed: \(short)",
                                      symbol: "exclamationmark.triangle.fill",
                                      duration: 3)
            WorkspaceStore.shared.status = "Text recognition failed"
        }
    }
}
