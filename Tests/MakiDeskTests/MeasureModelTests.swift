import CoreGraphics
import XCTest
@testable import MakiDesk

/// T39: the pure side of the measure command — units, readout and badge
/// placement — plus the drag modifier rules.
final class MeasureModelTests: XCTestCase {
    private let display = MeasureDisplay(id: 1, scale: 2, dpi: 144, hasPhysicalSize: true)
    private let unknownDisplay = MeasureDisplay(id: 2, scale: 1, dpi: 72, hasPhysicalSize: false)

    private func measurement(width: CGFloat = 100, height: CGFloat = 50,
                             snapped: ScreenRegionSelector.SnapInfo = .none,
                             display: MeasureDisplay? = nil) -> ScreenMeasurement {
        ScreenMeasurement(rect: CGRect(x: 10, y: 200, width: width, height: height),
                          display: display ?? self.display,
                          snapped: snapped)
    }

    // MARK: - Units

    func testUnitConversions() {
        XCTAssertEqual(display.value(fromPoints: 100, unit: .points), 100)
        XCTAssertEqual(display.value(fromPoints: 100, unit: .pixels), 200)
        XCTAssertEqual(display.value(fromPoints: 100, unit: .millimeters),
                       100 / 144 * 25.4, accuracy: 0.0001)
        XCTAssertEqual(display.value(fromPoints: 144, unit: .inches), 1, accuracy: 0.0001)
    }

    func testUnknownPhysicalSizeFallsBackToSeventyTwoDpi() {
        XCTAssertEqual(unknownDisplay.value(fromPoints: 72, unit: .inches), 1, accuracy: 0.0001)
        XCTAssertFalse(unknownDisplay.hasPhysicalSize)
    }

    func testReadoutLinesAndBadgeValues() {
        let measurement = measurement()
        let lines = measurement.lines(.points)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "100 × 50 pt")
        XCTAssertEqual(lines[1], "ΔX 100 · ΔY 50")
        XCTAssertTrue(lines[2].hasPrefix("⤢ 112 pt · 26.6° · 5000 pt²"))
    }

    func testSnappedAxesAreMarked() {
        let lines = measurement(snapped: .init(axisX: true, axisY: false)).lines(.points)
        XCTAssertTrue(lines[0].hasSuffix("· snapped X"))
        XCTAssertEqual(lines[1], "ΔX 100 ⇥ · ΔY 50")
    }

    func testPixelReadoutUsesTheBackingScale() {
        let lines = measurement().lines(.pixels)
        XCTAssertEqual(lines[0], "200 × 100 px")
        XCTAssertEqual(lines[1], "ΔX 200 · ΔY 100")
    }

    func testEstimatedUnitsKeepDecimals() {
        XCTAssertEqual(measurement().lines(.millimeters)[0], "17.6 × 8.8 mm")
        XCTAssertEqual(measurement().lines(.inches)[0], "0.694 × 0.347 in")
    }

    func testCopyTextKeepsTheChosenUnitFirstAndPixelsSecond() {
        let lines = measurement().copyText(.points).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "100 × 50 pt · ΔX 100 · ΔY 50")
        XCTAssertTrue(lines[1].hasPrefix("200 × 100 px · diagonal 112 pt (26.6°) · area 5000 pt²"))

        let pixels = measurement().copyText(.pixels).split(separator: "\n")
        XCTAssertTrue(pixels[0].hasPrefix("200 × 100 px"))
        XCTAssertTrue(pixels[1].hasPrefix("100 × 50 pt"))
    }

    func testZeroWidthDiagonalIsVertical() {
        XCTAssertEqual(measurement(width: 0, height: 50).angle, 90)
    }

    // MARK: - Layout

    func testBadgeSitsBelowTheMeasurementWhenThereIsRoom() {
        let measurement = self.measurement()
        let frame = MeasureLayout.badgeFrame(measurement: measurement,
                                             size: CGSize(width: 220, height: 60),
                                             visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        XCTAssertEqual(frame.minY, 200 - 60 - 10)
        XCTAssertEqual(frame.minX, 10)
    }

    func testBadgeMovesAboveWhenTheMeasurementIsAtTheBottom() {
        let low = ScreenMeasurement(rect: CGRect(x: 900, y: 2, width: 80, height: 40),
                                    display: display, snapped: .none)
        let frame = MeasureLayout.badgeFrame(measurement: low,
                                             size: CGSize(width: 220, height: 60),
                                             visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        XCTAssertEqual(frame.minY, 2 + 40 + 10)
        XCTAssertEqual(frame.maxX, 1000 - 8)
    }

    // MARK: - Drag modifiers

    func testPlainDragIsANormalisedRectangle() {
        let rect = ScreenRegionGeometry.measureRect(from: CGPoint(x: 100, y: 100),
                                                    to: CGPoint(x: 40, y: 20))
        XCTAssertEqual(rect, CGRect(x: 40, y: 20, width: 60, height: 80))
    }

    func testShiftKeepsASquareUsingTheLargerSide() {
        let rect = ScreenRegionGeometry.measureRect(from: CGPoint(x: 100, y: 100),
                                                    to: CGPoint(x: 40, y: 70),
                                                    square: true)
        XCTAssertEqual(rect.width, 60)
        XCTAssertEqual(rect.height, 60)
        XCTAssertEqual(rect, CGRect(x: 40, y: 40, width: 60, height: 60))
    }

    func testOptionGrowsFromTheCentre() {
        let rect = ScreenRegionGeometry.measureRect(from: CGPoint(x: 100, y: 100),
                                                    to: CGPoint(x: 130, y: 80),
                                                    centered: true)
        XCTAssertEqual(rect, CGRect(x: 70, y: 80, width: 60, height: 40))
    }

    func testCentreAndSquareCombine() {
        let rect = ScreenRegionGeometry.measureRect(from: CGPoint(x: 100, y: 100),
                                                    to: CGPoint(x: 130, y: 80),
                                                    centered: true, square: true)
        XCTAssertEqual(rect, CGRect(x: 70, y: 70, width: 60, height: 60))
    }

    // MARK: - Persisted unit

    func testUnknownStoredUnitFallsBackToPoints() {
        let suite = "MakiDeskMeasureUnit-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(MeasurementSettings.unit(defaults: defaults), .points)
        defaults.set("furlongs", forKey: MeasurementSettings.unitKey)
        XCTAssertEqual(MeasurementSettings.unit(defaults: defaults), .points)
        defaults.set("pixels", forKey: MeasurementSettings.unitKey)
        XCTAssertEqual(MeasurementSettings.unit(defaults: defaults), .pixels)
    }
}
