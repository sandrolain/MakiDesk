import XCTest
@testable import MakiDesk

/// R11: the block a bug report carries. It has to say enough to be useful and
/// nothing the app promises never to write down.
final class DiagnosticsReportTests: XCTestCase {
    private var report: DiagnosticsReport {
        DiagnosticsReport(
            appVersion: "1.2 (34)",
            macOS: "14.2.1",
            accessibility: true,
            screenRecording: false,
            shortcutsRegistered: 62,
            shortcutsBlocked: 1,
            shortcutsModified: 2,
            shortcutFile: "loaded, 3 row(s) resolved",
            windows: 12,
            groups: 4
        )
    }

    func testTheReportSaysTheEssentials() {
        let text = report.text
        XCTAssertTrue(text.contains("MakiDesk 1.2 (34)"))
        XCTAssertTrue(text.contains("macOS 14.2.1"))
        XCTAssertTrue(text.contains("Accessibility: on"))
        XCTAssertTrue(text.contains("Screen Recording: off"))
        XCTAssertTrue(text.contains("62 active, 1 taken, 2 customised"))
        XCTAssertTrue(text.contains("shortcuts.json: loaded, 3 row(s) resolved"))
        XCTAssertTrue(text.contains("Windows known: 12 · groups: 4"))
        XCTAssertTrue(text.contains("Capture budget: 96 MiB"))
    }

    /// A path is the one thing a diagnostics blob must never grow: the report
    /// says "loaded", not where the file is.
    func testTheReportCarriesNoPath() {
        XCTAssertFalse(report.text.contains("/"))
    }

    func testTheReportIsStableLineByLine() {
        XCTAssertEqual(report.text.split(separator: "\n").count, 8)
    }
}
