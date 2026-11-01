import XCTest
@testable import MakiDesk

/// R06: one total, two shares. The numbers are a policy, not an accident, so
/// they are written down where a change is visible.
final class CaptureBudgetTests: XCTestCase {
    func testTheSharesAddUpToTheTotal() {
        XCTAssertEqual(CaptureBudget.cacheBytes + CaptureBudget.paletteBytes,
                       CaptureBudget.totalBytes)
    }

    /// The palette shows what the capture cache produced: giving it more room
    /// than its source would only hold stale copies.
    func testThePaletteHoldsLessThanTheCache() {
        XCTAssertLessThan(CaptureBudget.paletteBytes, CaptureBudget.cacheBytes)
    }

    func testTheSharesAreWholeMebibytes() {
        let mebibyte = 1024 * 1024
        XCTAssertEqual(CaptureBudget.totalBytes % mebibyte, 0)
        XCTAssertEqual(CaptureBudget.cacheBytes % mebibyte, 0)
        XCTAssertEqual(CaptureBudget.paletteBytes % mebibyte, 0)
    }
}
