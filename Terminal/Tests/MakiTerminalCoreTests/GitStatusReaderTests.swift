import Foundation
import XCTest
@testable import MakiTerminalCore

final class GitStatusReaderTests: XCTestCase {
    func testDistinguishesNonRepositoryFromCommandFailure() throws {
        let fixture = try makeFixture(script: "#!/bin/sh\nexit 1\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        XCTAssertEqual(
            GitStatusReader.read(directory: fixture.directory.path,
                                 gitExecutable: fixture.executable,
                                 commandTimeout: 1,
                                 maximumOutputBytes: 1024),
            .notRepository
        )

        try FileManager.default.createDirectory(
            at: fixture.directory.appendingPathComponent(".git"),
            withIntermediateDirectories: false
        )
        XCTAssertEqual(
            GitStatusReader.read(directory: fixture.directory.path,
                                 gitExecutable: fixture.executable,
                                 commandTimeout: 1,
                                 maximumOutputBytes: 1024),
            .failure(.commandFailed)
        )
    }

    func testReadsStatusAndEnforcesOutputLimit() throws {
        let fixture = try makeFixture(script: """
        #!/bin/sh
        if [ "$3" = "rev-parse" ]; then
            printf '%s\\n' "$2"
        elif [ "$3" = "status" ]; then
            printf '?? '
            i=0
            while [ "$i" -lt 2048 ]; do
                printf x
                i=$((i + 1))
            done
            printf '\\000'
        fi
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        XCTAssertEqual(
            GitStatusReader.read(directory: fixture.directory.path,
                                 gitExecutable: fixture.executable,
                                 commandTimeout: 1,
                                 maximumOutputBytes: 4096),
            .success(root: fixture.directory.path,
                                          files: [GitChangedFile(path: String(repeating: "x", count: 2048), status: "??")])
        )
        let outputLimit = fixture.directory.path.utf8.count + 16
        XCTAssertEqual(
            GitStatusReader.read(directory: fixture.directory.path,
                                 gitExecutable: fixture.executable,
                                 commandTimeout: 1,
                                 maximumOutputBytes: outputLimit),
            .failure(.outputTooLarge)
        )
    }

    private func makeFixture(script: String) throws -> (directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitStatusReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-git")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: executable.path)
        return (directory, executable)
    }
}
