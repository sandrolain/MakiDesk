import XCTest
@testable import MakiTerminalCore

final class TerminalCLITests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiCLI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testTheStableLinkPointsAtTheBundledCLI() throws {
        let bundled = directory.appendingPathComponent("makidesk")
        try "#!/bin/sh\n".write(to: bundled, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: bundled.path)
        let stable = directory.appendingPathComponent("bin/makidesk")

        let result = TerminalCLI.install(bundledURL: bundled, stableURL: stable)
        XCTAssertEqual(result?.path, stable.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: stable.path),
                       bundled.path)
    }

    func testAMissingBundledCLIYieldsNothing() {
        let stable = directory.appendingPathComponent("bin/makidesk")
        let result = TerminalCLI.install(bundledURL: directory.appendingPathComponent("missing"),
                                         stableURL: stable)
        XCTAssertNil(result)
    }
}
