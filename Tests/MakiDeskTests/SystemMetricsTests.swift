import XCTest
@testable import MakiDesk

/// The numbers behind the menu-bar figure: decimal units like the Finder, a
/// clear split between purgeable and strictly free space, and a busy share
/// that comes from ticks rather than from a decayed percentage.
final class SystemMetricsTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let italian = Locale(identifier: "it_IT")

    func testSizesAreDecimalLikeTheFinder() {
        XCTAssertEqual(DiskSpaceText.size(494_384_795_648, locale: english), "494 GB")
        XCTAssertEqual(DiskSpaceText.size(21_954_277_376, locale: english), "22.0 GB")
        XCTAssertEqual(DiskSpaceText.size(1_500_000_000, locale: english), "1.5 GB")
        XCTAssertEqual(DiskSpaceText.size(900_000_000, locale: english), "900 MB")
        XCTAssertEqual(DiskSpaceText.size(2_400_000_000_000, locale: english), "2.4 TB")
    }

    func testSizesFollowTheLocale() {
        XCTAssertEqual(DiskSpaceText.size(21_954_277_376, locale: italian), "22,0 GB")
        XCTAssertEqual(DiskSpaceText.percent(0.0444, locale: italian), "4,4%")
    }

    func testTheShareUsesOneDecimal() {
        XCTAssertEqual(DiskSpaceText.percent(0.04407, locale: english), "4.4%")
        XCTAssertEqual(DiskSpaceText.percent(1, locale: english), "100%")
        XCTAssertEqual(DiskSpaceText.percent(0, locale: english), "0.0%")
    }

    func testTheSummaryNamesTheVolumeAndBothFigures() {
        let space = DiskSpace(volumeName: "Macintosh HD",
                              totalBytes: 494_384_795_648,
                              availableBytes: 21_954_277_376,
                              availableForImportantUsageBytes: 27_297_310_736)
        XCTAssertEqual(DiskSpaceText.summary(space, locale: english),
                       "Macintosh HD · 27.3 GB free of 494 GB (5.5%)")
        XCTAssertEqual(DiskSpaceText.menuBar(space, format: .size, locale: english), "27.3 GB")
        XCTAssertEqual(DiskSpaceText.menuBar(space, format: .percent, locale: english), "5.5%")
        XCTAssertNotNil(DiskSpaceText.detail(space, locale: english))
    }

    /// Two nearly identical figures are noise; the strict one is shown only
    /// when the purgeable allowance is worth naming.
    func testThePurgeableSplitIsOnlyShownWhenItMatters() {
        let small = DiskSpace(volumeName: "Disk", totalBytes: 100_000_000_000,
                              availableBytes: 50_000_000_000,
                              availableForImportantUsageBytes: 50_200_000_000)
        XCTAssertFalse(small.hasPurgeableSpace)
        XCTAssertNil(DiskSpaceText.detail(small, locale: english))

        let strictOnly = DiskSpace(volumeName: "Disk", totalBytes: 100_000_000_000,
                                   availableBytes: 50_000_000_000,
                                   availableForImportantUsageBytes: nil)
        XCTAssertEqual(strictOnly.displayedAvailableBytes, 50_000_000_000)
        XCTAssertNil(DiskSpaceText.detail(strictOnly, locale: english))
    }

    func testNoCapacityDoesNotDivideByZero() {
        let empty = DiskSpace(volumeName: "Disk", totalBytes: 0, availableBytes: -1,
                              availableForImportantUsageBytes: nil)
        XCTAssertEqual(empty.freeFraction, 0)
        XCTAssertEqual(empty.displayedAvailableBytes, 0)
    }

    func testBusyShareComesFromTickDeltas() {
        let before = CPUTicks(user: 100, system: 100, idle: 800, nice: 0)
        let after = CPUTicks(user: 150, system: 150, idle: 900, nice: 0)
        // 100 busy out of 200 total.
        XCTAssertEqual(after.busyPercent(since: before), 50)
        XCTAssertNil(before.busyPercent(since: after))
        XCTAssertNil(after.busyPercent(since: after))
    }

    func testTheProcessShareIsPercentOfOneCore() {
        let reading = ProcessReading(identity: ProcessIdentity(pid: 1, startSeconds: 2),
                                     name: "Build", cpuPercent: 312.4)
        XCTAssertEqual(reading.percentText, "312%")
        XCTAssertEqual(CPUFormat.cores(312.4), "3.1 cores")
        XCTAssertEqual(CPUFormat.cores(100), "1.0 core")
        XCTAssertEqual(CPUFormat.minutes(0), "under a minute")
        XCTAssertEqual(CPUFormat.minutes(600), "10 min")
    }
}
