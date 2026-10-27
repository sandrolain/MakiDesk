import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// One drop target: what it accepts, which command it runs and how it reports.
///
/// This is the persisted shape (`dropzones.json`); the executable behaviour
/// lives in `DropzoneMatcher` and `CommandRunner`. Pure value type, so it can be
/// decoded, validated and tested without AppKit or a real drop.
struct DropzoneConfig: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var icon: DropzoneIcon
    var enabled: Bool
    var accepts: DropzoneAccept
    var command: CommandSpec
    /// Optional path template checked before a run. If it already exists, the
    /// app asks before executing a command that may replace it. Presets that
    /// write next to the source set this; a custom command can leave it empty.
    var expectedOutput: String?
    var feedback: DropFeedback
    /// Hash of what was confirmed; `nil` means the first run still needs a
    /// confirmation. Recomputed from the command, so editing it asks again.
    var confirmedCommandHash: String?
    var createdAt: Date?

    init(id: UUID = UUID(),
         name: String = "",
         icon: DropzoneIcon = .symbol("bolt.fill"),
         enabled: Bool = true,
         accepts: DropzoneAccept = DropzoneAccept(),
         command: CommandSpec = CommandSpec(),
         expectedOutput: String? = nil,
         feedback: DropFeedback = DropFeedback(),
         confirmedCommandHash: String? = nil,
         createdAt: Date? = Date()) {
        self.id = id
        self.name = name
        self.icon = icon
        self.enabled = enabled
        self.accepts = accepts
        self.command = command
        self.expectedOutput = expectedOutput
        self.feedback = feedback
        self.confirmedCommandHash = confirmedCommandHash
        self.createdAt = createdAt
    }

    /// Hand-edited files are expected, so a missing field falls back to its
    /// default instead of turning the whole file into a corrupt one.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        icon = try container.decodeIfPresent(DropzoneIcon.self, forKey: .icon) ?? .symbol("bolt.fill")
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        accepts = try container.decodeIfPresent(DropzoneAccept.self, forKey: .accepts) ?? DropzoneAccept()
        command = try container.decodeIfPresent(CommandSpec.self, forKey: .command) ?? CommandSpec()
        expectedOutput = try container.decodeIfPresent(String.self, forKey: .expectedOutput)
        feedback = try container.decodeIfPresent(DropFeedback.self, forKey: .feedback) ?? DropFeedback()
        confirmedCommandHash = try container.decodeIfPresent(String.self, forKey: .confirmedCommandHash)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

// MARK: - Icon

enum DropzoneIcon: Equatable, Sendable {
    case symbol(String)
    case emoji(String)
    /// Path relative to `Application Support/MakiDesk/DropzoneIcons/`.
    case file(String)

    var symbolName: String? {
        if case let .symbol(name) = self { return name }
        return nil
    }
}

extension DropzoneIcon: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case symbol, emoji, file }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .symbol
        let value = try container.decodeIfPresent(String.self, forKey: .value) ?? "bolt.fill"
        switch kind {
        case .symbol: self = .symbol(value)
        case .emoji: self = .emoji(value)
        case .file: self = .file(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .symbol(value):
            try container.encode(Kind.symbol, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .emoji(value):
            try container.encode(Kind.emoji, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .file(value):
            try container.encode(Kind.file, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

// MARK: - What it accepts

struct DropzoneAccept: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case files
        case text
        case urls
        case images
    }

    enum Match: String, Codable, Sendable {
        /// Every dropped item must be accepted.
        case all
        /// At least one item must be accepted; the others are not passed.
        case any
    }

    /// Sorted and unique, so the JSON stays stable across saves.
    var kinds: [Kind]
    /// UTIs for files. Empty means any file type.
    var utis: [String]
    var match: Match
    var minItems: Int?
    var maxItems: Int?

    init(kinds: [Kind] = [.files],
         utis: [String] = [],
         match: Match = .all,
         minItems: Int? = 1,
         maxItems: Int? = nil) {
        self.kinds = Self.normalized(kinds)
        self.utis = Self.normalized(utis)
        self.match = match
        self.minItems = minItems
        self.maxItems = maxItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kinds = Self.normalized(try container.decodeIfPresent([Kind].self, forKey: .kinds) ?? [.files])
        utis = Self.normalized(try container.decodeIfPresent([String].self, forKey: .utis) ?? [])
        match = try container.decodeIfPresent(Match.self, forKey: .match) ?? .all
        minItems = try container.decodeIfPresent(Int.self, forKey: .minItems) ?? 1
        maxItems = try container.decodeIfPresent(Int.self, forKey: .maxItems)
        // A zero minimum is the same as one item and only makes the editor
        // confusing; normalise it here so the matcher has one shape to handle.
        if let minimum = minItems, minimum < 1 { minItems = 1 }
    }

    func accepts(kind: Kind) -> Bool { kinds.contains(kind) }

    private static func normalized(_ kinds: [Kind]) -> [Kind] {
        Kind.allCases.filter { kinds.contains($0) }
    }

    private static func normalized(_ utis: [String]) -> [String] {
        var seen = Set<String>()
        return utis
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false && seen.insert($0).inserted }
    }
}

// MARK: - Feedback

struct DropFeedback: Codable, Equatable, Sendable {
    enum Output: String, Codable, Sendable {
        case none
        case stdout
        case reveal
        /// Copies what the command produced (its files, else stdout) to the
        /// clipboard (T47).
        case clipboard
        /// Adds what the command produced (its files, else stdout) to the
        /// Shelf (T47).
        case shelf
    }

    var notifyOnSuccess: Bool
    /// `stdout` shows the output in the result notice; `reveal` opens the
    /// output folder in Finder; `clipboard`/`shelf` send the produced files to
    /// the clipboard or the Shelf.
    var showOutput: Output
    var revealOutput: Bool

    init(notifyOnSuccess: Bool = true, showOutput: Output = .none, revealOutput: Bool = false) {
        self.notifyOnSuccess = notifyOnSuccess
        self.showOutput = showOutput
        self.revealOutput = revealOutput
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        notifyOnSuccess = try container.decodeIfPresent(Bool.self, forKey: .notifyOnSuccess) ?? true
        // A value written by a newer build (or edited by hand) must not make
        // the whole file unreadable: an unknown destination means `none`.
        if let raw = try? container.decodeIfPresent(String.self, forKey: .showOutput),
           let output = Output(rawValue: raw) {
            showOutput = output
        } else {
            showOutput = .none
        }
        revealOutput = try container.decodeIfPresent(Bool.self, forKey: .revealOutput) ?? false
    }
}

// MARK: - Confirmation and validation

extension DropzoneConfig {
    /// What the user confirmed: the command that will run. The timeout and the
    /// feedback do not change the code path, so they are not part of the hash.
    static func confirmationHash(for command: CommandSpec) -> String {
        let environment = command.environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\u{0}")
        let material = [
            command.line,
            command.mode.rawValue,
            command.stdin.rawValue,
            command.workingDirectory ?? "",
            environment
        ].joined(separator: "\u{0}\u{0}")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    var requiresConfirmation: Bool {
        confirmedCommandHash != Self.confirmationHash(for: command)
    }

    mutating func markConfirmed() {
        confirmedCommandHash = Self.confirmationHash(for: command)
    }

    /// What prevents this zone from being stored or offered, with the messages
    /// the editor shows. An invalid UTI is reported but does not crash the
    /// matcher, which refuses the zone instead.
    func issues() -> [DropzoneIssue] {
        var issues: [DropzoneIssue] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.emptyName)
        }
        if name.count > Self.maximumNameLength {
            issues.append(.nameTooLong)
        }
        let line = command.line.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty {
            issues.append(.emptyCommand)
        }
        if command.line.count > Self.maximumCommandLength {
            issues.append(.commandLineTooLong)
        }
        if (0...3600).contains(command.timeoutSeconds) == false {
            issues.append(.invalidTimeout(command.timeoutSeconds))
        }
        if accepts.kinds.isEmpty {
            issues.append(.noAcceptedKinds)
        }
        if let minimum = accepts.minItems, minimum < 1 {
            issues.append(.invalidItemRange)
        }
        if let minimum = accepts.minItems, let maximum = accepts.maxItems, maximum < minimum {
            issues.append(.invalidItemRange)
        }
        if let maximum = accepts.maxItems, maximum > Self.maximumItems {
            issues.append(.invalidItemRange)
        }
        for uti in accepts.utis where UTType(uti) == nil {
            issues.append(.invalidUTI(uti))
        }
        return issues
    }

    static let maximumNameLength = 80
    static let maximumCommandLength = 4096
    static let maximumItems = 100
}

enum DropzoneIssue: Equatable, Sendable, LocalizedError {
    case emptyName
    case nameTooLong
    case emptyCommand
    case commandLineTooLong
    case invalidTimeout(Int)
    case noAcceptedKinds
    case invalidItemRange
    case invalidUTI(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "The dropzone needs a name."
        case .nameTooLong:
            return "The name is too long (80 characters at most)."
        case .emptyCommand:
            return "The dropzone needs a command."
        case .commandLineTooLong:
            return "The command is too long (4096 characters at most)."
        case let .invalidTimeout(seconds):
            return "The timeout must be 0 (none) or 1–3600 seconds; got \(seconds)."
        case .noAcceptedKinds:
            return "Choose at least one kind of item the dropzone accepts."
        case .invalidItemRange:
            return "The item count range is invalid."
        case let .invalidUTI(uti):
            return "\(uti) is not a valid Uniform Type Identifier."
        }
    }
}
