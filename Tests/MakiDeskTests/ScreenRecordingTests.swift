import XCTest
@testable import MakiDesk

/// T40: the recording writes a movie; these check the pieces that can run
/// without a display — the clock the menu shows and a session that captured
/// nothing.
final class ScreenRecordingTests: XCTestCase {
    func testTheRecordingClockReadsLikeATimer() {
        XCTAssertEqual(RecordingClock.text(0), "0:00")
        XCTAssertEqual(RecordingClock.text(9.9), "0:09")
        XCTAssertEqual(RecordingClock.text(65), "1:05")
        XCTAssertEqual(RecordingClock.text(600), "10:00")
        XCTAssertEqual(RecordingClock.text(3661), "1:01:01")
        XCTAssertEqual(RecordingClock.text(-4), "0:00")
    }

    func testASessionWithNoFramesSavesNothing() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDesk-test-\(UUID().uuidString).mov")
        let session = try ScreenRecordingSession(url: url, width: 640, height: 360, audio: false)
        let result = await session.stop()
        XCTAssertNil(result.url)
        XCTAssertEqual(result.message, ScreenRecordingError.noFrames.localizedDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: url)
    }

    func testTheAudioTrackIsLeftOutWhenTheWriterTakesIt() throws {
        // The input is optional; with `audio: false` there is no track at all.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDesk-test-\(UUID().uuidString).mov")
        let session = try ScreenRecordingSession(url: url, width: 320, height: 200, audio: false)
        XCTAssertFalse(session.includesAudio)
        try? FileManager.default.removeItem(at: url)
    }
}
