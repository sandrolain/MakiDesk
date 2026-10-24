import XCTest
@testable import MakiDesk

/// T38/T44: the safe `argv` tokenizer and the placeholder vocabulary. These
/// are pure functions, so the tests do not touch the disk or spawn anything.
final class CommandTemplateTests: XCTestCase {
    func testTokenizerKeepsQuotedArgumentsTogether() throws {
        let tokens = try CommandLineTokenizer.tokenize(
            #"shortcuts run ABC --input-path "/Users/me/My File.png" 'second file' escape\ space"#
        )
        XCTAssertEqual(tokens, ["shortcuts", "run", "ABC", "--input-path",
                                "/Users/me/My File.png", "second file", "escape space"])
    }

    func testTokenizerPreservesAnEmptyQuotedArgument() throws {
        XCTAssertEqual(try CommandLineTokenizer.tokenize(#"cmd """#), ["cmd", ""])
        XCTAssertEqual(try CommandLineTokenizer.tokenize("cmd ''"), ["cmd", ""])
    }

    func testTokenizerLeavesShellSyntaxLiteral() throws {
        // In argv mode these are characters, not shell syntax: the shell mode
        // is the only one where they mean something.
        let tokens = try CommandLineTokenizer.tokenize(#"echo $HOME `id` a|b *.png"#)
        XCTAssertEqual(tokens, ["echo", "$HOME", "`id`", "a|b", "*.png"])
    }

    func testTokenizerReportsAnUnterminatedQuote() {
        XCTAssertThrowsError(try CommandLineTokenizer.tokenize(#"echo "abc"#)) { error in
            XCTAssertEqual(error as? CommandResolutionError, .unterminatedQuote)
        }
        XCTAssertThrowsError(try CommandLineTokenizer.tokenize("echo 'abc")) { error in
            XCTAssertEqual(error as? CommandResolutionError, .unterminatedQuote)
        }
    }

    func testTokenizerHandlesEscapedQuotesInsideDoubleQuotes() throws {
        XCTAssertEqual(try CommandLineTokenizer.tokenize(#"echo "a\"b""#), ["echo", #"a"b"#])
    }

    func testShellQuoteSurvivesSpacesQuotesAndDollars() {
        XCTAssertEqual(CommandLineTokenizer.shellQuote(""), "''")
        XCTAssertEqual(CommandLineTokenizer.shellQuote("plain"), "'plain'")
        XCTAssertEqual(CommandLineTokenizer.shellQuote("a b"), "'a b'")
        XCTAssertEqual(CommandLineTokenizer.shellQuote("it's $(rm -rf /)"),
                       #"'it'\''s $(rm -rf /)'"#)
    }

    func testExactPlaceholderRequiresTheWholeToken() {
        XCTAssertEqual(CommandPlaceholder.exact(in: "{paths}"), .paths)
        XCTAssertEqual(CommandPlaceholder.exact(in: "{count}"), .count)
        XCTAssertNil(CommandPlaceholder.exact(in: "--in={paths}"))
        XCTAssertNil(CommandPlaceholder.exact(in: "{unknown}"))
        XCTAssertNil(CommandPlaceholder.exact(in: "{{paths}}"))
    }

    func testSpecDecodesMissingFieldsLeniently() throws {
        let json = #"{"line":"echo hi","mode":"shell"}"#.data(using: .utf8)!
        let spec = try JSONDecoder().decode(CommandSpec.self, from: json)
        XCTAssertEqual(spec.line, "echo hi")
        XCTAssertEqual(spec.mode, .shell)
        XCTAssertEqual(spec.stdin, .none)
        XCTAssertEqual(spec.timeoutSeconds, 60)
        XCTAssertFalse(spec.keepWorkdir)
        XCTAssertEqual(spec.environment, [:])
    }
}
