import AppKit
import CoreGraphics
import Vision

/// How hard Vision should look (T41). `accurate` is the default: the extra
/// time is small for a selection and the difference on screen text is visible.
enum TextRecognitionQuality: String, CaseIterable, Identifiable, Sendable {
    case accurate
    case fast

    var id: String { rawValue }

    var label: String {
        switch self {
        case .accurate: return "Accurate"
        case .fast: return "Fast"
        }
    }

    var visionLevel: VNRequestTextRecognitionLevel {
        switch self {
        case .accurate: return .accurate
        case .fast: return .fast
        }
    }
}

/// What to ask Vision for. Languages stay empty for automatic detection, which
/// follows the text on screen instead of forcing the system language.
struct TextRecognitionOptions: Equatable, Sendable {
    var quality: TextRecognitionQuality = .accurate
    var usesLanguageCorrection = true
    var languages: [String] = []

    static let standard = TextRecognitionOptions()
}

/// The result of one recognition. Counts and the preview are derived here so
/// the controller and the HUD do not each re-parse the text.
struct TextRecognitionResult: Equatable, Sendable {
    let text: String
    let durationMilliseconds: Int
    let scaled: Bool

    var characterCount: Int { text.count }

    var lineCount: Int {
        text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    /// At most four non-empty lines, each cut short: the HUD preview, not a
    /// second copy of the whole result.
    var preview: String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(4)
            .map { line -> String in
                let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                return trimmed.count > 100 ? String(trimmed.prefix(100)) + "…" : trimmed
            }
            .joined(separator: "\n")
    }
}

enum TextRecognitionError: Error, Equatable, LocalizedError {
    case noText
    case visionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noText:
            return "No text found."
        case let .visionFailed(message):
            return "Text recognition failed: \(message)"
        }
    }
}

/// The one place that turns Vision observations into text (T41).
enum TextRecognitionLayout {
    struct Block: Equatable, Sendable {
        let text: String
        let box: CGRect
    }

    /// Reading order: top to bottom, then left to right for blocks that share a
    /// line. Vision's boxes are normalized with the origin at the bottom left.
    static func joined(from blocks: [Block], sameLineTolerance: CGFloat = 0.01) -> String {
        blocks.sorted { lhs, rhs in
            if abs(lhs.box.maxY - rhs.box.maxY) > sameLineTolerance {
                return lhs.box.maxY > rhs.box.maxY
            }
            return lhs.box.minX < rhs.box.minX
        }
        .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { $0.isEmpty == false }
        .joined(separator: "\n")
    }
}

/// Bounds the image Vision has to scan: a 5K selection is ~15 megapixels and
/// buys nothing over 3000 px on the long side.
enum TextRecognitionImage {
    struct Prepared: Sendable {
        let image: CGImage
        let scaled: Bool
    }

    static let maximumDimension = 3000

    static func targetSize(for size: CGSize, maxDimension: Int = maximumDimension) -> CGSize {
        let width = max(1, size.width)
        let height = max(1, size.height)
        let longest = max(width, height)
        guard longest > CGFloat(maxDimension) else {
            return CGSize(width: width.rounded(), height: height.rounded())
        }
        let factor = CGFloat(maxDimension) / longest
        return CGSize(width: max(1, (width * factor).rounded()),
                      height: max(1, (height * factor).rounded()))
    }

    static func prepared(_ image: CGImage,
                         maxDimension: Int = maximumDimension) -> Prepared {
        let size = targetSize(for: CGSize(width: image.width, height: image.height),
                              maxDimension: maxDimension)
        guard Int(size.width) != image.width || Int(size.height) != image.height else {
            return Prepared(image: image, scaled: false)
        }
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return Prepared(image: image, scaled: false)
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        guard let scaled = context.makeImage() else {
            return Prepared(image: image, scaled: false)
        }
        return Prepared(image: scaled, scaled: true)
    }
}

protocol TextRecognizing: Sendable {
    func recognize(_ image: CGImage,
                   options: TextRecognitionOptions) async throws -> TextRecognitionResult
}

/// Vision behind an actor: one recognition at a time, off the main thread.
/// A newer request cannot interrupt a request already inside Vision, so the
/// caller also carries a generation and discards the stale answer.
actor TextRecognizer: TextRecognizing {
    func recognize(_ image: CGImage,
                   options: TextRecognitionOptions) async throws -> TextRecognitionResult {
        try Task.checkCancellation()
        let started = ContinuousClock.now
        let prepared = TextRecognitionImage.prepared(image)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = options.quality.visionLevel
        request.usesLanguageCorrection = options.usesLanguageCorrection
        if options.languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = options.languages
        }

        do {
            let handler = VNImageRequestHandler(cgImage: prepared.image, options: [:])
            try handler.perform([request])
        } catch {
            throw TextRecognitionError.visionFailed(error.localizedDescription)
        }
        try Task.checkCancellation()

        let blocks = (request.results ?? []).compactMap { observation -> TextRecognitionLayout.Block? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return TextRecognitionLayout.Block(text: candidate.string,
                                               box: observation.boundingBox)
        }
        let text = TextRecognitionLayout.joined(from: blocks)
        guard text.isEmpty == false else { throw TextRecognitionError.noText }

        let elapsed = ContinuousClock.now - started
        let milliseconds = max(0, Int(elapsed.components.seconds) * 1000
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000))
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: true).count
        // Counts and timings only: the recognized text never reaches a log.
        makiLog.notice("ocr chars=\(text.count, privacy: .public) lines=\(lineCount, privacy: .public) ms=\(milliseconds, privacy: .public) scaled=\(prepared.scaled, privacy: .public)")
        return TextRecognitionResult(text: text,
                                     durationMilliseconds: milliseconds,
                                     scaled: prepared.scaled)
    }
}
