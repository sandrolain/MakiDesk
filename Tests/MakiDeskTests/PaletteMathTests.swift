import XCTest
@testable import MakiDesk

final class PaletteMathTests: XCTestCase {
    private let us = Locale(identifier: "en_US_POSIX")
    private let italian = Locale(identifier: "it_IT")

    private func value(_ expression: String, locale: Locale? = nil) -> Double? {
        PaletteMath.evaluate(expression, locale: locale ?? us)?.value
    }

    private func text(_ expression: String, locale: Locale? = nil) -> String? {
        PaletteMath.evaluate(expression, locale: locale ?? us)?.text
    }

    // MARK: - Arithmetic

    func testPrecedenceAndParentheses() {
        XCTAssertEqual(value("2 + 3 * 4"), 14)
        XCTAssertEqual(value("(2 + 3) * 4"), 20)
        XCTAssertEqual(value("10 - 4 - 3"), 3)
        XCTAssertEqual(value("20 / 4 / 5"), 1)
    }

    func testPowerIsRightAssociative() {
        XCTAssertEqual(value("2 ^ 3 ^ 2"), 512)
        XCTAssertEqual(value("2 ^ 10"), 1024)
    }

    func testUnaryMinusBindsLooserThanPower() {
        XCTAssertEqual(value("-3 + 5"), 2)
        XCTAssertEqual(value("-2 ^ 2"), -4)
        XCTAssertEqual(value("2 ^ -3"), 0.125)
    }

    func testModuloUsesAWordSoPercentStaysAPercentage() {
        XCTAssertEqual(value("10 mod 3"), 1)
        XCTAssertEqual(value("15 %"), 0.15)
    }

    func testDivisionByZeroIsRejected() {
        XCTAssertNil(value("1 / 0"))
        XCTAssertNil(value("0 / 0"))
    }

    func testFunctions() {
        XCTAssertEqual(value("sqrt(9)"), 3)
        XCTAssertEqual(value("abs(-3)"), 3)
        XCTAssertEqual(value("round(2.6)"), 3)
        XCTAssertEqual(value("floor(2.9)"), 2)
        XCTAssertEqual(value("ceil(2.1)"), 3)
        XCTAssertEqual(value("SQRT(16)"), 4)
    }

    func testConstants() {
        XCTAssertEqual(value("pi") ?? 0, Double.pi, accuracy: 1e-9)
        XCTAssertEqual(value("e") ?? 0, exp(1), accuracy: 1e-9)
    }

    // MARK: - Percentages

    func testPercentageOf() {
        XCTAssertEqual(value("15% of 80"), 12)
        XCTAssertEqual(value("15% of (80 + 10)"), 13.5)
    }

    func testPercentageInAdditionAppliesToTheLeftSide() {
        XCTAssertEqual(value("80 + 15%"), 92)
        XCTAssertEqual(value("80 - 15%"), 68)
        XCTAssertEqual(value("50% * 80"), 40)
    }

    func testBarePercentIsAFraction() {
        XCTAssertEqual(value("15%"), 0.15)
        XCTAssertEqual(text("15%"), "0.15")
    }

    func testOfRequiresAPercentage() {
        XCTAssertNil(value("2 of 3"))
    }

    // MARK: - Units

    func testLengthConversion() {
        let calculation = PaletteMath.evaluate("12 cm in in", locale: us)
        XCTAssertEqual(calculation?.value ?? 0, 4.724409448818897, accuracy: 1e-9)
        XCTAssertEqual(calculation?.unit, "in")
    }

    func testAddingDifferentUnitsOfTheSameDimension() {
        let calculation = PaletteMath.evaluate("1 m + 50 cm", locale: us)
        XCTAssertEqual(calculation?.value ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertEqual(calculation?.unit, "m")
    }

    func testTemperatureConversion() {
        XCTAssertEqual(value("30 °C in °F") ?? 0, 86, accuracy: 1e-9)
        XCTAssertEqual(value("212 °F in °C") ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(value("0 °C in K") ?? 0, 273.15, accuracy: 1e-9)
    }

    func testDataDecimalAndBinary() {
        XCTAssertEqual(value("2 GB in MB"), 2000)
        XCTAssertEqual(value("1 GiB in MiB"), 1024)
        XCTAssertEqual(value("1 KB in B"), 1000)
    }

    func testTimeConversion() {
        XCTAssertEqual(value("90 min in h"), 1.5)
        XCTAssertEqual(value("2 d in h"), 48)
    }

    func testIncompatibleUnitsAreRejected() {
        XCTAssertNil(value("12 cm in kg"))
        XCTAssertNil(value("1 m + 1 s"))
        XCTAssertNil(value("1 m + 2"))
    }

    func testMultiplicationKeepsOneUnit() {
        let calculation = PaletteMath.evaluate("3 * 2 cm", locale: us)
        XCTAssertEqual(calculation?.value, 6)
        XCTAssertEqual(calculation?.unit, "cm")
    }

    func testSameUnitDivisionIsUnitless() {
        XCTAssertEqual(value("10 m / 2 m"), 5)
    }

    // MARK: - Locale

    func testItalianSeparators() {
        XCTAssertEqual(value("1.234,5", locale: italian), 1234.5)
        XCTAssertEqual(value("1.000", locale: italian), 1000)
        XCTAssertEqual(value("1,5", locale: italian), 1.5)
    }

    func testEnglishSeparators() {
        XCTAssertEqual(value("1,234.5"), 1234.5)
        XCTAssertEqual(value("1,000"), 1000)
        // A single separator with one or two digits after is a decimal even
        // when the locale would call it grouping.
        XCTAssertEqual(value("1,5"), 1.5)
    }

    func testGroupingIsOnlyAcceptedInThrees() {
        XCTAssertNil(value("1,23,456"))
        XCTAssertNil(value("1,2345"))
        // A single separator with two digits after is a decimal, not grouping.
        XCTAssertEqual(value("12,34"), 12.34)
    }

    // MARK: - Rejections

    func testPlainTextIsNotAnExpression() {
        XCTAssertNil(value("Safari"))
        XCTAssertNil(value("note"))
        XCTAssertNil(value("⌥"))
        XCTAssertNil(value(""))
        XCTAssertNil(value("   "))
    }

    func testIncompleteExpressionsAreRejected() {
        XCTAssertNil(value("12 *"))
        XCTAssertNil(value("(1 + 2"))
        XCTAssertNil(value("1 + 2)"))
        XCTAssertNil(value("()"))
        XCTAssertNil(value("%"))
    }

    func testTooDeepAndTooLongInputsAreRejected() {
        let deep = String(repeating: "(", count: 17) + "1" + String(repeating: ")", count: 17)
        XCTAssertNil(value(deep))
        let long = String(repeating: "1+", count: 101) + "1"
        XCTAssertNil(value(long))
    }

    func testHugeExponentIsRejected() {
        XCTAssertNil(value("2 ^ 100"))
        XCTAssertNil(value("2 ^ 13"))
        XCTAssertEqual(value("2 ^ 12"), 4096)
    }

    // MARK: - Formatting

    func testPlainNumbersAreFormattedWithoutTrailingZeros() {
        XCTAssertEqual(text("12 * 3"), "36")
        XCTAssertEqual(text("10 / 4"), "2.5")
        XCTAssertEqual(text("1 / 3"), "0.3333333333")
    }

    func testUnitsAppearAfterASpace() {
        XCTAssertEqual(text("2 GB"), "2 GB")
        XCTAssertEqual(text("30 °C in °F"), "86 °F")
    }

    func testScientificNotationForExtremeValues() {
        XCTAssertEqual(text("10 ^ 12"), "1e+12")
    }
}
