import AppKit
import CoreGraphics
import ImageIO

/// Reads an image that is already on the clipboard for text recognition (U2)
/// and for the clipboard history (U3).
///
/// The pasteboard belongs to AppKit, so reading the bytes happens on the main
/// actor; decoding and downscaling are pure CoreGraphics work and run on a
/// worker. Nothing is written to disk and the image never leaves the process.
enum ClipboardImageSource {
    /// The same ceiling the screen captures use before recognition: a huge
    /// pasted photo does not need its full resolution to be read.
    static let maximumDimension = 4000

    enum Failure: Error, Equatable, Sendable {
        case noImage
        /// The app that made the copy marked it private (`org.nspasteboard`).
        case concealed
    }

    /// The bytes and their pasteboard type, handed to the worker. `Data` and
    /// the type are Sendable; the pasteboard is not captured.
    struct Payload: Sendable, Equatable {
        let data: Data
        let type: NSPasteboard.PasteboardType
    }

    /// `CGImage` is immutable once created; the box exists only so the decoded
    /// picture can cross the worker boundary without an unsafe global.
    struct Decoded: @unchecked Sendable {
        let image: CGImage
    }

    /// PNG keeps the original pixels; TIFF is what many apps put there instead.
    /// JPEG and HEIC are accepted for the apps that publish only the compressed
    /// original.
    static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.heic"),
        NSPasteboard.PasteboardType("public.heif"),
    ]

    /// The pasteboard is read once, in order of preference.
    @MainActor
    static func payload(from pasteboard: NSPasteboard) -> Result<Payload, Failure> {
        if hasConcealedType(pasteboard) { return .failure(.concealed) }
        for type in imageTypes {
            if let data = pasteboard.data(forType: type), data.isEmpty == false {
                return .success(Payload(data: data, type: type))
            }
        }
        return .failure(.noImage)
    }

    /// Decodes and, when needed, shrinks the image so its longest side is at
    /// most `maximumDimension`. Nil means the data was not a readable image.
    static func decode(_ payload: Payload,
                       maximumDimension: Int = maximumDimension) -> Decoded? {
        guard let source = CGImageSourceCreateWithData(payload.data as CFData, nil) else {
            return nil
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let longest = max(width, height)
        if longest > 0, longest <= maximumDimension,
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return Decoded(image: image)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maximumDimension),
        ]
        if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return Decoded(image: thumbnail)
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil).map(Decoded.init)
    }

    @MainActor
    private static func hasConcealedType(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        return types.contains { ClipboardHistory.concealedTypes.contains($0) }
    }
}
