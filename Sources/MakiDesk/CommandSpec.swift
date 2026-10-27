import Foundation

/// The command a dropzone (T44) or a text command (T38) runs.
///
/// A pure value type: no AppKit, no process, no file-system side effects. The
/// `line` is what the user typed — a command with placeholders — and
/// `CommandResolver` turns it into a `ResolvedCommand` for `CommandRunner`.
struct CommandSpec: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable {
        /// The line is tokenized and passed as `argv`, with no shell.
        case argv
        /// The line is run by `/bin/zsh -lc`; only placeholders are quoted.
        case shell
    }

    enum Stdin: String, Codable, Sendable {
        case none
        /// The dropped text, as a temporary UTF-8 file.
        case text
        /// The whole payload, as a JSON manifest file.
        case manifest
    }

    var line: String
    var mode: Mode
    var stdin: Stdin
    /// Extra variables for the child, merged over the inherited environment.
    var environment: [String: String]
    /// `nil` means the run's working directory.
    var workingDirectory: String?
    /// `0` disables the timeout.
    var timeoutSeconds: Int
    /// Keeps the run directory after the command exits (diagnostics).
    var keepWorkdir: Bool

    init(line: String = "",
         mode: Mode = .argv,
         stdin: Stdin = .none,
         environment: [String: String] = [:],
         workingDirectory: String? = nil,
         timeoutSeconds: Int = 60,
         keepWorkdir: Bool = false) {
        self.line = line
        self.mode = mode
        self.stdin = stdin
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
        self.keepWorkdir = keepWorkdir
    }

    /// Hand-edited JSON and older files may omit any field, so every key is
    /// read leniently and falls back to the default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        line = try container.decodeIfPresent(String.self, forKey: .line) ?? ""
        mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .argv
        stdin = try container.decodeIfPresent(Stdin.self, forKey: .stdin) ?? .none
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 60
        keepWorkdir = try container.decodeIfPresent(Bool.self, forKey: .keepWorkdir) ?? false
    }
}

/// Everything a command may need from one run, already materialized.
///
/// The caller owns the run directory and creates the temporary files named
/// here; the resolver only reads the paths. `context` carries app-level
/// variables (for example the dropzone's `MAKIDESK_ZONE` and its name) so the
/// command core stays independent of dropzones and text commands.
struct CommandPayload: Equatable, Sendable {
    var paths: [String] = []
    var text: String?
    var urls: [String] = []
    var name: String?
    var count: Int = 0
    var kinds: [String] = []
    var workDirectory: String
    var textFile: String?
    var urlsFile: String?
    var manifestFile: String?
    var sourceApp: String?
    var context: [String: String] = [:]

    init(workDirectory: String,
         paths: [String] = [],
         text: String? = nil,
         urls: [String] = [],
         name: String? = nil,
         count: Int = 0,
         kinds: [String] = [],
         textFile: String? = nil,
         urlsFile: String? = nil,
         manifestFile: String? = nil,
         sourceApp: String? = nil,
         context: [String: String] = [:]) {
        self.workDirectory = workDirectory
        self.paths = paths
        self.text = text
        self.urls = urls
        self.name = name
        self.count = count
        self.kinds = kinds
        self.textFile = textFile
        self.urlsFile = urlsFile
        self.manifestFile = manifestFile
        self.sourceApp = sourceApp
        self.context = context
    }
}

/// A command ready to run: absolute executable, final arguments, environment
/// and the files the runner owns.
struct ResolvedCommand: Equatable, Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL
    /// Where stdout, stderr and temporary files go; the caller may delete it.
    let workDirectory: URL
    /// `<workDirectory>/output`, what `{outdir}` points at.
    let outputDirectory: URL
    let stdinFile: URL?
    /// Seconds; `0` disables the timeout.
    let timeout: TimeInterval
    let keepWorkdir: Bool
}

enum CommandResolutionError: Error, Equatable, LocalizedError {
    case emptyLine
    case unterminatedQuote
    case multiValuePlaceholderInToken(String)
    case missingPlaceholderValue(String)
    case emptyMultiValue(String)
    case quotedPlaceholder(String)
    case executableNotFound(String)
    case notExecutable(String)
    case invalidWorkingDirectory(String)
    case invalidTimeout(Int)
    case missingStdinFile(String)

    var errorDescription: String? {
        switch self {
        case .emptyLine:
            return "The command is empty."
        case .unterminatedQuote:
            return "The command has an unterminated quote."
        case let .multiValuePlaceholderInToken(name):
            return "{\(name)} must be a separate argument: write it as a token of its own."
        case let .missingPlaceholderValue(name):
            return "Nothing was dropped for {\(name)}."
        case let .emptyMultiValue(name):
            return "Nothing was dropped for {\(name)}."
        case let .quotedPlaceholder(name):
            return "Do not put quotes around {\(name)}; the app quotes it already."
        case let .executableNotFound(name):
            return "Command not found: \(name). Check PATH or use an absolute path."
        case let .notExecutable(path):
            return "Not executable: \(path)."
        case let .invalidWorkingDirectory(path):
            return "Working directory not found: \(path)."
        case let .invalidTimeout(seconds):
            return "Timeout must be 0 (none) or between 1 and 3600 seconds; got \(seconds)."
        case let .missingStdinFile(name):
            return "No \(name) file was prepared for standard input."
        }
    }
}

/// Refuses commands that would ask for an administrator password (T47).
///
/// The runner starts without a TTY, so `sudo` usually fails on its own. That is
/// not a guarantee, and the failure is a poor explanation: this rejects the
/// command before a process exists.
enum CommandElevation {
    static let message = "MakiDesk does not run commands that ask for an administrator password. Remove sudo from the command."

    static func rejection(for command: ResolvedCommand) -> String? {
        if isSudo(command.executable) { return message }
        if command.executable.lastPathComponent == "env",
           let first = command.arguments.first, isSudo(URL(fileURLWithPath: first)) {
            return message
        }
        if shells.contains(command.executable.lastPathComponent),
           let script = command.arguments.last, startsWithSudo(script) {
            return message
        }
        return nil
    }

    private static let shells: Set<String> = ["zsh", "sh", "bash"]

    private static func isSudo(_ url: URL) -> Bool {
        url.lastPathComponent == "sudo"
    }

    /// `sudo …`, `/usr/bin/sudo …`, `env sudo …`, `env -i sudo …`.
    private static func startsWithSudo(_ script: String) -> Bool {
        let words = script.split(whereSeparator: \.isWhitespace).prefix(3).map(String.init)
        guard let first = words.first else { return false }
        if isSudo(URL(fileURLWithPath: first)) { return true }
        if first == "env" || first.hasSuffix("/env") {
            return words.dropFirst().contains { isSudo(URL(fileURLWithPath: $0)) }
        }
        return false
    }
}

/// Expands and validates a `CommandSpec` into a `ResolvedCommand`.
///
/// Pure apart from resolving the executable and checking the working
/// directory, both of which make the error readable *before* spawning.
struct CommandResolver {
    /// GUI apps inherit a minimal PATH, so Homebrew tools would not be found.
    static let defaultPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Injected for tests; the real app passes its own environment.
    let baseEnvironment: [String: String]

    init(baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.baseEnvironment = baseEnvironment
    }

    func resolve(_ spec: CommandSpec, payload: CommandPayload) throws -> ResolvedCommand {
        let line = spec.line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.isEmpty == false else { throw CommandResolutionError.emptyLine }
        guard (0...3600).contains(spec.timeoutSeconds) else {
            throw CommandResolutionError.invalidTimeout(spec.timeoutSeconds)
        }

        let workDirectory = Self.url(payload.workDirectory)
        let workingDirectory: URL
        if let raw = spec.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines), raw.isEmpty == false {
            let url = Self.url((raw as NSString).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw CommandResolutionError.invalidWorkingDirectory(url.path)
            }
            workingDirectory = url
        } else {
            workingDirectory = workDirectory
        }

        let environment = resolveEnvironment(spec: spec, payload: payload, workDirectory: workDirectory)
        let stdinFile = try resolveStdin(spec: spec, payload: payload)

        switch spec.mode {
        case .argv:
            let tokens = try CommandLineTokenizer.tokenize(line)
            let expanded = try expandAll(tokens: tokens, payload: payload)
            guard let program = expanded.first, program.isEmpty == false else {
                throw CommandResolutionError.emptyLine
            }
            let executable = try resolveExecutable(program,
                                                   workingDirectory: workingDirectory,
                                                   environment: environment)
            return ResolvedCommand(executable: executable,
                                   arguments: Array(expanded.dropFirst()),
                                   environment: environment,
                                   workingDirectory: workingDirectory,
                                   workDirectory: workDirectory,
                                   outputDirectory: workDirectory.appendingPathComponent("output", isDirectory: true),
                                   stdinFile: stdinFile,
                                   timeout: TimeInterval(spec.timeoutSeconds),
                                   keepWorkdir: spec.keepWorkdir)
        case .shell:
            let expanded = try expandShellLine(line, payload: payload)
            return ResolvedCommand(executable: URL(fileURLWithPath: "/bin/zsh"),
                                   arguments: ["-lc", expanded],
                                   environment: environment,
                                   workingDirectory: workingDirectory,
                                   workDirectory: workDirectory,
                                   outputDirectory: workDirectory.appendingPathComponent("output", isDirectory: true),
                                   stdinFile: stdinFile,
                                   timeout: TimeInterval(spec.timeoutSeconds),
                                   keepWorkdir: spec.keepWorkdir)
        }
    }

    /// Expands one path template (for example a preset's checked output) with
    /// the same placeholder rules as an argv token. It is not tokenized and
    /// unknown braces stay literal; a multi-value placeholder is rejected
    /// because the result must be a single path.
    func resolvePathTemplate(_ template: String, payload: CommandPayload) throws -> String {
        try expandToken(template, payload: payload)
    }

    // MARK: - Environment

    private func resolveEnvironment(spec: CommandSpec,
                                    payload: CommandPayload,
                                    workDirectory: URL) -> [String: String] {
        var environment = baseEnvironment
        // The inherited PATH of a GUI app does not include Homebrew, so the
        // default is explicit and the spec may override it.
        environment["PATH"] = spec.environment["PATH"] ?? Self.defaultPATH
        for (key, value) in spec.environment {
            environment[key] = value
        }
        // App-provided variables win over user ones: they describe this run.
        for (key, value) in payload.context {
            environment[key] = value
        }
        environment["MAKIDESK_WORKDIR"] = workDirectory.path
        environment["MAKIDESK_OUTDIR"] = workDirectory.appendingPathComponent("output", isDirectory: true).path
        environment["MAKIDESK_COUNT"] = String(payload.count)
        if payload.kinds.isEmpty == false {
            environment["MAKIDESK_KINDS"] = payload.kinds.joined(separator: ",")
        }
        if let manifest = payload.manifestFile {
            environment["MAKIDESK_MANIFEST"] = manifest
        }
        if let sourceApp = payload.sourceApp {
            environment["MAKIDESK_SOURCE_APP"] = sourceApp
        }
        return environment
    }

    // MARK: - Stdin

    private func resolveStdin(spec: CommandSpec, payload: CommandPayload) throws -> URL? {
        switch spec.stdin {
        case .none:
            return nil
        case .text:
            guard let file = payload.textFile else {
                throw CommandResolutionError.missingStdinFile("text")
            }
            let url = Self.url(file, isDirectory: false)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CommandResolutionError.missingStdinFile("text")
            }
            return url
        case .manifest:
            guard let file = payload.manifestFile else {
                throw CommandResolutionError.missingStdinFile("manifest")
            }
            let url = Self.url(file, isDirectory: false)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CommandResolutionError.missingStdinFile("manifest")
            }
            return url
        }
    }

    // MARK: - argv

    private func expandAll(tokens: [String], payload: CommandPayload) throws -> [String] {
        var result: [String] = []
        result.reserveCapacity(tokens.count)
        for token in tokens {
            if let whole = CommandPlaceholder.exact(in: token) {
                guard let value = whole.value(in: payload) else {
                    throw CommandResolutionError.missingPlaceholderValue(whole.rawValue)
                }
                switch value {
                case let .single(value):
                    result.append(value)
                case let .multiple(values):
                    guard values.isEmpty == false else {
                        throw CommandResolutionError.emptyMultiValue(whole.rawValue)
                    }
                    result.append(contentsOf: values)
                }
            } else {
                result.append(try expandToken(token, payload: payload))
            }
        }
        return result
    }

    private func expandToken(_ token: String, payload: CommandPayload) throws -> String {
        var output = ""
        var index = token.startIndex
        while index < token.endIndex {
            let character = token[index]
            if character == "{" {
                let next = token.index(after: index)
                if next < token.endIndex, token[next] == "{" {
                    output.append("{")
                    index = token.index(after: next)
                    continue
                }
                if let close = token[next...].firstIndex(of: "}"),
                   let placeholder = CommandPlaceholder(rawValue: String(token[next..<close])) {
                    guard let value = placeholder.value(in: payload) else {
                        throw CommandResolutionError.missingPlaceholderValue(placeholder.rawValue)
                    }
                    switch value {
                    case let .single(value):
                        output.append(value)
                    case .multiple:
                        throw CommandResolutionError.multiValuePlaceholderInToken(placeholder.rawValue)
                    }
                    index = token.index(after: close)
                    continue
                }
                output.append(character)
                index = next
                continue
            }
            if character == "}" {
                let next = token.index(after: index)
                if next < token.endIndex, token[next] == "}" {
                    output.append("}")
                    index = token.index(after: next)
                    continue
                }
            }
            output.append(character)
            index = token.index(after: index)
        }
        return output
    }

    // MARK: - Shell

    /// In shell mode only *known* placeholders are replaced, so `{print $1}`
    /// and `jq '{title}'` keep working. The value is single-quoted; a
    /// placeholder wrapped in the user's own quotes would nest them, so that
    /// is refused instead of producing a broken command line.
    private func expandShellLine(_ line: String, payload: CommandPayload) throws -> String {
        var output = ""
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            guard character == "{" else {
                output.append(character)
                index = line.index(after: index)
                continue
            }
            let next = line.index(after: index)
            guard next < line.endIndex,
                  let close = line[next...].firstIndex(of: "}"),
                  let placeholder = CommandPlaceholder(rawValue: String(line[next..<close])) else {
                output.append(character)
                index = next
                continue
            }
            if let before = line[..<index].last, before == "'" || before == "\"" || before == "\\" {
                throw CommandResolutionError.quotedPlaceholder(placeholder.rawValue)
            }
            let afterIndex = line.index(after: close)
            if afterIndex < line.endIndex {
                let after = line[afterIndex]
                if after == "'" || after == "\"" || after == "\\" {
                    throw CommandResolutionError.quotedPlaceholder(placeholder.rawValue)
                }
            }
            guard let value = placeholder.value(in: payload) else {
                throw CommandResolutionError.missingPlaceholderValue(placeholder.rawValue)
            }
            switch value {
            case let .single(value):
                output.append(CommandLineTokenizer.shellQuote(value))
            case let .multiple(values):
                guard values.isEmpty == false else {
                    throw CommandResolutionError.emptyMultiValue(placeholder.rawValue)
                }
                output.append(values.map(CommandLineTokenizer.shellQuote).joined(separator: " "))
            }
            index = afterIndex
        }
        return output
    }

    // MARK: - Executable

    private func resolveExecutable(_ program: String,
                                   workingDirectory: URL,
                                   environment: [String: String]) throws -> URL {
        let expanded = (program as NSString).expandingTildeInPath
        let candidates: [URL]
        if expanded.contains("/") {
            if expanded.hasPrefix("/") {
                candidates = [URL(fileURLWithPath: expanded)]
            } else {
                candidates = [URL(fileURLWithPath: expanded, relativeTo: workingDirectory).standardizedFileURL]
            }
        } else {
            let path = environment["PATH"] ?? Self.defaultPATH
            candidates = path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent(expanded)
            }
        }
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            if let existing = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                throw CommandResolutionError.notExecutable(existing.path)
            }
            throw CommandResolutionError.executableNotFound(program)
        }
        return found
    }

    private static func url(_ path: String, isDirectory: Bool = true) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: isDirectory)
    }
}
