import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Image data is prepared after admission to the shelf. Drag initiation only
/// promises the representations; it does not encode TIFF and PNG on the UI path.
final class ShelfImageWriter: NSObject, NSPasteboardWriting, @unchecked Sendable {
    private static let queue = DispatchQueue(label: "com.makidesk.shelf-image-data", qos: .utility)
    /// NSCache synchronizes its own lookups and insertions across threads.
    private final class Cache: @unchecked Sendable {
        let values = NSCache<NSString, NSData>()
        init() {
            values.totalCostLimit = 32 * 1024 * 1024
            values.countLimit = 100
        }
    }
    private static let cache = Cache()
    private let image: NSImage
    private let identity = UUID().uuidString
    private let encodingLock = NSLock()

    init(image: NSImage) { self.image = image }

    func prepare() {
        Self.queue.async { [self] in _ = data(for: .png) }
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] { [.png, .tiff] }

    func writingOptions(forType type: NSPasteboard.PasteboardType,
                        pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions { .promised }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? { data(for: type) }

    private func data(for type: NSPasteboard.PasteboardType) -> Data? {
        guard type == .png || type == .tiff else { return nil }
        let key = "\(identity)-\(type.rawValue)" as NSString
        if let data = Self.cache.values.object(forKey: key) { return data as Data }
        encodingLock.lock()
        defer { encodingLock.unlock() }
        if let data = Self.cache.values.object(forKey: key) { return data as Data }
        let data = type == .png ? image.shelfPNGData : image.tiffRepresentation
        if let data, data.count <= 8 * 1024 * 1024 {
            Self.cache.values.setObject(data as NSData, forKey: key, cost: data.count)
        }
        return data
    }
}
