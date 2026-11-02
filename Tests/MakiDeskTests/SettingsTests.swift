import XCTest
@testable import MakiDesk

/// R02: a default is written once and both the read and `register(defaults:)`
/// use it. These tests read an empty suite the way the app does at launch.
final class SettingsTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "MakiDeskSettings-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testAnEmptySuiteReadsTheDeclaredDefaults() {
        Settings.registerDefaults(in: defaults)

        XCTAssertEqual(Settings.value(.hudPosition, in: defaults), HUDPosition.bottomCenter)
        XCTAssertEqual(Settings.value(.hudScreenLocation, in: defaults),
                       PaletteScreenLocation.focusedWindow)
        XCTAssertEqual(Settings.double(.hudBaseDuration, in: defaults), 1.4, accuracy: 0.001)
        XCTAssertTrue(Settings.bool(.hudHistoryEnabled, in: defaults))
        XCTAssertTrue(Settings.bool(.hudVoiceOver, in: defaults))
        XCTAssertFalse(Settings.bool(.hudCompact, in: defaults))
        XCTAssertEqual(Settings.double(.hudTextSize, in: defaults), 14, accuracy: 0.001)
        XCTAssertFalse(Settings.bool(.hudKeepErrors, in: defaults))
    }

    func testAStoredValueWinsOverTheDefault() {
        Settings.registerDefaults(in: defaults)
        Settings.set(false, for: .hudHistoryEnabled, in: defaults)
        Settings.set(18.0, for: .hudTextSize, in: defaults)

        XCTAssertFalse(Settings.bool(.hudHistoryEnabled, in: defaults))
        XCTAssertEqual(Settings.double(.hudTextSize, in: defaults), 18, accuracy: 0.001)
    }

    /// Registering is not "create every key": a key with no default stays
    /// absent, so the code that asks whether it was ever set keeps working.
    func testRegisteringDoesNotInventKeysOutsideTheTable() {
        Settings.registerDefaults(in: defaults)
        XCTAssertNil(defaults.object(forKey: SettingsKey.setupCompleted.rawValue))
        XCTAssertNil(defaults.object(forKey: SettingsKey.idlePerformanceDiagnostics.rawValue))
        XCTAssertNil(defaults.object(forKey: SettingsKey.shelfExcludedApps.rawValue))
    }

    /// Every default has to parse as the type its readers ask for, or the read
    /// silently falls back to the zero value.
    func testEveryDeclaredDefaultParsesAsItsType() {
        XCTAssertNotNil(HUDPosition(rawValue: SettingsDefaults.table[.hudPosition] as? String ?? ""))
        XCTAssertNotNil(PaletteScreenLocation(rawValue: SettingsDefaults.table[.hudScreenLocation] as? String ?? ""))
        XCTAssertNotNil(SettingsDefaults.table[.hudBaseDuration] as? Double)
        XCTAssertNotNil(SettingsDefaults.table[.hudTextSize] as? Double)
        for key in [SettingsKey.hudHistoryEnabled, .hudVoiceOver, .hudCompact, .hudKeepErrors] {
            XCTAssertNotNil(SettingsDefaults.table[key] as? Bool, key.rawValue)
        }
    }

    /// A key whose default is not `false` must be in the table: without it the
    /// read returns the zero value and the option quietly changes meaning.
    func testTheHUDKeysAreAllDeclared() {
        let required: [SettingsKey] = [
            .hudPosition, .hudScreenLocation, .hudBaseDuration, .hudHistoryEnabled,
            .hudVoiceOver, .hudCompact, .hudTextSize, .hudKeepErrors,
        ]
        for key in required {
            XCTAssertNotNil(SettingsDefaults.table[key], "\(key.rawValue) has no default")
        }
    }

    func testTheSystemDefaultsAreDeclared() {
        Settings.registerDefaults(in: defaults)

        XCTAssertEqual(Settings.value(.systemDiskMenuBarMode, as: DiskMenuBarMode.self,
                                      in: defaults), .always)
        XCTAssertEqual(Settings.value(.systemDiskFormat, as: DiskSpaceFormat.self,
                                      in: defaults), .size)
        XCTAssertEqual(Settings.double(.systemDiskWarningThresholdGB, in: defaults), 10,
                       accuracy: 0.001)
        XCTAssertTrue(Settings.bool(.systemCPUAlertsEnabled, in: defaults))
        XCTAssertEqual(Settings.double(.systemCPUThresholdPercent, in: defaults), 100,
                       accuracy: 0.001)
        XCTAssertEqual(Settings.double(.systemCPUSustainedMinutes, in: defaults), 10,
                       accuracy: 0.001)
        XCTAssertFalse(Settings.bool(.systemCPUNotifySystem, in: defaults))
        // Never warned is the answer, not a date.
        XCTAssertEqual(Settings.double(.systemDiskWarningDate, in: defaults), 0,
                       accuracy: 0.001)
    }

    func testRemovingAKeyReturnsToTheDefault() {
        Settings.registerDefaults(in: defaults)
        Settings.set(false, for: .hudVoiceOver, in: defaults)
        XCTAssertFalse(Settings.bool(.hudVoiceOver, in: defaults))
        Settings.remove(.hudVoiceOver, in: defaults)
        XCTAssertTrue(Settings.bool(.hudVoiceOver, in: defaults))
    }

    // MARK: - Checklist and timers

    func testTheChecklistDefaultsAreDeclared() {
        Settings.registerDefaults(in: defaults)

        XCTAssertFalse(Settings.bool(.checklistVisible, in: defaults))
        XCTAssertEqual(Settings.double(.checklistOpacity, in: defaults),
                       ChecklistSettings.defaultOpacity, accuracy: 0.001)
        XCTAssertEqual(Settings.double(.checklistWidth, in: defaults),
                       ChecklistSettings.defaultWidth, accuracy: 0.001)
        XCTAssertEqual(Settings.value(.checklistPosition, in: defaults),
                       ChecklistSettings.defaultPosition)
        XCTAssertEqual(Settings.value(.checklistScreen, in: defaults),
                       ChecklistSettings.defaultScreen)
    }

    func testTheTimerDefaultsAreDeclared() {
        Settings.registerDefaults(in: defaults)

        XCTAssertTrue(Settings.bool(.timerOverlayVisible, in: defaults))
        XCTAssertEqual(Settings.double(.timerOverlayOpacity, in: defaults),
                       TimerSettings.defaultOpacity, accuracy: 0.001)
        XCTAssertEqual(Settings.value(.timerOverlayPosition, in: defaults),
                       TimerSettings.defaultPosition)
        XCTAssertEqual(Settings.value(.timerOverlayScreen, in: defaults),
                       TimerSettings.defaultScreen)
        XCTAssertTrue(Settings.bool(.timerSoundEnabled, in: defaults))
        XCTAssertEqual(Settings.string(.timerSoundName, in: defaults), TimerSettings.defaultSound)
    }

    // MARK: - Notes and screenshots

    func testTheNotesDefaultsAreDeclared() {
        Settings.registerDefaults(in: defaults)
        XCTAssertEqual(Settings.double(.notesFontSize, in: defaults), 13, accuracy: 0.001)
        XCTAssertEqual(Settings.double(.notesSidebarWidth, in: defaults), 230, accuracy: 0.001)
    }

    func testTheScreenshotDefaultsAreDeclared() {
        Settings.registerDefaults(in: defaults)

        XCTAssertTrue(Settings.bool(.screenshotCopyToClipboard, in: defaults))
        XCTAssertFalse(Settings.bool(.screenshotSavedNotice, in: defaults))
        XCTAssertTrue(Settings.bool(.recordingIncludesAudio, in: defaults))
        XCTAssertFalse(Settings.bool(.screenshotLibraryShowsRecordings, in: defaults))
        XCTAssertEqual(Settings.value(.screenshotLibrarySort, as: ScreenshotSortOrder.self,
                                      in: defaults), .newestFirst)
        XCTAssertEqual(Settings.value(.screenshotLibraryGrouping, as: ScreenshotGrouping.self,
                                      in: defaults), .month)
        XCTAssertEqual(Settings.double(.screenshotLibraryScale, in: defaults), 1, accuracy: 0.001)
    }

    /// An absent folder is "the system folder", not a value: registering one
    /// would turn "never chosen" into "chosen empty".
    func testTheLibraryFolderHasNoDefault() {
        Settings.registerDefaults(in: defaults)
        XCTAssertNil(defaults.object(forKey: SettingsKey.screenshotLibraryFolderPath.rawValue))
    }

    // MARK: - Appearance and palette

    func testTheAppearanceDefaultsAreDeclared() {
        Settings.registerDefaults(in: defaults)

        XCTAssertEqual(Settings.string(.themeID, in: defaults), "mocha")
        XCTAssertTrue(Settings.bool(.animationsEnabled, in: defaults))
        XCTAssertEqual(Settings.double(.animationDuration, in: defaults), 0.22, accuracy: 0.001)
        XCTAssertTrue(Settings.bool(.showMiniMap, in: defaults))
        XCTAssertTrue(Settings.bool(.showPreview, in: defaults))
        XCTAssertEqual(Settings.value(.miniMapPosition, as: PalettePosition.self, in: defaults),
                       .topRight)
        XCTAssertEqual(Settings.double(.overlayScale, in: defaults), 1.0, accuracy: 0.001)
        XCTAssertEqual(Settings.double(.overlayOpacity, in: defaults), 0.94, accuracy: 0.001)
    }

    func testThePaletteDefaultsAreDeclared() {
        Settings.registerDefaults(in: defaults)

        XCTAssertEqual(Settings.double(.paletteMaxCardWidth, in: defaults), 250, accuracy: 0.001)
        XCTAssertEqual(Settings.int(.paletteColumns, in: defaults), 0,
                       "0 means auto")
        XCTAssertFalse(Settings.bool(.paletteCardSizeFollowsCount, in: defaults))
        XCTAssertEqual(Settings.double(.paletteOpacity, in: defaults), 0.9, accuracy: 0.001)
        XCTAssertTrue(Settings.bool(.paletteTintedCards, in: defaults))
        XCTAssertFalse(Settings.bool(.paletteFullScreen, in: defaults))
        XCTAssertEqual(Settings.value(.paletteScreenLocation, as: PaletteScreenLocation.self,
                                      in: defaults), .focusedWindow)
        XCTAssertTrue(Settings.bool(.showGroupsInPalette, in: defaults))
        XCTAssertTrue(Settings.bool(.showEmptyGroupsInPalette, in: defaults))
    }

    /// The theme id is normalised, so a default that is not a theme would be
    /// silently replaced and the settings window would show the first one.
    func testTheThemeDefaultIsATealTheme() {
        Settings.registerDefaults(in: defaults)
        let id = Settings.string(.themeID, in: defaults) ?? ""
        XCTAssertEqual(PaletteTheme.normalized(id), id)
    }

    // MARK: - Focus border and dim

    func testTheFocusDefaultsAreDeclared() {
        Settings.registerDefaults(in: defaults)

        XCTAssertTrue(Settings.bool(.focusBorderEnabled, in: defaults))
        XCTAssertEqual(Settings.double(.focusBorderWidth, in: defaults),
                       FocusBorder.defaultWidth, accuracy: 0.001)
        XCTAssertFalse(Settings.bool(.focusDimEnabled, in: defaults),
                       "the dim is opt-in: it changes the whole screen")
        XCTAssertEqual(Settings.double(.focusDimOpacity, in: defaults),
                       FocusDim.defaultOpacity, accuracy: 0.001)
        XCTAssertEqual(Settings.double(.focusDimFade, in: defaults),
                       FocusDim.defaultFade, accuracy: 0.001)
        XCTAssertFalse(Settings.bool(.focusDimDesktopDims, in: defaults))
        XCTAssertFalse(Settings.bool(.focusDimStopsOnAppChange, in: defaults))
    }

    func testTheFocusEnumsParseFromTheirDefaults() {
        Settings.registerDefaults(in: defaults)
        XCTAssertEqual(Settings.value(.focusDimColour, as: FocusDim.Colour.self, in: defaults),
                       .black)
        XCTAssertEqual(Settings.value(.focusDimSource, as: FocusDim.Source.self, in: defaults),
                       .window)
        XCTAssertEqual(Settings.value(.focusDimDisplayMode,
                                      as: FocusDim.DisplayMode.self, in: defaults),
                       .independent)
    }

    // MARK: - Recognition, shelf, drag and pickers

    func testTheRecognitionDefaultsAreDeclared() {
        Settings.registerDefaults(in: defaults)

        XCTAssertFalse(Settings.bool(.ocrFastRecognition, in: defaults))
        XCTAssertTrue(Settings.bool(.ocrLanguageCorrection, in: defaults))
        XCTAssertEqual(Settings.value(.ocrOutputDestination,
                                      as: TextRecognitionOutput.self, in: defaults),
                       .pasteboardAndHistory)
        XCTAssertEqual(Settings.value(.ocrRevealHistory, as: OCRRevealHistory.self, in: defaults),
                       .never)
    }

    func testTheShelfAndDragDefaultsAreDeclared() {
        Settings.registerDefaults(in: defaults)

        XCTAssertTrue(Settings.bool(.shelfShakeEnabled, in: defaults))
        XCTAssertEqual(Settings.value(.shelfShakeSensitivity,
                                      as: ShelfShakeSensitivity.self, in: defaults), .medium)
        XCTAssertTrue(Settings.bool(.dragEnabled, in: defaults))
        XCTAssertEqual(Settings.value(.dragActivator, as: DragActivator.self, in: defaults),
                       .fallback)
    }

    func testTheWindowAndPickerDefaultsAreDeclared() {
        Settings.registerDefaults(in: defaults)

        XCTAssertEqual(Settings.double(.windowGap, in: defaults), 12, accuracy: 0.001)
        XCTAssertTrue(Settings.bool(.layoutAsksFirst, in: defaults))
        XCTAssertTrue(Settings.bool(.announceGroupChanges, in: defaults))
        XCTAssertEqual(Settings.value(.measureUnit, as: MeasurementUnit.self, in: defaults),
                       .points)
        XCTAssertEqual(Settings.value(.colorPickerFormat, as: ColorClipboardFormat.self,
                                      in: defaults), .hex)
    }

    /// The table is the list of keys whose reads have moved. Adding a domain
    /// means adding it here, which forces the question "are its reads using
    /// this, or still carrying their own fallback?".
    func testTheTableCoversExactlyTheMigratedDomains() {
        let expected: Set<SettingsKey> = [
            .hudPosition, .hudScreenLocation, .hudBaseDuration, .hudHistoryEnabled,
            .hudVoiceOver, .hudCompact, .hudTextSize, .hudKeepErrors,
            .checklistVisible, .checklistOpacity, .checklistWidth, .checklistPosition,
            .checklistScreen,
            .timerOverlayVisible, .timerOverlayOpacity, .timerOverlayPosition,
            .timerOverlayScreen, .timerSoundEnabled, .timerSoundName,
            .notesFontSize, .notesSidebarWidth,
            .clipboardKeepsImages, .clipboardImageBudgetMB,
            .screenshotCopyToClipboard, .screenshotSavedNotice, .recordingIncludesAudio,
            .screenshotLibrarySort, .screenshotLibraryGrouping,
            .screenshotLibraryScale, .screenshotLibraryShowsRecordings,
            .themeID, .animationsEnabled, .animationDuration,
            .showMiniMap, .showPreview, .miniMapPosition,
            .overlayScale, .overlayOpacity,
            .paletteMaxCardWidth, .paletteColumns, .paletteCardSizeFollowsCount,
            .paletteOpacity, .paletteTintedCards, .paletteFullScreen,
            .paletteScreenLocation, .showGroupsInPalette, .showEmptyGroupsInPalette,
            .focusBorderEnabled, .focusBorderWidth,
            .focusDimEnabled, .focusDimOpacity, .focusDimFade, .focusDimColour,
            .focusDimSource, .focusDimDisplayMode, .focusDimDesktopDims,
            .focusDimStopsOnAppChange,
            .ocrFastRecognition, .ocrLanguageCorrection,
            .ocrOutputDestination, .ocrRevealHistory,
            .shelfShakeEnabled, .shelfShakeSensitivity,
            .dragEnabled, .dragActivator, .layoutAsksFirst, .announceGroupChanges,
            .windowGap, .measureUnit, .colorPickerFormat,
            .systemDiskMenuBarMode, .systemDiskFormat, .systemDiskWarningThresholdGB,
            .systemCPUAlertsEnabled, .systemCPUThresholdPercent,
            .systemCPUSustainedMinutes, .systemCPUNotifySystem,
        ]
        XCTAssertEqual(Set(SettingsDefaults.table.keys), expected)
    }
}
