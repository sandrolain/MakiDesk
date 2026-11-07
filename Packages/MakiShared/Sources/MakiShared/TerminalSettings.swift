import Foundation

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

    public init(version: Int = TerminalSettingsDocument.currentVersion,
                fontFamily: String? = nil,
                fontSize: Double = 13,
                shell: String? = nil,
                quakeHeightFraction: Double = 0.45) {
        self.version = version
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.shell = shell
        self.quakeHeightFraction = quakeHeightFraction
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
    public var ansi: [String]

    public init(version: Int = TerminalThemeDocument.currentVersion,
                id: String,
                name: String,
                background: String,
                foreground: String,
                cursor: String,
                selectionBackground: String,
                selectionForeground: String,
                ansi: [String] = TerminalThemeDocument.standardANSI) {
        self.version = version
        self.id = id
        self.name = name
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
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
        selectionForeground: "#CDD6F4"
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
