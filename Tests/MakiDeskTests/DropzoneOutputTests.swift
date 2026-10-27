import XCTest
@testable import MakiDesk

/// T47: what a finished run hands to the clipboard or the Shelf.
final class DropzoneOutputTests: XCTestCase {
    private var workDirectory: URL!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDeskOutput-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workDirectory.appendingPathComponent("output", isDirectory: true),
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
    }

    private func result(succeeded: Bool = true, stdout: String? = nil) -> CommandResult {
        CommandResult(exitCode: succeeded ? 0 : 1, termSignal: nil, timedOut: false,
                      cancelled: false, duration: 0.1, workDirectory: workDirectory,
                      stdoutFile: workDirectory.appendingPathComponent("stdout.log"),
                      stderrFile: workDirectory.appendingPathComponent("stderr.log"),
                      stdoutExcerpt: stdout, stderrExcerpt: "")
    }

    private func write(_ name: String) throws -> URL {
        let url = workDirectory.appendingPathComponent("output", isDirectory: true)
            .appendingPathComponent(name)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testFilesUnderOutputAreDeliveredInNameOrder() throws {
        _ = try write("b.txt")
        _ = try write("a.txt")
        let payload = try XCTUnwrap(DropzoneOutput.payload(result: result(), expectedOutput: nil))
        XCTAssertEqual(payload.fileURLs.map(\.lastPathComponent), ["a.txt", "b.txt"])
        XCTAssertNil(payload.text)
    }

    func testDeclaredOutputWinsOverTheOutputFolder() throws {
        _ = try write("ignored.txt")
        let declared = workDirectory.appendingPathComponent("archive.zip")
        try "zip".write(to: declared, atomically: true, encoding: .utf8)
        let payload = try XCTUnwrap(DropzoneOutput.payload(result: result(),
                                                           expectedOutput: declared.path))
        XCTAssertEqual(payload.fileURLs.map(\.lastPathComponent), ["archive.zip"])
    }

    func testStdoutIsTheFallbackWhenNoFileWasWritten() throws {
        let payload = try XCTUnwrap(DropzoneOutput.payload(result: result(stdout: "hello\n"),
                                                           expectedOutput: nil))
        XCTAssertTrue(payload.fileURLs.isEmpty)
        XCTAssertEqual(payload.text, "hello\n")
    }

    func testFailedRunAndEmptyOutputDeliverNothing() throws {
        XCTAssertNil(DropzoneOutput.payload(result: result(succeeded: false), expectedOutput: nil))
        XCTAssertNil(DropzoneOutput.payload(result: result(stdout: "  \n"), expectedOutput: nil))
    }
}
