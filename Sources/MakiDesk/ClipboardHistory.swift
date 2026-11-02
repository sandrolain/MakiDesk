import AppKit
import Carbon.HIToolbox
import CryptoKit
import Darwin
import ImageIO
import os

/// One copied item — text or an image — kept in memory only (T21, U3).
struct ClipboardEntry: Identifiable, Equatable {
    let id: UUID
    let content: ClipboardContent
    let date: Date
    /// A pinned entry survives *Clear* and is not evicted by the image budget
    /// or the entry count. It is still in memory only: pins die with the app.
    var isPinned: Bool

    init(id: UUID, content: ClipboardContent, date: Date, isPinned: Bool = false) {
        self.id = id
        self.content = content
        self.date = date
        self.isPinned = isPinned
    }

    init(id: UUID = UUID(), text: String, date: Date, isPinned: Bool = false) {
        self.init(id: id, content: .text(text), date: date, isPinned: isPinned)
    }

    init(id: UUID = UUID(), image: ClipboardImage, date: Date, isPinned: Bool = false) {
        self.init(id: id, content: .image(image), date: date, isPinned: isPinned)
    }

    /// The text of a text entry, empty for an image.
    var text: String { content.text ?? "" }
    var image: ClipboardImage? { content.image }

    /// The first non-empty line, collapsed to one line: what the list shows.
    var preview: String {
        if let image { return "Image \(image.pixelWidth) × \(image.pixelHeight)" }
        let line = text.split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.trimmingCharacters(in: .whitespaces).isEmpty == false } ?? ""
        let collapsed = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
            .joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Whitespace" }
        return trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
    }

    var detail: String {
        if let image {
            let size = ByteCountFormatter.string(fromByteCount: Int64(image.byteCost),
                                                 countStyle: .file)
            return "\(image.pixelWidth) × \(image.pixelHeight) · \(size)"
        }
        let lines = text.components(separatedBy: "\n").count
        let size = text.count == 1 ? "1 character" : "\(text.count) characters"
        return lines > 1 ? "\(lines) lines · \(size)" : size
    }

    /// What the row shows before the text: a colour swatch, an image
    /// thumbnail, or the plain text icon (T36, U3).
    var previewKind: ClipboardPreview {
        if let image { return .storedImage(image) }
        return ClipboardPreview(text: text)
    }
}

/// Text or an image. A closed enum keeps the two paste paths honest: an image
/// entry has no text to paste and a text entry has no bytes to write.
enum ClipboardContent: Equatable {
    case text(String)
    case image(ClipboardImage)

    var text: String? {
        if case let .text(value) = self { return value }
        return nil
    }

    var image: ClipboardImage? {
        if case let .image(value) = self { return value }
        return nil
    }
}

/// One copied image, kept in memory (U3). The original bytes are what a paste
/// writes back; the thumbnail is what the list draws. `byteCost` is the data
/// plus the thumbnail, which is what the history's budget counts.
///
/// `@unchecked Sendable`: `Data` and `CGImage` are immutable after creation, so
/// moving one from the decode worker to the main actor is safe; nothing mutates
/// it afterwards.
struct ClipboardImage: Equatable, @unchecked Sendable {
    let data: Data
    let type: NSPasteboard.PasteboardType
    let thumbnail: CGImage
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCost: Int
    let digest: String

    static func == (lhs: ClipboardImage, rhs: ClipboardImage) -> Bool {
        lhs.digest == rhs.digest && lhs.byteCost == rhs.byteCost
    }
}

/// The leading preview of a clipboard row, recognised from the copied text:
/// a colour, a local image path, a stored image, or nothing special.
enum ClipboardPreview: Equatable {
    case text
    case color(SampledColor)
    case image(URL)
    case storedImage(ClipboardImage)

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tif", "tiff", "heic", "heif", "gif", "bmp", "webp"
    ]

    init(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let color = SampledColor(parsing: trimmed) {
            self = .color(color)
            return
        }
        guard trimmed.isEmpty == false, trimmed.contains("\n") == false,
              trimmed.count <= 1024 else {
            self = .text
            return
        }
        let url: URL?
        if let parsed = URL(string: trimmed), parsed.isFileURL {
            url = parsed
        } else if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        } else {
            url = nil
        }
        if let url, Self.imageExtensions.contains(url.pathExtension.lowercased()) {
            self = .image(url)
        } else {
            self = .text
        }
    }
}

/// Writes one clipboard entry to a pasteboard. Kept out of the controller so
/// the two paths — a string, or raw image bytes with their own type — can be
/// tested without a panel.
enum ClipboardPasteboardWriter {
    @MainActor
    @discardableResult
    static func write(_ entry: ClipboardEntry, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        if let image = entry.image {
            return pasteboard.setData(image.data, forType: image.type)
        }
        return pasteboard.setString(entry.text, forType: .string)
    }
}

/// The clipboard history: an in-memory ring of the last texts and images copied
/// (T21, U3).
///
/// Nothing is written to disk. The poll is cheap (`changeCount`), skips
/// passwords (secure input) and app-private copies (the `org.nspasteboard`
/// concealed/transient types), and keeps one entry per distinct text or image.
@MainActor
final class ClipboardHistory {
    static let shared = ClipboardHistory()

    private(set) var entries: [ClipboardEntry] = []
    let limit: Int
    /// Whether copied images are kept (U3). Off means text only.
    private(set) var keepsImages: Bool
    /// Bytes of image data plus thumbnails kept in memory.
    private(set) var imageBudgetBytes: Int
    /// Called when a copied image cannot fit even after evicting the oldest
    /// unpinned ones; the controller turns it into a notice.
    var onImageRejected: (() -> Void)?
    /// Called when the list changes (new copy, clear, promotion).
    var onChange: (() -> Void)?

    private let pasteboard: NSPasteboard
    private let secureInput: () -> Bool
    private var lastChangeCount: Int
    private var timer: Timer?
    private let performanceLog = Logger(subsystem: "com.makidesk.app", category: "Idle Performance")
    private var metricsWindowStarted = ContinuousClock.now
    private var metricsPollCount: UInt64 = 0
    private var metricsChangedCount: UInt64 = 0
    private var metricsPollCPUTime = 0.0
    /// Changes for every image being prepared; a result from before a newer
    /// copy is dropped rather than published.
    private var imageGeneration: UInt64 = 0

    /// Texts are kept whole so a paste is exact; a single absurd copy (a
    /// multi-megabyte log) is not worth the memory.
    private let maximumLength = 1_000_000

    /// Length in UTF-16 units: constant time for the bridged pasteboard string,
    /// where `String.count` would scan every grapheme of a huge copy on the
    /// main thread just to reject it.
    private func isWithinLimit(_ text: String) -> Bool {
        text.utf16.count <= maximumLength
    }

    /// The marker the `org.nspasteboard` convention uses for secrets.
    static let concealedMarker = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    static let concealedTypes: Set<NSPasteboard.PasteboardType> = [
        concealedMarker,
        .init("org.nspasteboard.TransientType"),
        .init("org.nspasteboard.AutoGeneratedType"),
    ]

    init(pasteboard: NSPasteboard = .general,
         limit: Int = 50,
         secureInput: @escaping () -> Bool = { IsSecureEventInputEnabled() },
         keepsImages: Bool = true,
         imageBudgetMB: Int = 32) {
        self.pasteboard = pasteboard
        self.limit = max(1, limit)
        self.secureInput = secureInput
        self.keepsImages = keepsImages
        self.imageBudgetBytes = max(1, imageBudgetMB) * 1_048_576
        self.lastChangeCount = pasteboard.changeCount
    }

    // MARK: - Collecting

    /// Starts the light poll. The clipboard itself needs no permission.
    func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One look at the pasteboard. Separate from the timer so the tests can
    /// drive it without waiting.
    func poll() {
        var cpuStart = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &cpuStart)
        defer { recordPoll(cpuStart: cpuStart) }
        guard secureInput() == false else {
            // Do not remember whatever a password field had for when secure
            // input turns off again.
            lastChangeCount = pasteboard.changeCount
            return
        }
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        metricsChangedCount += 1

        guard hasConcealedType() == false else { return }
        if let text = pasteboard.string(forType: .string),
           text.isEmpty == false, isWithinLimit(text) {
            insert(text)
            return
        }
        guard keepsImages else { return }
        guard case let .success(payload) = ClipboardImageSource.payload(from: pasteboard) else {
            return
        }
        prepareImage(payload, changeCount: count)
    }

    /// Emits an aggregate once a minute so diagnostics add no per-poll logging
    /// and never include clipboard contents.
    private func recordPoll(cpuStart: timespec) {
        metricsPollCount += 1
        var cpuEnd = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &cpuEnd)
        let startNanoseconds = Double(cpuStart.tv_sec) * 1e9 + Double(cpuStart.tv_nsec)
        let endNanoseconds = Double(cpuEnd.tv_sec) * 1e9 + Double(cpuEnd.tv_nsec)
        metricsPollCPUTime += max(0, endNanoseconds - startNanoseconds)
        let elapsed = metricsWindowStarted.duration(to: .now)
        guard elapsed >= .seconds(60) else { return }
        let cpuNanoseconds = UInt64(max(0, metricsPollCPUTime))
        performanceLog.info("Idle clipboard metrics: polls=\(self.metricsPollCount), changed=\(self.metricsChangedCount), poll_cpu_ns=\(cpuNanoseconds)")
        metricsWindowStarted = .now
        metricsPollCount = 0
        metricsChangedCount = 0
        metricsPollCPUTime = 0
    }

    private func hasConcealedType() -> Bool {
        guard let types = pasteboard.types else { return false }
        return types.contains { Self.concealedTypes.contains($0) }
    }

    /// Adds a text to the history as if it had been copied, **without touching
    /// the pasteboard**: the OCR "history only" destination uses it (T54), and
    /// so does the palette calculator. Dedupes by text, keeps the newest first,
    /// preserves a pin on the same text and trims to `limit`; the same bounds
    /// as the poll apply, so a giant text cannot flood the memory.
    func insert(_ text: String) {
        guard text.isEmpty == false, isWithinLimit(text) else { return }
        let existing = entries.first { $0.content == .text(text) }
        entries.removeAll { $0.content == .text(text) }
        entries.insert(ClipboardEntry(id: UUID(), text: text, date: Date(),
                                      isPinned: existing?.isPinned ?? false), at: 0)
        trimToCountLimit()
        onChange?()
    }

    // MARK: - Images (U3)

    /// Applies the clipboard image settings. Turning images off drops the
    /// unpinned ones (pins are explicit) and invalidates a decode already in
    /// flight, so nothing arrives afterwards.
    func configure(keepsImages: Bool, budgetMB: Int) {
        let previousBudget = imageBudgetBytes
        let wasKeeping = self.keepsImages
        self.keepsImages = keepsImages
        imageBudgetBytes = max(1, budgetMB) * 1_048_576
        let before = entries.count
        if keepsImages == false {
            imageGeneration &+= 1
            entries.removeAll { $0.image != nil && !$0.isPinned }
        }
        evictImagesOverBudget()
        trimToCountLimit()
        if entries.count != before || previousBudget != imageBudgetBytes
            || wasKeeping != keepsImages {
            onChange?()
        }
    }

    /// Adds an image, or moves an identical one (same digest) back to the top
    /// with its pin. Returns false when the budget cannot be met even after
    /// evicting the oldest unpinned images.
    @discardableResult
    func insertImage(_ image: ClipboardImage, date: Date = Date()) -> Bool {
        guard keepsImages else { return false }
        let existing = entries.first { $0.image?.digest == image.digest }
        guard canFitImage(bytes: image.byteCost, replacing: existing) else {
            onImageRejected?()
            return false
        }
        if let existing { entries.removeAll { $0.id == existing.id } }
        entries.insert(ClipboardEntry(image: image, date: date,
                                      isPinned: existing?.isPinned ?? false), at: 0)
        evictImagesOverBudget()
        trimToCountLimit()
        onChange?()
        return true
    }

    /// Whether `bytes` fit after removing the unpinned images that would have
    /// to go. Pure with respect to the list: nothing is removed until the
    /// answer is yes.
    private func canFitImage(bytes: Int, replacing: ClipboardEntry?) -> Bool {
        var used = totalImageBytes()
        if let replaced = replacing?.image { used -= replaced.byteCost }
        if used + bytes <= imageBudgetBytes { return true }
        for entry in entries.reversed() where entry.id != replacing?.id {
            guard let image = entry.image, entry.isPinned == false else { continue }
            used -= image.byteCost
            if used + bytes <= imageBudgetBytes { return true }
        }
        return false
    }

    private func evictImagesOverBudget() {
        while totalImageBytes() > imageBudgetBytes {
            guard let index = entries.lastIndex(where: {
                $0.image != nil && $0.isPinned == false
            }) else { return }
            entries.remove(at: index)
        }
    }

    /// Pins are deliberate, so the count limit gives way to them: they are
    /// never evicted, and the list can be longer than `limit` when they are.
    private func trimToCountLimit() {
        while entries.count > limit {
            guard let index = entries.lastIndex(where: { $0.isPinned == false }) else { return }
            entries.remove(at: index)
        }
    }

    private func totalImageBytes() -> Int {
        entries.reduce(0) { total, entry in
            total + (entry.image?.byteCost ?? 0)
        }
    }

    /// Decoding, thumbnailing and hashing are CPU work: they happen on a worker,
    /// and the result is dropped when another copy has arrived meanwhile.
    private func prepareImage(_ payload: ClipboardImageSource.Payload, changeCount: Int) {
        imageGeneration &+= 1
        let generation = imageGeneration
        Task { [weak self] in
            let image = await Task.detached(priority: .utility) {
                Self.prepare(payload)
            }.value
            guard let self, self.imageGeneration == generation,
                  self.lastChangeCount == changeCount,
                  let image else { return }
            self.insertImage(image)
        }
    }

    /// The original bytes are kept for the paste; only a 96 px thumbnail is
    /// decoded for the row. The cost is what both actually occupy.
    nonisolated private static func prepare(_ payload: ClipboardImageSource.Payload) -> ClipboardImage? {
        guard let source = CGImageSourceCreateWithData(payload.data as CFData, nil) else {
            return nil
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 96,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }
        let digest = SHA256.hash(data: payload.data)
            .map { String(format: "%02x", $0) }
            .joined()
        let cost = payload.data.count + thumbnail.width * thumbnail.height * 4
        return ClipboardImage(data: payload.data, type: payload.type,
                              thumbnail: thumbnail, pixelWidth: width, pixelHeight: height,
                              byteCost: cost, digest: digest)
    }

    // MARK: - Using the list

    /// A pasted entry becomes the most recent one, with its content and pin.
    func promote(_ entry: ClipboardEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let item = entries.remove(at: index)
        entries.insert(ClipboardEntry(id: item.id, content: item.content,
                                      date: Date(), isPinned: item.isPinned), at: 0)
        onChange?()
    }

    /// Pin or unpin one entry. A pinned entry survives *Clear*, the image budget
    /// and the entry limit; it is still in memory only.
    func togglePin(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isPinned.toggle()
        onChange?()
    }

    /// The text we just wrote to the pasteboard is not a new copy.
    func markPasteboardSeen() {
        lastChangeCount = pasteboard.changeCount
    }

    /// *Clear* keeps the pinned entries; `includingPins` is the explicit
    /// everything-goes action (and what the factory reset uses).
    func clear(includingPins: Bool = false) {
        guard entries.isEmpty == false else { return }
        imageGeneration &+= 1
        if includingPins {
            entries.removeAll()
        } else {
            entries.removeAll { $0.isPinned == false }
        }
        onChange?()
    }

    var count: Int { entries.count }
    var pinnedCount: Int { entries.reduce(0) { $0 + ($1.isPinned ? 1 : 0) } }
}
