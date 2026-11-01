import XCTest
@testable import MakiDesk

/// R02: a key is spelled once. These tests are the gate the analysis asked for
/// — no `UserDefaults` key written by hand outside the registry — and they are
/// enforced against the sources, not against a list someone has to maintain.
final class SettingsKeyTests: XCTestCase {
    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MakiDeskTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // the repository
            .appendingPathComponent("Sources/MakiDesk", isDirectory: true)
    }

    /// `forKey: "…"` and `@AppStorage("…")` are the two ways a key used to be
    /// written by hand.
    private static let literalKey = try! NSRegularExpression(
        pattern: #"(?:forKey: |@AppStorage\()"([A-Za-z]+)""#
    )

    private func firstLiteralKey(in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = Self.literalKey.firstMatch(in: text, range: range),
              let found = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[found])
    }

    func testNoKeyIsSpelledOutsideTheRegistry() throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: sourcesRoot, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "SettingsKey.swift" }
        XCTAssertGreaterThan(files.count, 50, "the sources should be found")

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            if let key = firstLiteralKey(in: text) {
                XCTFail("\(file.lastPathComponent) writes the key “\(key)” by hand: use SettingsKey")
            }
        }
    }

    func testTheRegistryIsUniqueAndNonEmpty() {
        let raw = SettingsKey.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raw).count, raw.count, "two keys with one name")
        XCTAssertFalse(raw.contains(where: \.isEmpty))
        for key in SettingsKey.allCases {
            XCTAssertEqual(key.rawValue.first?.isLetter, true, key.rawValue)
        }
    }

    /// The constants the UI reads (`HUDSettings.positionKey`, …) must point at
    /// the registry, not carry a copy of the string.
    func testTheNamedConstantsComeFromTheRegistry() {
        XCTAssertEqual(HUDSettings.positionKey, SettingsKey.hudPosition.rawValue)
        XCTAssertEqual(HUDSettings.screenKey, SettingsKey.hudScreenLocation.rawValue)
        XCTAssertEqual(SettingsView.SettingsTab.defaultsKey, SettingsKey.settingsTab.rawValue)
        XCTAssertEqual(MeasurementSettings.unitKey, SettingsKey.measureUnit.rawValue)
        XCTAssertEqual(ColorSamplerController.formatDefaultsKey,
                       SettingsKey.colorPickerFormat.rawValue)
        XCTAssertEqual(ApplicationUsageStore.defaultsKey, SettingsKey.applicationLauncherUsage.rawValue)
    }

    /// The one key that is not ours: macOS writes it, the app only reads it.
    func testTheSystemTilingKeyIsReadOnlyInTheSources() throws {
        let name = SettingsKey.enableTilingOptionAccelerator.rawValue
        let files = try FileManager.default
            .contentsOfDirectory(at: sourcesRoot, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("SettingsKey.enableTilingOptionAccelerator") else { continue }
            XCTAssertFalse(text.contains("forKey: SettingsKey.enableTilingOptionAccelerator.rawValue)"),
                           "\(file.lastPathComponent) must not write the system tiling preference")
        }
    }
}
