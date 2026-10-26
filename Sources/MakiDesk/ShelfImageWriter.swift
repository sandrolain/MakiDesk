import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Image data is prepared after admission to the shelf. The pasteboard callback
/// uses this bounded strong cache so normal eviction and memory pressure do not
/// trigger a second synchronous image encode.
final class ShelfImageWriter: NSObject, NSPasteboardWriting, @unchecked Sendable {
    private static let queue = DispatchQueue(label: "com.makidesk.shelf-image-data", qos: .utility)
    /// Lock protects entries, recency and byte accounting. The cache is sized
    /// for the Shelf's 128 MiB decoded-image admission budget plus both PNG and
    /// TIFF outputs and format overhead.
    private final class Cache: @unchecked Sendable {
        private struct Entry {
            let data: Data
            let cost: Int
        }

        private let lock = NSLock()
        private let byteLimit = 288 * 1024 * 1024
        private let countLimit = 200
        private var entries: [String: Entry] = [:]
        private var recency: [String] = []
        private var totalCost = 0

        func value(for key: String) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[key] else { return nil }
            recency.removeAll { $0 == key }
            recency.append(key)
            return entry.data
        }

        func insert(_ data: Data, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            guard data.count <= byteLimit else { return }
            if let old = entries.removeValue(forKey: key) {
                totalCost -= old.cost
                recency.removeAll { $0 == key }
            }
            while totalCost + data.count > byteLimit || entries.count >= countLimit {
                guard let evictedKey = recency.first,
                      let evicted = entries.removeValue(forKey: evictedKey) else { break }
                recency.removeFirst()
                totalCost -= evicted.cost
            }
            entries[key] = Entry(data: data, cost: data.count)
            recency.append(key)
            totalCost += data.count
        }

        /// Encoded formats for a shelf that no longer holds the image are dead
        /// weight: the shelf is temporary and never reuses an identity.
        func removeAll() {
            lock.lock()
            defer { lock.unlock() }
            entries.removeAll()
            recency.removeAll()
            totalCost = 0
        }
    }
    private static let cache = Cache()

    /// Releases every prepared representation when the shelf empties or closes.
    static func clearCache() {
        cache.removeAll()
    }
    private let image: NSImage
    private let identity = UUID().uuidString
    private let encodingLock = NSLock()

    init(image: NSImage) { self.image = image }

    func prepare() {
        Self.queue.async { [self] in
            _ = data(for: .png)
            _ = data(for: .tiff)
        }
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] { [.png, .tiff] }

    func writingOptions(forType type: NSPasteboard.PasteboardType,
                        pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions { .promised }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? { data(for: type) }

    private func data(for type: NSPasteboard.PasteboardType) -> Data? {
        guard type == .png || type == .tiff else { return nil }
        let key = "\(identity)-\(type.rawValue)"
        if let data = Self.cache.value(for: key) { return data }
        encodingLock.lock()
        defer { encodingLock.unlock() }
        if let data = Self.cache.value(for: key) { return data }
        let data = type == .png ? image.shelfPNGData : image.tiffRepresentation
        if let data { Self.cache.insert(data, for: key) }
        return data
    }
}
