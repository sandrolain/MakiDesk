import Foundation
import Observation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether the on-device model can be asked to rewrite a note (T66).
enum NotesIntelligenceAvailability: Equatable {
    case available
    case unavailable(String)

    var isAvailable: Bool { self == .available }

    /// What Settings and the menu say.
    var summary: String {
        switch self {
        case .available:
            return "On-device model available"
        case let .unavailable(reason):
            return reason
        }
    }
}

/// The rewriting engine: the real one wraps Foundation Models, the tests use a
/// fake, so the controller's streaming and revisions can be checked anywhere.
protocol NotesRewriteEngine: Sendable {
    func stream(prompt: String, action: NotesRewriteAction) -> AsyncThrowingStream<NotesRewriteDraft, Error>
}

enum NotesRewriteProvider: String, CaseIterable, Identifiable, Sendable {
    case appleIntelligence
    case ollama

    var id: String { rawValue }
    var title: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence"
        case .ollama: "Ollama (local)"
        }
    }
}

enum NotesRewriteService {
    static var provider: NotesRewriteProvider {
        Settings.value(.notesRewriteProvider, as: NotesRewriteProvider.self,
                       in: NotesPreferences.defaults) ?? .appleIntelligence
    }

    static var ollamaModel: String {
        Settings.string(.notesRewriteModel, in: NotesPreferences.defaults) ?? "qwen3.5:4b"
    }

    static func availability() -> NotesIntelligenceAvailability {
        switch provider {
        case .appleIntelligence:
            NotesIntelligence.availability()
        case .ollama:
            ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .unavailable("Enter an Ollama model name in Settings > Panels > Tools.")
                : .available
        }
    }

    static func makeEngine() -> NotesRewriteEngine? {
        switch provider {
        case .appleIntelligence:
            return NotesIntelligence.makeEngine()
        case .ollama:
            let model = ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? nil : OllamaNotesRewriteEngine(model: model)
        }
    }
}

/// What the app can say about the model on this system and in this language.
enum NotesIntelligence {
    static func availability() -> NotesIntelligenceAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return model.supportsLocale()
                    ? .available
                    : .unavailable("Apple Intelligence does not support this note's language yet.")
            case let .unavailable(reason):
                switch reason {
                case .deviceNotEligible:
                    return .unavailable("This Mac does not support Apple Intelligence.")
                case .appleIntelligenceNotEnabled:
                    return .unavailable("Apple Intelligence is off in System Settings.")
                case .modelNotReady:
                    return .unavailable("The on-device model is not ready yet.")
                @unknown default:
                    return .unavailable("Apple Intelligence is not available.")
                }
            }
        }
        #endif
        return .unavailable("Rewriting notes needs macOS 26 with Apple Intelligence.")
    }

    /// The real engine, or nil when this system cannot run one.
    static func makeEngine() -> NotesRewriteEngine? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard availability().isAvailable else { return nil }
            return AppleNotesRewriteEngine()
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
private struct AppleNotesRewriteEngine: NotesRewriteEngine {
    func stream(prompt: String, action: NotesRewriteAction) -> AsyncThrowingStream<NotesRewriteDraft, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(
                        instructions: NotesRewritePrompt.instructions(for: action)
                    )
                    var options = GenerationOptions()
                    options.temperature = action == .proofread ? 0.15 : (action == .improve ? 0.3 : 0.5)
                    if action == .proofread {
                        let stream = session.streamResponse(to: prompt,
                                                            generating: ProofreadMarkdown.self,
                                                            options: options)
                        for try await snapshot in stream {
                            try Task.checkCancellation()
                            let markdown = snapshot.content.markdown ?? ""
                            continuation.yield(NotesRewriteDraft(summary: markdown, rawMarkdown: markdown))
                        }
                    } else {
                        let stream = session.streamResponse(to: prompt,
                                                            generating: GeneratedRewrite.self,
                                                            options: options)
                        for try await snapshot in stream {
                            try Task.checkCancellation()
                            continuation.yield(Self.draft(from: snapshot.content))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func draft(from content: GeneratedRewrite.PartiallyGenerated) -> NotesRewriteDraft {
        NotesRewriteDraft(
            title: content.title ?? "",
            summary: content.summary ?? "",
            sections: (content.sections ?? []).map { section in
                NotesRewriteDraft.Section(
                    level: level(from: section.level ?? "h2"),
                    heading: section.heading ?? "",
                    paragraphs: section.paragraphs ?? [],
                    bullets: section.bullets ?? [],
                    table: (section.table ?? []).map { $0.cells ?? [] }
                )
            }
        )
    }

    private static func level(from text: String) -> Int {
        switch text.lowercased() {
        case "h1": return 1
        case "h3": return 3
        default: return 2
        }
    }
}

@available(macOS 26, *)
@Generable
private struct ProofreadMarkdown {
    @Guide(description: "The complete corrected Markdown document, preserving all existing structure and content with minimal spelling, grammar, punctuation and readability edits. Return no preface or commentary.")
    var markdown: String
}

/// The shape the model fills in. Everything is plain text: the Markdown is
/// written by `NotesMarkdownSerializer`, not by the model (T66).
@available(macOS 26, *)
@Generable
struct GeneratedRewrite {
    @Guide(description: "A short title for the note, in the note's language.")
    var title: String
    @Guide(description: "One or two sentences that say what the note is about.")
    var summary: String
    @Guide(description: "The sections of the note, in order.")
    var sections: [GeneratedSection]
}

@available(macOS 26, *)
@Generable
struct GeneratedSection {
    @Guide(description: "How deep the heading is: h1 for a main section, h2 or h3 below it.",
           .anyOf(["h1", "h2", "h3"]))
    var level: String
    @Guide(description: "The heading, without any # marker.")
    var heading: String
    @Guide(description: "Prose paragraphs, without Markdown markers.")
    var paragraphs: [String]
    @Guide(description: "Short list items, without the leading dash.")
    var bullets: [String]
    @Guide(description: "Optional table: the first row is the header, without the separator row.")
    var table: [GeneratedRow]
}

@available(macOS 26, *)
@Generable
struct GeneratedRow {
    @Guide(description: "The cells of one table row, in order, without the pipes.")
    var cells: [String]
}
#endif

/// Runs one rewrite at a time and keeps the preview in step (T66).
@MainActor
@Observable
final class NotesRewriteController {
    static let shared = NotesRewriteController()

    enum Phase: Equatable {
        case idle
        case running
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// The Markdown produced so far; it grows while the model streams.
    private(set) var preview = ""
    private(set) var action: NotesRewriteAction = .improve
    private(set) var noteID: UUID?
    private(set) var provider: NotesRewriteProvider = .appleIntelligence

    var isRunning: Bool { phase == .running }

    /// Injected by tests; the app uses the provider selected in Settings.
    @ObservationIgnored var availabilityProvider: () -> NotesIntelligenceAvailability = {
        NotesRewriteService.availability()
    }
    @ObservationIgnored var engineProvider: () -> NotesRewriteEngine? = {
        NotesRewriteService.makeEngine()
    }

    /// Every start and cancel bumps it: a result that arrives for an older
    /// generation is dropped instead of overwriting a newer draft.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    private init() {}

    var availability: NotesIntelligenceAvailability { availabilityProvider() }

    /// The task of the current request. The tests await the streams they feed;
    /// the app never reads it.
    var currentTask: Task<Void, Never>? { task }

    /// Starts a rewrite of `source`. The controller keeps the note it belongs to
    /// and the generation, so the caller can apply the result to the right range
    /// only if nothing newer arrived.
    func start(action: NotesRewriteAction, source: String, noteID: UUID) {
        let availability = availabilityProvider()
        guard availability.isAvailable, let engine = engineProvider() else {
            generation &+= 1
            task?.cancel()
            task = nil
            preview = ""
            phase = .failed(availability.summary)
            return
        }
        guard source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            generation &+= 1
            task?.cancel()
            task = nil
            preview = ""
            phase = .failed("There is nothing to rewrite.")
            return
        }
        generation &+= 1
        let generation = generation
        task?.cancel()
        self.action = action
        self.noteID = noteID
        preview = ""
        phase = .running
        let selectedProvider = NotesRewriteService.provider
        provider = selectedProvider
        let prompt = NotesRewritePrompt.prompt(for: action, source: source,
                                               provider: selectedProvider)
        task = Task { @MainActor [weak self] in
            do {
                for try await draft in engine.stream(prompt: prompt, action: action) {
                    try Task.checkCancellation()
                    guard let self, self.generation == generation else { return }
                    self.preview = NotesMarkdownSerializer.render(draft, action: action)
                }
                guard let self, self.generation == generation else { return }
                if self.preview.isEmpty {
                    self.phase = .failed("The model returned nothing.")
                } else {
                    self.phase = .ready
                }
                self.task = nil
            } catch is CancellationError {
                // Superseded or cancelled: the newer state owns the screen.
            } catch {
                guard let self, self.generation == generation else { return }
                self.preview = ""
                self.phase = .failed(error.localizedDescription)
                self.task = nil
            }
        }
    }

    /// Drops the running rewrite; the preview stays as it is for a cancel that
    /// only closes the panel.
    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        if phase == .running { phase = .idle }
    }

    /// Called when the notes panel closes or another note is selected: nothing
    /// of a session may survive into a different note.
    func reset() {
        cancel()
        phase = .idle
        preview = ""
        noteID = nil
    }
}

private struct OllamaNotesRewriteEngine: NotesRewriteEngine {
    let model: String

    func stream(prompt: String, action: NotesRewriteAction) -> AsyncThrowingStream<NotesRewriteDraft, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 180
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": model,
                        "stream": true,
                        "think": false,
                        "keep_alive": "5m",
                        "messages": [[
                            "role": "user",
                            "content": prompt
                        ]]
                    ])

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let response = response as? HTTPURLResponse else {
                        throw OllamaNotesRewriteError.invalidResponse
                    }
                    guard (200..<300).contains(response.statusCode) else {
                        throw OllamaNotesRewriteError.httpStatus(response.statusCode)
                    }
                    var accumulated = ""
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let data = line.data(using: .utf8),
                              let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }
                        if let error = event["error"] as? String {
                            throw OllamaNotesRewriteError.server(error)
                        }
                        if let message = event["message"] as? [String: Any],
                           let content = message["content"] as? String, !content.isEmpty {
                            accumulated += content
                            continuation.yield(NotesRewriteDraft(summary: accumulated,
                                                                  rawMarkdown: accumulated))
                        }
                        if event["done"] as? Bool == true { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private enum OllamaNotesRewriteError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Ollama returned an invalid response."
        case .httpStatus(let status): "Ollama returned HTTP \(status). Check that the model is installed and Ollama is running."
        case .server(let message): "Ollama: \(message)"
        }
    }
}
