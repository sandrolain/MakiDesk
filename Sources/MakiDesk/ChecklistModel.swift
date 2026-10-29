import CoreGraphics
import Foundation

/// One line of the checklist. The text is short but may keep the user's own
/// line breaks; nothing here is interpreted.
struct ChecklistItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var text: String
    var done: Bool

    init(id: UUID = UUID(), text: String, done: Bool = false) {
        self.id = id
        self.text = text
        self.done = done
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, done
    }

    /// A file written by an older or a partial build must not fail to load: a
    /// missing field takes its default instead of throwing the whole list away.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        done = try container.decodeIfPresent(Bool.self, forKey: .done) ?? false
    }
}

/// The ordered list of items and the operations on it, as plain values: the
/// panel, the tests and a future import all work on the same rules.
struct Checklist: Equatable, Sendable {
    private(set) var items: [ChecklistItem] = []

    /// A short list stays readable at a glance; past this the panel is a list
    /// of lists. The limit is enforced here, not only in the add field.
    static let maxItems = 50
    /// One item cannot fill the panel, whichever way it was pasted in.
    static let maxTextLength = 200

    init(items: [ChecklistItem] = []) {
        self.items = Array(items.prefix(Self.maxItems))
    }

    /// Adds an item, or nothing when the text is empty or the list is full.
    @discardableResult
    mutating func add(_ text: String) -> ChecklistItem? {
        guard items.count < Self.maxItems, let clean = Self.normalized(text) else {
            return nil
        }
        let item = ChecklistItem(text: clean)
        items.append(item)
        return item
    }

    mutating func toggle(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].done.toggle()
    }

    mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    mutating func removeAll() {
        items.removeAll()
    }

    /// Moves one step up (-1) or down (+1). Returns whether anything moved, so
    /// a button at the end of the list can stay inert.
    @discardableResult
    mutating func move(_ id: UUID, by offset: Int) -> Bool {
        guard offset != 0,
              let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let target = index + offset
        guard target >= 0, target < items.count else { return false }
        let item = items.remove(at: index)
        items.insert(item, at: target)
        return true
    }

    /// Takes the ticked items away and says how many went.
    @discardableResult
    mutating func clearCompleted() -> Int {
        let before = items.count
        items.removeAll { $0.done }
        return before - items.count
    }

    var remaining: Int {
        items.reduce(0) { $0 + ($1.done ? 0 : 1) }
    }

    var completed: Int {
        items.count - remaining
    }

    var isFull: Bool { items.count >= Self.maxItems }

    /// Trims the ends, keeps the line breaks the user typed, drops the ones
    /// that only add blank space, and caps the length.
    static func normalized(_ text: String) -> String? {
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.isEmpty == false else { return nil }
        let lines = collapsed
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }
        let joined = lines.joined(separator: "\n")
        return joined.count > maxTextLength
            ? String(joined.prefix(maxTextLength))
            : joined
    }
}

/// Where the panel sits and how solid it is (T59). Values, so the settings
/// window and the panel cannot disagree about a limit.
enum ChecklistSettings {
    static let opacityRange: ClosedRange<Double> = 0.3...1
    static let defaultOpacity = 0.85
    static let widthRange: ClosedRange<Double> = 260...480
    static let defaultWidth: Double = 320
    static let defaultPosition = HUDPosition.topRight
    static let defaultScreen = PaletteScreenLocation.focusedWindow

    /// How tall the list may get before it scrolls, as a share of the display.
    static let maximumHeightShare = 0.6

    static func clampedOpacity(_ value: Double) -> Double {
        min(max(value, opacityRange.lowerBound), opacityRange.upperBound)
    }

    static func clampedWidth(_ value: Double) -> Double {
        min(max(value, widthRange.lowerBound), widthRange.upperBound)
    }

    /// The resting opacity is the setting; a card the user points at or types
    /// in shows solid, and so does any card with Reduce Transparency on.
    static func alpha(opacity: Double, revealed: Bool, reduceTransparency: Bool) -> CGFloat {
        (revealed || reduceTransparency) ? 1 : CGFloat(clampedOpacity(opacity))
    }

    /// How far a tiled window sits from a screen edge: the gap is shared
    /// between neighbours, so one window keeps half of it (Settings ▸ Windows).
    static func edgeMargin(forGap gap: Double) -> CGFloat {
        CGFloat(max(0, min(gap, 80))) / 2
    }

    /// The panel frame for one display, in Cocoa coordinates.
    ///
    /// The corner rule is the notices', but the distance from the edges is the
    /// one a tiled window has — half the gap — because a card that sat 24 pt
    /// from the edge next to windows sitting on the gap looked like it belonged
    /// to another app. Negative origins are handled once, in `HUDLayout`.
    static func frame(for size: CGSize, position: HUDPosition, screen: CGRect,
                      margin: CGFloat) -> CGRect {
        // No 8 pt floor: the gap is the whole rule, and 0 means 0.
        HUDLayout.frames(anchor: position, screen: screen, sizes: [size],
                         margin: max(0, margin), minimumEdge: 0).first ?? .zero
    }
}

/// Persists the checklist to a small JSON file in Application Support.
///
/// Same shape as `GroupStore`: one file, written atomically, and an unreadable
/// file set aside as `.bak` instead of being deleted, so a bad write never costs
/// the user the list and never stops the app. The URL is injectable, so the
/// store is tested on a temporary directory.
struct ChecklistFile {
    struct Payload: Codable, Equatable {
        var version: Int
        var items: [ChecklistItem]

        init(version: Int = ChecklistFile.currentVersion, items: [ChecklistItem]) {
            self.version = version
            self.items = items
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version)
                ?? ChecklistFile.currentVersion
            items = try container.decodeIfPresent([ChecklistItem].self, forKey: .items) ?? []
        }
    }

    static let currentVersion = 1

    let fileURL: URL

    init(fileURL: URL = ChecklistFile.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/MakiDesk/checklist.json`.
    static var defaultFileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("MakiDesk", isDirectory: true)
            .appendingPathComponent("checklist.json")
    }

    /// The items written last, or an empty list when there is nothing to read.
    func load() -> [ChecklistItem] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            // A filler item with no text is not a task.
            return payload.items.filter { $0.text.isEmpty == false }
        } catch {
            backUpCorruptFile()
            return []
        }
    }

    @discardableResult
    func save(_ items: [ChecklistItem]) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Payload(items: items)) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            makiLog.error("checklist: could not save -> \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func backUpURL() -> URL {
        fileURL.appendingPathExtension("bak")
    }

    private func backUpCorruptFile() {
        let base = backUpURL()
        var backup = base
        var suffix = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = base.deletingPathExtension().appendingPathExtension("bak-\(suffix)")
            suffix += 1
        }
        do {
            try FileManager.default.moveItem(at: fileURL, to: backup)
            makiLog.error("checklist: unreadable file set aside at \(backup.path, privacy: .public)")
        } catch {
            makiLog.error("checklist: could not preserve unreadable file -> \(error.localizedDescription, privacy: .public)")
        }
    }
}
