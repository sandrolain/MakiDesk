import Combine
import Foundation

/// Editable state of the Dropzones tab (T44).
///
/// The model owns the draft and the last saved copy; the view only edits the
/// draft. Saving is explicit because a command is not a checkbox: it needs a
/// name and a command line, and every change to the command asks for a new
/// confirmation on the next drop. Keeping this out of the view also makes the
/// list operations testable with a temporary `DropzoneStore`.
final class DropzoneEditorModel: ObservableObject {
    @Published private(set) var snapshot: DropzoneStore.Snapshot
    @Published var zones: [DropzoneConfig]
    @Published var selection: UUID?
    @Published var errorMessage: String?
    @Published private(set) var statusMessage: String?

    @Published private(set) var shortcuts: [DropzoneShortcut] = []
    @Published private(set) var shortcutsError: String?
    @Published private(set) var isLoadingShortcuts = false
    @Published private(set) var shortcutsLoaded = false

    private let store: DropzoneStore
    private var savedZones: [DropzoneConfig]

    init(store: DropzoneStore = DropzoneStore()) {
        self.store = store
        let snapshot = store.load()
        self.snapshot = snapshot
        self.zones = snapshot.zones
        self.savedZones = snapshot.zones
        self.selection = snapshot.zones.first?.id
    }

    var fileURL: URL { store.fileURL }
    var isDirty: Bool { zones != savedZones }
    var canEdit: Bool { snapshot.canSave }
    /// Saving also fixes a symlinked or group-writable file, even when the
    /// contents did not change.
    var canSave: Bool { canEdit && (isDirty || snapshot.isTrusted == false) }

    var selectedZone: DropzoneConfig? {
        guard let selection else { return nil }
        return zones.first { $0.id == selection }
    }

    // MARK: - Reading and writing

    /// Drops the draft and reads the file again. The Reload button and the
    /// factory reset use this; the view asks before discarding unsaved edits.
    func reload() {
        let fresh = store.load()
        snapshot = fresh
        zones = fresh.zones
        savedZones = fresh.zones
        if let selection, fresh.zones.contains(where: { $0.id == selection }) {
            self.selection = selection
        } else {
            self.selection = fresh.zones.first?.id
        }
        errorMessage = nil
        statusMessage = nil
    }

    func revert() {
        zones = savedZones
        if let selection, zones.contains(where: { $0.id == selection }) {
            self.selection = selection
        } else {
            self.selection = zones.first?.id
        }
        errorMessage = nil
        statusMessage = nil
    }

    /// Validates every zone, then writes the whole list. Returns `false` with
    /// `errorMessage` set when nothing was written.
    @discardableResult
    func save() -> Bool {
        guard canEdit else {
            errorMessage = snapshot.futureVersionMessage
            return false
        }
        for (index, zone) in zones.enumerated() {
            if let issue = zone.issues().first {
                selection = zone.id
                errorMessage = "Dropzone \(index + 1): \(issue.errorDescription ?? "Invalid dropzone.")"
                return false
            }
        }
        if isDirty == false, snapshot.isTrusted { return true }

        switch store.save(zones) {
        case .success:
            snapshot = store.load()
            savedZones = zones
            statusMessage = "Saved"
            errorMessage = nil
            return true
        case let .failure(error):
            errorMessage = error.localizedDescription
            return false
        }
    }

    func clearMessages() {
        errorMessage = nil
        statusMessage = nil
    }

    // MARK: - List operations

    @discardableResult
    func add() -> DropzoneConfig? {
        guard canEdit else {
            errorMessage = snapshot.futureVersionMessage
            return nil
        }
        guard zones.count < DropzoneStore.maximumZones else {
            errorMessage = "The limit is \(DropzoneStore.maximumZones) dropzones."
            return nil
        }
        let zone = DropzoneConfig(name: "New dropzone")
        zones.append(zone)
        selection = zone.id
        errorMessage = nil
        statusMessage = nil
        return zone
    }

    @discardableResult
    func duplicate(_ id: UUID) -> DropzoneConfig? {
        guard canEdit else {
            errorMessage = snapshot.futureVersionMessage
            return nil
        }
        guard let index = zones.firstIndex(where: { $0.id == id }) else { return nil }
        guard zones.count < DropzoneStore.maximumZones else {
            errorMessage = "The limit is \(DropzoneStore.maximumZones) dropzones."
            return nil
        }
        var copy = zones[index]
        copy.id = UUID()
        let prefix = "Copy of "
        copy.name = String((prefix + copy.name).prefix(DropzoneConfig.maximumNameLength))
        // A duplicate is a new drop target: it asks once, like any new command.
        copy.confirmedCommandHash = nil
        copy.createdAt = Date()
        zones.insert(copy, at: index + 1)
        selection = copy.id
        errorMessage = nil
        statusMessage = nil
        return copy
    }

    func delete(_ id: UUID) {
        guard canEdit else {
            errorMessage = snapshot.futureVersionMessage
            return
        }
        guard let index = zones.firstIndex(where: { $0.id == id }) else { return }
        zones.remove(at: index)
        if selection == id {
            if zones.indices.contains(index) {
                selection = zones[index].id
            } else {
                selection = zones.last?.id
            }
        }
        errorMessage = nil
        statusMessage = nil
    }

    func move(_ id: UUID, by offset: Int) {
        guard canEdit else { return }
        guard let index = zones.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard zones.indices.contains(target) else { return }
        let zone = zones.remove(at: index)
        zones.insert(zone, at: target)
        selection = id
        errorMessage = nil
        statusMessage = nil
    }

    func canMove(_ id: UUID, by offset: Int) -> Bool {
        guard canEdit, let index = zones.firstIndex(where: { $0.id == id }) else { return false }
        return zones.indices.contains(index + offset)
    }

    // MARK: - Shortcuts catalog

    /// Loaded on demand by the picker; the editor never starts `shortcuts list`
    /// just because the tab opened. Main-actor bound so the published updates
    /// after the awaited CLI call stay on the UI thread.
    @MainActor
    func refreshShortcuts() async {
        guard isLoadingShortcuts == false else { return }
        isLoadingShortcuts = true
        shortcutsError = nil
        let result = await DropzoneShortcutCatalog.load()
        isLoadingShortcuts = false
        switch result {
        case let .success(entries):
            shortcuts = entries
            shortcutsLoaded = true
        case let .failure(error):
            shortcutsError = error.localizedDescription
        }
    }
}

// MARK: - Checks shared by the editor and its tests

enum DropzoneEditorChecks {
    /// The executable named by the first token, when it cannot be found. Shell
    /// mode is left to the preview/resolve step: the line is code, not a path.
    static func executableWarning(for spec: CommandSpec) -> String? {
        guard spec.mode == .argv else { return nil }
        guard let tokens = try? CommandLineTokenizer.tokenize(spec.line),
              let first = tokens.first,
              first.isEmpty == false,
              first.contains("{") == false else { return nil }

        let program = (first as NSString).expandingTildeInPath
        if program.contains("/") {
            guard program.hasPrefix("/") else { return nil }
            if FileManager.default.isExecutableFile(atPath: program) { return nil }
            if FileManager.default.fileExists(atPath: program) {
                return "Not executable: \(program)."
            }
            return "Command not found: \(program)."
        }

        let path = spec.environment["PATH"] ?? CommandResolver.defaultPATH
        var existing: String?
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(program).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return nil }
            if existing == nil, FileManager.default.fileExists(atPath: candidate) {
                existing = candidate
            }
        }
        if let existing { return "Not executable: \(existing)." }
        return "Command not found: \(program)."
    }

    /// The argument after `shortcuts run`, when the line is an argv invocation
    /// of the Shortcuts CLI. `{placeholders}` are ignored: the catalog cannot
    /// know what they will contain.
    static func shortcutArgument(in spec: CommandSpec) -> String? {
        guard spec.mode == .argv,
              let tokens = try? CommandLineTokenizer.tokenize(spec.line),
              tokens.count >= 3,
              tokens[0].contains("{") == false,
              URL(fileURLWithPath: (tokens[0] as NSString).expandingTildeInPath).lastPathComponent == "shortcuts",
              tokens[1] == "run",
              tokens[2].hasPrefix("-") == false else { return nil }
        return tokens[2]
    }

    /// Names inside braces that are not placeholders but are close enough to
    /// one to look like a typo. `jq '{title}'` is intentionally not a typo.
    static func placeholderTypos(in line: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\\{([A-Za-z][A-Za-z0-9_]*)\\}") else {
            return []
        }
        let known = Set(CommandPlaceholder.allCases.map(\.rawValue))
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        var result: [String] = []
        var seen = Set<String>()
        for match in regex.matches(in: line, range: range) {
            guard match.numberOfRanges > 1,
                  let nameRange = Range(match.range(at: 1), in: line) else { continue }
            let name = String(line[nameRange])
            guard known.contains(name) == false, seen.insert(name).inserted else { continue }
            let closest = known
                .map { (name: $0, distance: levenshtein(name, $0)) }
                .filter { $0.distance <= 2 }
                .min { $0.distance < $1.distance }
            if closest != nil { result.append(name) }
        }
        return result
    }

    /// The closest known placeholder for a typo, used in the warning text.
    static func suggestion(for name: String) -> String? {
        let known = CommandPlaceholder.allCases.map(\.rawValue)
        return known
            .map { (name: $0, distance: levenshtein(name, $0)) }
            .filter { $0.distance <= 2 }
            .min { $0.distance < $1.distance }?
            .name
    }

    private static func levenshtein(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }
        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)
        for i in 1...left.count {
            current[0] = i
            for j in 1...right.count {
                let cost = left[i - 1] == right[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[right.count]
    }
}

/// `KEY=VALUE` lines for the environment editor. Kept pure so the parser can be
/// tested without a view, and so an invalid line is reported instead of being
/// silently dropped from the command.
enum DropzoneEnvironmentText {
    static func format(_ values: [String: String]) -> String {
        values.keys.sorted().map { key in "\(key)=\(values[key] ?? "")" }.joined(separator: "\n")
    }

    static func parse(_ text: String) -> (values: [String: String], invalid: [String]) {
        var values: [String: String] = [:]
        var invalid: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.isEmpty == false, line.hasPrefix("#") == false else { continue }
            guard let equals = line.firstIndex(of: "=") else {
                invalid.append(line)
                continue
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard key.isEmpty == false,
                  key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                invalid.append(line)
                continue
            }
            values[key] = value
        }
        return (values, invalid)
    }
}

extension DropzoneStore.Snapshot {
    var futureVersionMessage: String {
        if case let .futureVersion(version) = state {
            return "This file was written by a newer MakiDesk (version \(version)); it is read-only."
        }
        return "This configuration cannot be edited."
    }
}

extension Notification.Name {
    /// Posted when the confirmation hash is stored for a zone. An open editor
    /// with no draft reloads so the lock badge goes away.
    static let makiDeskDropzonesChanged = Notification.Name("makiDeskDropzonesChanged")
    /// Posted after a factory reset deletes the file: an open editor reloads,
    /// even with a draft, because the user asked to remove the zones.
    static let makiDeskDropzonesReset = Notification.Name("makiDeskDropzonesReset")
}
