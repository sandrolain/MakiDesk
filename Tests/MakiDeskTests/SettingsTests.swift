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
        XCTAssertNil(defaults.object(forKey: SettingsKey.themeID.rawValue))
        XCTAssertNil(defaults.object(forKey: SettingsKey.windowGap.rawValue))
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

    func testRemovingAKeyReturnsToTheDefault() {
        Settings.registerDefaults(in: defaults)
        Settings.set(false, for: .hudVoiceOver, in: defaults)
        XCTAssertFalse(Settings.bool(.hudVoiceOver, in: defaults))
        Settings.remove(.hudVoiceOver, in: defaults)
        XCTAssertTrue(Settings.bool(.hudVoiceOver, in: defaults))
    }
}
