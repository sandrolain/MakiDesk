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

        // Checklist (T59): hidden until asked for, 0.85, 320 pt, top right.
        .checklistVisible: false,
        .checklistOpacity: ChecklistSettings.defaultOpacity,
        .checklistWidth: ChecklistSettings.defaultWidth,
        .checklistPosition: ChecklistSettings.defaultPosition.rawValue,
        .checklistScreen: ChecklistSettings.defaultScreen.rawValue,

        // Countdown card (T61): shown, 0.6, top centre, a Glass chime.
        .timerOverlayVisible: true,
        .timerOverlayOpacity: TimerSettings.defaultOpacity,
        .timerOverlayPosition: TimerSettings.defaultPosition.rawValue,
        .timerOverlayScreen: TimerSettings.defaultScreen.rawValue,
        .timerSoundEnabled: true,
        .timerSoundName: TimerSettings.defaultSound,

        // Notes: the editor's own size and the split view's starting width.
        .notesFontSize: 13.0,
        .notesSidebarWidth: 230.0,

        // Screenshots and recordings. The library folder has no default: an
        // absent key means "the system folder", which is not a value.
        .screenshotCopyToClipboard: true,
        .screenshotSavedNotice: false,
        .recordingIncludesAudio: true,
        .screenshotLibrarySort: ScreenshotSortOrder.newestFirst.rawValue,
        .screenshotLibraryGrouping: ScreenshotGrouping.month.rawValue,
        .screenshotLibraryScale: 1.0,
        .screenshotLibraryShowsRecordings: false,

        // Appearance and palette. `normalized` and the clamps that follow these
        // reads handle a value that no longer parses; they are not defaults.
        .themeID: "mocha",
        .animationsEnabled: true,
        .animationDuration: 0.22,
        .showMiniMap: true,
        .showPreview: true,
        .miniMapPosition: PalettePosition.topRight.rawValue,
        .overlayScale: 1.0,
        .overlayOpacity: 0.94,
        .paletteMaxCardWidth: 250.0,
        .paletteColumns: 0,
        .paletteCardSizeFollowsCount: false,
        .paletteOpacity: 0.9,
        .paletteTintedCards: true,
        .paletteFullScreen: false,
        .paletteScreenLocation: PaletteScreenLocation.focusedWindow.rawValue,
        .showGroupsInPalette: true,
        .showEmptyGroupsInPalette: true,

        // Focus border and dim (T36/T62). The dim is opt-in: it changes the
        // whole screen.
        .focusBorderEnabled: true,
        .focusBorderWidth: FocusBorder.defaultWidth,
        .focusDimEnabled: false,
        .focusDimOpacity: FocusDim.defaultOpacity,
        .focusDimFade: FocusDim.defaultFade,
        .focusDimColour: FocusDim.Colour.black.rawValue,
        .focusDimSource: FocusDim.Source.window.rawValue,
        .focusDimDisplayMode: FocusDim.DisplayMode.independent.rawValue,
        .focusDimDesktopDims: false,
        .focusDimStopsOnAppChange: false,

        // Text recognition (T41/T54).
        .ocrFastRecognition: false,
        .ocrLanguageCorrection: true,
        .ocrOutputDestination: TextRecognitionOutput.pasteboardAndHistory.rawValue,
        .ocrRevealHistory: OCRRevealHistory.never.rawValue,

        // Shelf, drag and layouts.
        .shelfShakeEnabled: true,
        .shelfShakeSensitivity: ShelfShakeSensitivity.medium.rawValue,
        .dragEnabled: true,
        .dragActivator: DragActivator.fallback.rawValue,
        .layoutAsksFirst: true,
        .announceGroupChanges: true,

        // Window gap and the two pickers. Three keys stay out on purpose:
        // `setupCompleted` and `idlePerformanceDiagnostics` are flags whose
        // absence is the answer, and `shelfExcludedApps` is a list.
        .windowGap: 12.0,
        .measureUnit: MeasurementUnit.points.rawValue,
        .colorPickerFormat: ColorClipboardFormat.hex.rawValue,

        // System monitor: the free space beside the icon and the CPU watch.
        // The date of the last disk warning has no default: never warned is
        // the answer, and a zero date would mean 1970.
        .systemDiskMenuBarMode: DiskMenuBarMode.always.rawValue,
        .systemDiskFormat: DiskSpaceFormat.size.rawValue,
        .systemDiskWarningThresholdGB: 10.0,
        .systemCPUAlertsEnabled: true,
        .systemCPUThresholdPercent: 100.0,
        .systemCPUSustainedMinutes: 10.0,
        .systemCPUNotifySystem: false,
        ]
    }
}
