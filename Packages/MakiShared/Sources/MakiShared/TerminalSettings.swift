import Foundation

/// One saved SSH target. The helper only turns it into an `ssh` command line:
/// keys, `known_hosts` and prompts remain `ssh`'s own.
public struct TerminalSSHProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var host: String
    public var user: String
    public var port: Int?
    public var identityFile: String?
    /// Passed to `ssh` as the remote command, not interpreted locally.
    public var remoteCommand: String?
    public var forwardAgent: Bool

    public init(id: UUID = UUID(),
                name: String = "",
                host: String = "",
                user: String = "",
                port: Int? = nil,
                identityFile: String? = nil,
                remoteCommand: String? = nil,
                forwardAgent: Bool = false) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.remoteCommand = remoteCommand
        self.forwardAgent = forwardAgent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        user = try container.decodeIfPresent(String.self, forKey: .user) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        identityFile = try container.decodeIfPresent(String.self, forKey: .identityFile)
        remoteCommand = try container.decodeIfPresent(String.self, forKey: .remoteCommand)
        forwardAgent = try container.decodeIfPresent(Bool.self, forKey: .forwardAgent) ?? false
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false { return trimmed }
        return host
    }

    public var isValid: Bool {
        host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && (port == nil || (1...65535).contains(port ?? 0))
    }

    /// A shell-safe command line for Ghostty's `command`. Nil when there is no
    /// host. Values are single-quoted only when they need it.
    public func commandLine() -> String? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedHost.isEmpty == false else { return nil }
        var parts = ["ssh"]
        if let port, (1...65535).contains(port) {
            parts += ["-p", "\(port)"]
        }
        if let identity = identityFile?.trimmingCharacters(in: .whitespacesAndNewlines),
           identity.isEmpty == false {
            parts += ["-i", Self.quoted(identity)]
        }
        if forwardAgent { parts.append("-A") }
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = trimmedUser.isEmpty ? trimmedHost : "\(trimmedUser)@\(trimmedHost)"
        parts.append(Self.quoted(target))
        if let remote = remoteCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
           remote.isEmpty == false {
            parts.append(Self.quoted(remote))
        }
        return parts.joined(separator: " ")
    }

    public func normalized() -> TerminalSSHProfile {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.identityFile = Self.cleaned(identityFile)
        copy.remoteCommand = Self.cleaned(remoteCommand)
        if let port, (1...65535).contains(port) == false {
            copy.port = nil
        }
        return copy
    }

    /// Minimal shell quoting: a target like `user@host` stays readable, while
    /// a path with spaces or a remote command with `&&` is protected.
    static func quoted(_ value: String) -> String {
        let safe = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%_-./:~")
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The terminal cursor shapes Ghostty accepts.
public enum TerminalCursorStyle: String, Codable, CaseIterable, Sendable {
    case block
    case bar
    case underline
    case blockHollow = "block_hollow"

    public var label: String {
        switch self {
        case .block: return "Block"
        case .bar: return "Bar"
        case .underline: return "Underline"
        case .blockHollow: return "Hollow block"
        }
    }
}

/// The terminal helper's preferences, written by MakiDesk and read by the
/// helper at launch and after a change. Plain value types: the file is the
/// contract, not the UI.
public struct TerminalSettingsDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// Nil or empty keeps the built-in monospaced family.
    public var fontFamily: String?
    /// Points, 10…20.
    public var fontSize: Double
    /// Nil or empty means the user's login shell.
    public var shell: String?
    /// Share of the visible frame used by the quake panel, 0.3…0.6.
    public var quakeHeightFraction: Double
    /// The cursor shape; a running program can still override it with
    /// `DECSCUSR`, and Ghostty's shell integration cursor is disabled so the
    /// choice shows at the prompt too.
    public var cursorStyle: TerminalCursorStyle
    public var cursorBlink: Bool
    /// Scrollback memory per pane, in megabytes; nil keeps Ghostty's default.
    /// A change applies to new panes only.
    public var scrollbackLimitMB: Int?
    /// Saved SSH targets offered in the helper's sidebar.
    public var sshProfiles: [TerminalSSHProfile]

    public init(version: Int = TerminalSettingsDocument.currentVersion,
                fontFamily: String? = nil,
                fontSize: Double = 13,
                shell: String? = nil,
                quakeHeightFraction: Double = 0.45,
                cursorStyle: TerminalCursorStyle = .block,
                cursorBlink: Bool = true,
                scrollbackLimitMB: Int? = nil,
                sshProfiles: [TerminalSSHProfile] = []) {
        self.version = version
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.shell = shell
        self.quakeHeightFraction = quakeHeightFraction
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.scrollbackLimitMB = scrollbackLimitMB
        self.sshProfiles = sshProfiles
    }

    public static var defaults: TerminalSettingsDocument { .init() }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
            ?? TerminalSettingsDocument.currentVersion
        fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily)
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 13
        shell = try container.decodeIfPresent(String.self, forKey: .shell)
        quakeHeightFraction = try container.decodeIfPresent(Double.self,
                                                           forKey: .quakeHeightFraction) ?? 0.45
        cursorStyle = try container.decodeIfPresent(TerminalCursorStyle.self,
                                                    forKey: .cursorStyle) ?? .block
        cursorBlink = try container.decodeIfPresent(Bool.self, forKey: .cursorBlink) ?? true
        scrollbackLimitMB = try container.decodeIfPresent(Int.self, forKey: .scrollbackLimitMB)
        sshProfiles = try container.decodeIfPresent([TerminalSSHProfile].self,
                                                    forKey: .sshProfiles) ?? []
    }

    /// A hand-edited file cannot put the font at 2 pt or the quake over the
    /// whole screen.
    public func normalized() -> TerminalSettingsDocument {
        var copy = self
        copy.version = Self.currentVersion
        copy.fontSize = min(max(fontSize, 10), 20)
        copy.quakeHeightFraction = min(max(quakeHeightFraction, 0.3), 0.6)
        copy.fontFamily = Self.cleaned(fontFamily)
        copy.shell = Self.cleaned(shell)
        if let limit = scrollbackLimitMB {
            copy.scrollbackLimitMB = min(max(limit, 1), 1024)
        }
        copy.sshProfiles = sshProfiles.map { $0.normalized() }
        return copy
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The terminal colours generated from the MakiDesk palette. ANSI colours are
/// sixteen `#RRGGBB` strings; the helper falls back per entry when one is
/// missing or malformed.
public struct TerminalThemeDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var id: String
    public var name: String
    public var background: String
    public var foreground: String
    public var cursor: String
    public var selectionBackground: String
    public var selectionForeground: String
    /// The helper's own window chrome follows the same palette. Optional so an
    /// older theme file still reads; `normalized()` fills them.
    public var surface: String?
    public var surfaceSelected: String?
    public var subtext: String?
    public var accent: String?
    public var border: String?
    public var ansi: [String]

    public init(version: Int = TerminalThemeDocument.currentVersion,
                id: String,
                name: String,
                background: String,
                foreground: String,
                cursor: String,
                selectionBackground: String,
                selectionForeground: String,
                surface: String? = nil,
                surfaceSelected: String? = nil,
                subtext: String? = nil,
                accent: String? = nil,
                border: String? = nil,
                ansi: [String] = TerminalThemeDocument.standardANSI) {
        self.version = version
        self.id = id
        self.name = name
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.surface = surface
        self.surfaceSelected = surfaceSelected
        self.subtext = subtext
        self.accent = accent
        self.border = border
        self.ansi = ansi
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = TerminalThemeDocument.fallback
        version = try container.decodeIfPresent(Int.self, forKey: .version)
            ?? TerminalThemeDocument.currentVersion
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? fallback.id
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? fallback.name
        background = try container.decodeIfPresent(String.self, forKey: .background)
            ?? fallback.background
        foreground = try container.decodeIfPresent(String.self, forKey: .foreground)
            ?? fallback.foreground
        cursor = try container.decodeIfPresent(String.self, forKey: .cursor) ?? fallback.cursor
        selectionBackground = try container.decodeIfPresent(String.self,
                                                            forKey: .selectionBackground)
            ?? fallback.selectionBackground
        selectionForeground = try container.decodeIfPresent(String.self,
                                                            forKey: .selectionForeground)
            ?? fallback.selectionForeground
        surface = try container.decodeIfPresent(String.self, forKey: .surface)
        surfaceSelected = try container.decodeIfPresent(String.self, forKey: .surfaceSelected)
        subtext = try container.decodeIfPresent(String.self, forKey: .subtext)
        accent = try container.decodeIfPresent(String.self, forKey: .accent)
        border = try container.decodeIfPresent(String.self, forKey: .border)
        ansi = try container.decodeIfPresent([String].self, forKey: .ansi) ?? fallback.ansi
    }

    public static let standardANSI: [String] = [
        "#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF",
        "#89B4FA", "#F5C2E7", "#94E2D5", "#BAC2DE",
        "#585B70", "#F38BA8", "#A6E3A1", "#F9E2AF",
        "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8",
    ]

    /// Mocha, for a helper launched without MakiDesk or a theme file.
    public static let fallback = TerminalThemeDocument(
        id: "mocha",
        name: "Mocha",
        background: "#1E1E2E",
        foreground: "#CDD6F4",
        cursor: "#CBA6F7",
        selectionBackground: "#585B70",
        selectionForeground: "#CDD6F4",
        surface: "#313244",
        surfaceSelected: "#45475A",
        subtext: "#A6ADC8",
        accent: "#CBA6F7",
        border: "#585B70"
    )

    /// Keeps sixteen well-formed colours and a resolved pair of surfaces.
    public func normalized() -> TerminalThemeDocument {
        let fallback = Self.fallback
        var copy = self
        copy.version = Self.currentVersion
        copy.background = Self.colour(background, fallback: fallback.background)
        copy.foreground = Self.colour(foreground, fallback: fallback.foreground)
        copy.cursor = Self.colour(cursor, fallback: fallback.cursor)
        copy.selectionBackground = Self.colour(selectionBackground,
                                               fallback: fallback.selectionBackground)
        copy.selectionForeground = Self.colour(selectionForeground,
                                               fallback: fallback.selectionForeground)
        copy.surface = Self.colour(surface ?? copy.background, fallback: copy.background)
        copy.surfaceSelected = Self.colour(surfaceSelected ?? copy.selectionBackground,
                                           fallback: copy.selectionBackground)
        copy.subtext = Self.colour(subtext ?? copy.foreground, fallback: copy.foreground)
        copy.accent = Self.colour(accent ?? copy.cursor, fallback: copy.cursor)
        copy.border = Self.colour(border ?? copy.selectionBackground,
                                  fallback: copy.selectionBackground)
        var colours: [String] = []
        for index in 0..<16 {
            let candidate = index < ansi.count ? ansi[index] : ""
            let fallbackColour = index < Self.standardANSI.count
                ? Self.standardANSI[index] : "#FFFFFF"
            colours.append(Self.colour(candidate, fallback: fallbackColour))
        }
        copy.ansi = colours
        return copy
    }

    private static func colour(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.count == 7, trimmed.hasPrefix("#"),
              trimmed.dropFirst().allSatisfy({ $0.isHexDigit }) else {
            return fallback
        }
        return trimmed
    }
}

/// Reads and writes the helper's settings file.
public struct TerminalSettingsStore {
    public let fileURL: URL

    public init(fileURL: URL = TerminalSettingsStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        TerminalSocketLocation.directory.appendingPathComponent("settings.json")
    }

    public func load() -> TerminalSettingsDocument {
        guard let data = try? Data(contentsOf: fileURL) else { return .defaults }
        do {
            return try StoredJSONFile.decoder()
                .decode(TerminalSettingsDocument.self, from: data).normalized()
        } catch {
            StoredJSONFile.quarantine(fileURL, label: "terminal settings")
            return .defaults
        }
    }

    @discardableResult
    public func save(_ document: TerminalSettingsDocument) -> Bool {
        var payload = document.normalized()
        payload.version = TerminalSettingsDocument.currentVersion
        guard let data = try? StoredJSONFile.encoder().encode(payload) else { return false }
        do {
            try StoredJSONFile.write(data, to: fileURL)
            return true
        } catch {
            return false
        }
    }
}

/// Reads and writes the helper's theme file.
public struct TerminalThemeStore {
    public let fileURL: URL

    public init(fileURL: URL = TerminalThemeStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        TerminalSocketLocation.directory.appendingPathComponent("theme.json")
    }

    public func load() -> TerminalThemeDocument {
        guard let data = try? Data(contentsOf: fileURL) else { return .fallback }
        do {
            return try StoredJSONFile.decoder()
                .decode(TerminalThemeDocument.self, from: data).normalized()
        } catch {
            StoredJSONFile.quarantine(fileURL, label: "terminal theme")
            return .fallback
        }
    }

    @discardableResult
    public func save(_ document: TerminalThemeDocument) -> Bool {
        var payload = document.normalized()
        payload.version = TerminalThemeDocument.currentVersion
        guard let data = try? StoredJSONFile.encoder().encode(payload) else { return false }
        do {
            try StoredJSONFile.write(data, to: fileURL)
            return true
        } catch {
            return false
        }
    }
}
