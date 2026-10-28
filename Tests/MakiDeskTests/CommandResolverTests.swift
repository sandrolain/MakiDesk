import XCTest
@testable import MakiDesk

/// T38/T44: from the user's command line to a runnable command. These tests use
/// a temporary directory and never spawn anything.
final class CommandResolverTests: XCTestCase {
    private var workdir: URL!
    private let resolver = CommandResolver(baseEnvironment: ["HOME": "/Users/test", "LANG": "en_US.UTF-8"])

    override func setUpWithError() throws {
        workdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDeskCommandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workdir { try? FileManager.default.removeItem(at: workdir) }
    }

    private func payload(_ configure: (inout CommandPayload) -> Void = { _ in }) -> CommandPayload {
        var payload = CommandPayload(workDirectory: workdir.path)
        configure(&payload)
        return payload
    }

    private func resolve(_ line: String,
                         mode: CommandSpec.Mode = .argv,
                         payload: CommandPayload? = nil,
                         stdin: CommandSpec.Stdin = .none,
                         environment: [String: String] = [:],
                         workingDirectory: String? = nil) throws -> ResolvedCommand {
        let spec = CommandSpec(line: line, mode: mode, stdin: stdin,
                               environment: environment, workingDirectory: workingDirectory)
        return try resolver.resolve(spec, payload: payload ?? self.payload())
    }

    // MARK: - argv

    func testMultiplePathsBecomeSeparateArguments() throws {
        let command = try resolve("/bin/echo {paths}", payload: payload {
            $0.paths = ["/tmp/a b.png", "/tmp/c.png"]
        })
        XCTAssertEqual(command.executable.path, "/bin/echo")
        XCTAssertEqual(command.arguments, ["/tmp/a b.png", "/tmp/c.png"])
        XCTAssertEqual(command.workingDirectory, workdir)
        XCTAssertEqual(command.outputDirectory, workdir.appendingPathComponent("output", isDirectory: true))
        XCTAssertNil(command.stdinFile)
    }

    func testPathTemplateExpandsTheParentPlaceholder() throws {
        let path = try resolver.resolvePathTemplate("{parent}/archive.zip", payload: payload {
            $0.paths = ["/tmp/a b/photo.png"]
        })
        XCTAssertEqual(path, "/tmp/a b/archive.zip")
        XCTAssertThrowsError(try resolver.resolvePathTemplate("{paths}", payload: payload {
            $0.paths = ["/tmp/a", "/tmp/b"]
        }))
    }

    func testParentPlaceholderIsTheFirstFilePathFolder() throws {
        let command = try resolve("/bin/echo {parent}/archive.zip", payload: payload {
            $0.paths = ["/tmp/a b/photo.png", "/elsewhere/other.png"]
        })
        XCTAssertEqual(command.arguments, ["/tmp/a b/archive.zip"])
    }

    func testParentPlaceholderWithoutAPathIsReported() {
        XCTAssertThrowsError(try resolve("/bin/echo {parent}")) { error in
            XCTAssertEqual(error as? CommandResolutionError,
                           .missingPlaceholderValue("parent"))
        }
    }

    func testEmbeddedSinglePlaceholderIsSubstituted() throws {
        let command = try resolve("/bin/echo --out={outdir}/x --name={name}",
                                  payload: payload {
                                      $0.name = "photo.png"
                                  })
        XCTAssertEqual(command.arguments,
                       ["--out=\(workdir.path)/output/x", "--name=photo.png"])
    }

    func testMultiplePlaceholderInsideATokenIsRejected() {
        XCTAssertThrowsError(try resolve("/bin/echo --in={paths}",
                                         payload: payload { $0.paths = ["/tmp/a"] })) { error in
            XCTAssertEqual(error as? CommandResolutionError,
                           .multiValuePlaceholderInToken("paths"))
        }
    }

    func testMissingSingleValueIsRejected() {
        XCTAssertThrowsError(try resolve("/bin/echo {text}")) { error in
            XCTAssertEqual(error as? CommandResolutionError, .missingPlaceholderValue("text"))
        }
    }

    func testEmptyMultiValueIsRejected() {
        XCTAssertThrowsError(try resolve("/bin/echo {paths}")) { error in
            XCTAssertEqual(error as? CommandResolutionError, .emptyMultiValue("paths"))
        }
    }

    func testUnknownBracesStayLiteral() throws {
        // `jq '{title}'` is a legitimate argument, not a typo to refuse.
        let command = try resolve("/bin/echo {title}", payload: payload { $0.name = "x" })
        XCTAssertEqual(command.arguments, ["{title}"])
    }

    func testDoubleBracesAreLiteralBraces() throws {
        let command = try resolve("/bin/echo {{paths}}", payload: payload { $0.paths = ["/tmp/a"] })
        XCTAssertEqual(command.arguments, ["{paths}"])
    }

    func testProgramWithSlashResolvesRelativeToTheRunDirectory() throws {
        let script = workdir.appendingPathComponent("tool.sh")
        try "#!/bin/sh\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let command = try resolve("./tool.sh")
        XCTAssertEqual(command.executable.standardizedFileURL.path, script.standardizedFileURL.path)
    }

    func testBareProgramIsFoundOnPATH() throws {
        let command = try resolve("echo hi")
        XCTAssertEqual(command.executable.path, "/bin/echo")
        XCTAssertEqual(command.arguments, ["hi"])
    }

    func testNonExecutableProgramIsReportedAsSuch() throws {
        let file = workdir.appendingPathComponent("plain.sh")
        try "#!/bin/sh\nexit 0\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try resolve("./plain.sh")) { error in
            XCTAssertEqual(error as? CommandResolutionError, .notExecutable(file.path))
        }
    }

    func testMissingProgramIsRejected() {
        XCTAssertThrowsError(try resolve("makidesk-definitely-missing")) { error in
            XCTAssertEqual(error as? CommandResolutionError,
                           .executableNotFound("makidesk-definitely-missing"))
        }
    }

    func testEmptyLineIsRejected() {
        XCTAssertThrowsError(try resolve("   ")) { error in
            XCTAssertEqual(error as? CommandResolutionError, .emptyLine)
        }
    }

    // MARK: - shell

    func testShellModeQuotesPlaceholders() throws {
        let command = try resolve("printf '%s' {text} --out={outdir}",
                                  mode: .shell,
                                  payload: payload { $0.text = "a b'c" })
        XCTAssertEqual(command.executable.path, "/bin/zsh")
        XCTAssertEqual(command.arguments.count, 2)
        XCTAssertEqual(command.arguments[0], "-lc")
        XCTAssertEqual(command.arguments[1],
                       "printf '%s' 'a b'\\''c' --out='\(workdir.path)/output'")
    }

    func testShellModeRefusesQuotedPlaceholders() {
        XCTAssertThrowsError(try resolve(#"printf "%s" "{text}""#,
                                         mode: .shell,
                                         payload: payload { $0.text = "x" })) { error in
            XCTAssertEqual(error as? CommandResolutionError, .quotedPlaceholder("text"))
        }
    }

    func testShellModeLeavesUnrelatedBracesForTheShell() throws {
        let command = try resolve("awk '{print $1}' {text}",
                                  mode: .shell,
                                  payload: payload { $0.text = "x" })
        XCTAssertEqual(command.arguments[1], "awk '{print $1}' 'x'")
    }

    // MARK: - Environment and stdin

    func testEnvironmentCarriesRunVariablesAndDefaults() throws {
        let payload = payload {
            $0.count = 2
            $0.kinds = ["files", "text"]
            $0.sourceApp = "com.apple.finder"
            $0.context = ["MAKIDESK_ZONE": "ABC"]
            $0.manifestFile = "/tmp/manifest.json"
        }
        let command = try resolve("/bin/echo hi", payload: payload,
                                  environment: ["FOO": "bar", "PATH": "/custom/bin"])
        XCTAssertEqual(command.environment["FOO"], "bar")
        XCTAssertEqual(command.environment["PATH"], "/custom/bin")
        XCTAssertEqual(command.environment["HOME"], "/Users/test")
        XCTAssertEqual(command.environment["MAKIDESK_ZONE"], "ABC")
        XCTAssertEqual(command.environment["MAKIDESK_COUNT"], "2")
        XCTAssertEqual(command.environment["MAKIDESK_KINDS"], "files,text")
        XCTAssertEqual(command.environment["MAKIDESK_SOURCE_APP"], "com.apple.finder")
        XCTAssertEqual(command.environment["MAKIDESK_WORKDIR"], workdir.path)
        XCTAssertEqual(command.environment["MAKIDESK_OUTDIR"], "\(workdir.path)/output")
        XCTAssertEqual(command.environment["MAKIDESK_MANIFEST"], "/tmp/manifest.json")
    }

    func testDefaultPATHIncludesHomebrew() throws {
        let command = try resolve("/bin/echo hi")
        XCTAssertEqual(command.environment["PATH"], CommandResolver.defaultPATH)
        XCTAssertTrue(CommandResolver.defaultPATH.contains("/opt/homebrew/bin"))
    }

    func testTextStdinUsesThePreparedFile() throws {
        let file = workdir.appendingPathComponent("text.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let command = try resolve("/bin/cat", payload: payload {
            $0.text = "hello"
            $0.textFile = file.path
        }, stdin: .text)
        XCTAssertEqual(command.stdinFile, file)
    }

    func testMissingTextStdinIsRejected() {
        XCTAssertThrowsError(try resolve("/bin/cat", stdin: .text)) { error in
            XCTAssertEqual(error as? CommandResolutionError, .missingStdinFile("text"))
        }
    }

    // MARK: - Working directory and timeout

    func testWorkingDirectoryCanBeOverridden() throws {
        let subdirectory = workdir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let command = try resolve("/bin/pwd", workingDirectory: subdirectory.path)
        XCTAssertEqual(command.workingDirectory, subdirectory)
    }

    func testMissingWorkingDirectoryIsRejected() {
        XCTAssertThrowsError(try resolve("/bin/pwd", workingDirectory: "/definitely/missing/dir")) { error in
            XCTAssertEqual(error as? CommandResolutionError,
                           .invalidWorkingDirectory("/definitely/missing/dir"))
        }
    }

    func testTimeoutRangeIsValidated() {
        XCTAssertThrowsError(try resolver.resolve(
            CommandSpec(line: "/bin/echo hi", timeoutSeconds: 3601),
            payload: payload()
        )) { error in
            XCTAssertEqual(error as? CommandResolutionError, .invalidTimeout(3601))
        }
        XCTAssertNoThrow(try resolver.resolve(
            CommandSpec(line: "/bin/echo hi", timeoutSeconds: 0),
            payload: payload()
        ))
    }

    func testInheritedDyldVariablesAreDroppedButExplicitOnesKept() throws {
        let inheriting = CommandResolver(baseEnvironment: ["HOME": "/Users/test",
                                                           "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib"])
        let plain = try inheriting.resolve(CommandSpec(line: "/bin/echo hi"), payload: payload())
        XCTAssertNil(plain.environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertEqual(plain.environment["HOME"], "/Users/test")

        let explicit = try inheriting.resolve(
            CommandSpec(line: "/bin/echo hi", environment: ["DYLD_LIBRARY_PATH": "/opt/lib"]),
            payload: payload())
        XCTAssertEqual(explicit.environment["DYLD_LIBRARY_PATH"], "/opt/lib")
    }

    func testCountAndNamePlaceholders() throws {
        let command = try resolve("/bin/echo {name} {count}", payload: payload {
            $0.name = "IMG 1.png"
            $0.count = 3
        })
        XCTAssertEqual(command.arguments, ["IMG 1.png", "3"])
    }
}
