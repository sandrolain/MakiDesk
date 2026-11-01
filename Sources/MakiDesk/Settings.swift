import Foundation

/// Typed access to the preferences (R02).
///
/// The rule this type exists to enforce is that a default is written **once**.
/// Before it, the fallback lived in the expression that read the key
/// (`object(forKey:) as? Bool ?? true`) and nowhere else, so "never set" and
/// "set to the value the code would have used" were different states that
/// looked identical — and a default registered somewhere else could disagree
/// with the inline one and change behaviour without a single test noticing.
///
/// Now the default lives in `SettingsDefaults`, `register(defaults:)` is built
/// from the same table, and the reading code asks for the key and nothing else.
enum Settings {
    // MARK: - Reading

    /// `false` when the key was never set **and** is not registered: a key with
    /// a non-false default must be in `SettingsDefaults`, and a test says so.
    static func bool(_ key: SettingsKey, in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key.rawValue)
    }

    static func int(_ key: SettingsKey, in defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: key.rawValue)
    }

    static func double(_ key: SettingsKey, in defaults: UserDefaults = .standard) -> Double {
        defaults.double(forKey: key.rawValue)
    }

    static func string(_ key: SettingsKey, in defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key.rawValue)
    }

    /// A value stored as its raw string, for the enums the UI offers.
    static func value<T: RawRepresentable>(_ key: SettingsKey, as type: T.Type = T.self,
                                           in defaults: UserDefaults = .standard) -> T?
    where T.RawValue == String {
        defaults.string(forKey: key.rawValue).flatMap(T.init(rawValue:))
    }

    // MARK: - Writing

    static func set(_ value: Any, for key: SettingsKey, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key.rawValue)
    }

    static func remove(_ key: SettingsKey, in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key.rawValue)
    }

    // MARK: - Defaults

    /// Registers the declared defaults. Called once, before anything reads a
    /// preference: after this, "unset" and "the default" are the same value.
    static func registerDefaults(in defaults: UserDefaults = .standard) {
        var table: [String: Any] = [:]
        for (key, value) in SettingsDefaults.table {
            table[key.rawValue] = value
        }
        defaults.register(defaults: table)
    }
}

/// The declared defaults, one domain at a time (R02).
///
/// A key enters this table together with the reads that consume it: registering
/// a value before its readers move would leave two defaults in force at once,
/// which is the problem the table exists to end. Where a constant already
/// existed for the UI to reset to, the table points at it instead of copying
/// the number.
enum SettingsDefaults {
    /// Built on demand: a `[SettingsKey: Any]` cannot be a shared constant
    /// under strict concurrency, and it is read once at launch.
    static var table: [SettingsKey: Any] {
        [
        // HUD (T52/T60): bottom centre, 1.4 s, history on, VoiceOver on.
        .hudPosition: HUDPosition.bottomCenter.rawValue,
        .hudScreenLocation: PaletteScreenLocation.focusedWindow.rawValue,
        .hudBaseDuration: HUDSettings.defaultBaseDuration,
        .hudHistoryEnabled: true,
        .hudVoiceOver: true,
        .hudCompact: false,
        .hudTextSize: Double(HUDSettings.defaultTextSize),
        .hudKeepErrors: false,
        ]
    }
}
