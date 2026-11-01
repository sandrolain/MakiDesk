import AppKit
import XCTest
@testable import MakiDesk

/// R03: a panel says what kind of panel it is, instead of repeating the same
/// overrides. The one exception is named, so it cannot grow silently.
@MainActor
final class FloatingPanelTests: XCTestCase {
    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MakiDesk", isDirectory: true)
    }

    func testEveryPanelUsesTheSharedBase() throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: sourcesRoot, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let pattern = try NSRegularExpression(pattern: #"class (\w+): NSPanel"#)

        var plain: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let name = Range(match.range(at: 1), in: text) else { continue }
                plain.append(String(text[name]))
            }
        }
        // NotesPanel keeps `canBecomeMain` true and carries key equivalents:
        // it is the documented exception, not an oversight.
        XCTAssertEqual(plain, ["FloatingPanel", "NotesPanel"])
    }

    func testTheStylesSayWhatTheyMean() {
        XCTAssertTrue(FloatingPanel.Style.utility.becomesKey)
        XCTAssertTrue(FloatingPanel.Style.utility.confinesToScreen)

        XCTAssertTrue(FloatingPanel.Style.keyOverlay.becomesKey)
        XCTAssertFalse(FloatingPanel.Style.keyOverlay.confinesToScreen)

        XCTAssertFalse(FloatingPanel.Style.passive.becomesKey)
        XCTAssertFalse(FloatingPanel.Style.passive.confinesToScreen)

        XCTAssertFalse(FloatingPanel.Style.readOnly.becomesKey)
        XCTAssertTrue(FloatingPanel.Style.readOnly.confinesToScreen)
    }

    /// The base answers the three questions from the style, so a subclass that
    /// forgets one cannot fall back to a different behaviour by accident.
    func testAPanelTakesItsAnswersFromTheStyle() {
        let panel = FloatingPanel(contentRect: .zero, styleMask: [.borderless],
                                  backing: .buffered, defer: true)
        XCTAssertTrue(panel.canBecomeKey, "the default style is a utility card")
        XCTAssertFalse(panel.canBecomeMain)
    }
}
