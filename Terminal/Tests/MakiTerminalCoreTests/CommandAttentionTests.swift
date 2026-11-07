import XCTest
@testable import MakiTerminalCore

final class CommandAttentionTests: XCTestCase {
    func testASuccessfulQuickCommandStaysQuiet() {
        XCTAssertFalse(CommandAttention.deservesAttention(exitCode: 0,
                                                          durationNanos: 100_000_000))
    }

    func testAFailedCommandMarksTheWorkspace() {
        XCTAssertTrue(CommandAttention.deservesAttention(exitCode: 1, durationNanos: 10))
    }

    func testALongCommandMarksTheWorkspace() {
        XCTAssertTrue(CommandAttention.deservesAttention(
            exitCode: 0, durationNanos: CommandAttention.longCommandNanos))
    }
}
