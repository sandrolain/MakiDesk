import AppKit
import XCTest
@testable import MakiDesk

/// The gutter must never ask TextKit for glyphs outside the laid-out text: that
/// is what threw inside `NSLayoutManager` and crashed the app on 29 October.
final class NotesRulerTests: XCTestCase {
    private let used = CGRect(x: 0, y: 0, width: 500, height: 900)
    private let origin = CGPoint(x: 10, y: 10)

    private func query(_ visible: CGRect) -> CGRect? {
        LineNumberRulerView.glyphQueryRect(visible: visible, containerOrigin: origin, used: used)
    }

    func testAVisibleRectInsideTheTextIsTranslatedToTheContainer() throws {
        let rect = try XCTUnwrap(query(CGRect(x: 10, y: 100, width: 500, height: 200)))
        XCTAssertEqual(rect.minX, 0, accuracy: 0.01)
        XCTAssertEqual(rect.minY, 90, accuracy: 0.01)
        XCTAssertEqual(rect.height, 200, accuracy: 0.01)
    }

    func testTheWholeDocumentIsClampedToTheLaidOutText() throws {
        // A live resize makes the clip view report the entire document.
        let rect = try XCTUnwrap(query(CGRect(x: 0, y: 0, width: 900, height: 40_000)))
        XCTAssertLessThanOrEqual(rect.maxY, used.maxY + 1.01)
        XCTAssertGreaterThanOrEqual(rect.minY, used.minY - 1.01)
    }

    func testARectBeyondTheTextAsksForNothing() {
        // Scrolled past the end: no numbers, and no layout query.
        XCTAssertNil(query(CGRect(x: 10, y: 5_000, width: 500, height: 400)))
        XCTAssertNil(query(CGRect(x: 10, y: -5_000, width: 500, height: 400)))
    }

    func testAnUnlaidOutTextAsksForNothing() {
        XCTAssertNil(LineNumberRulerView.glyphQueryRect(visible: CGRect(x: 0, y: 0, width: 500, height: 500),
                                                        containerOrigin: .zero,
                                                        used: CGRect(x: 0, y: 0, width: 0, height: 900)))
        XCTAssertNil(LineNumberRulerView.glyphQueryRect(visible: CGRect(x: 0, y: 0, width: 500, height: 500),
                                                        containerOrigin: .zero,
                                                        used: .zero))
    }

    func testAnEmptyVisibleRectAsksForNothing() {
        XCTAssertNil(query(CGRect(x: 10, y: 100, width: 0, height: 200)))
        XCTAssertNil(query(CGRect(x: 10, y: 100, width: 500, height: 0)))
    }
}
