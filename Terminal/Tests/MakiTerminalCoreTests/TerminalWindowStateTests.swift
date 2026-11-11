import CoreGraphics
import XCTest
@testable import MakiTerminalCore

final class TerminalWindowStateTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiTerminalWindow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private let mainScreen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testAFrameOnAScreenIsKept() {
        let frame = CGRect(x: 100, y: 120, width: 900, height: 600)
        XCTAssertEqual(TerminalWindowGeometry.restoredFrame(frame, screens: [mainScreen]), frame)
    }

    func testAFrameOnANegativeOriginDisplayIsKept() {
        let second = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let frame = CGRect(x: -1500, y: 100, width: 800, height: 600)
        XCTAssertEqual(TerminalWindowGeometry.restoredFrame(frame, screens: [mainScreen, second]),
                       frame)
    }

    func testAFrameOnAnUnpluggedDisplayIsDropped() {
        let frame = CGRect(x: 4000, y: 400, width: 900, height: 600)
        XCTAssertNil(TerminalWindowGeometry.restoredFrame(frame, screens: [mainScreen]))
    }

    func testASliverIsNotEnoughToGrabTheWindow() {
        let frame = CGRect(x: 1430, y: 400, width: 900, height: 600)
        XCTAssertNil(TerminalWindowGeometry.restoredFrame(frame, screens: [mainScreen]))
    }

    func testATooSmallFrameGrowsToTheMinimum() {
        let frame = CGRect(x: 20, y: 20, width: 100, height: 100)
        let restored = TerminalWindowGeometry.restoredFrame(frame, screens: [mainScreen])
        XCTAssertEqual(restored?.size, TerminalWindowGeometry.minimumSize)
        XCTAssertEqual(restored?.origin, frame.origin)
    }

    func testANonFiniteFrameIsDropped() {
        XCTAssertNil(TerminalWindowGeometry.restoredFrame(
            CGRect(x: CGFloat.nan, y: 0, width: 900, height: 600), screens: [mainScreen]))
        XCTAssertNil(TerminalWindowGeometry.restoredFrame(
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 600), screens: [mainScreen]))
    }

    func testTheStateRoundTrips() {
        let store = TerminalWindowStateStore(fileURL: directory.appendingPathComponent("window.json"))
        let frame = CGRect(x: -100, y: 40, width: 1024, height: 700)
        XCTAssertTrue(store.save(TerminalWindowState(frame: frame)))
        XCTAssertEqual(store.load()?.frame, frame)
        XCTAssertEqual(store.load()?.version, TerminalWindowState.currentVersion)
    }

    func testAMissingFileHasNoFrame() {
        let store = TerminalWindowStateStore(fileURL: directory.appendingPathComponent("window.json"))
        XCTAssertNil(store.load())
    }

    func testACorruptFileIsSetAsideAndIgnored() throws {
        let url = directory.appendingPathComponent("window.json")
        try Data("not json".utf8).write(to: url)
        let store = TerminalWindowStateStore(fileURL: url)
        XCTAssertNil(store.load())
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathExtension("bak").path))
    }

    func testAFutureVersionIsNotUsed() throws {
        let url = directory.appendingPathComponent("window.json")
        let json = #"{"version":99,"x":0,"y":0,"width":900,"height":600}"#
        try Data(json.utf8).write(to: url)
        let store = TerminalWindowStateStore(fileURL: url)
        XCTAssertNil(store.load())
        XCTAssertEqual(store.futureVersionOnDisk, 99)
        XCTAssertFalse(store.save(TerminalWindowState(frame: CGRect(x: 1, y: 2,
                                                                    width: 700, height: 500))))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), json)
    }
}
