import Foundation

/// The placeholders a command may use. Only these names are expanded: anything
/// else is left untouched, so `awk '{print $1}'` and `jq '{title}'` still work
/// in both modes. The Settings editor warns about a name that looks like a
/// typo of one of these.
enum CommandPlaceholder: String, CaseIterable, Sendable {
    case paths
    case path
    case text
    case textfile
    case urls
    case urlsfile
    case manifest
    case workdir
    case outdir
    case name
    case count

    enum Value: Equatable, Sendable {
        case single(String)
        case multiple([String])
    }

    var isMultiValue: Bool { self == .paths || self == .urls }

    /// `nil` when this run has nothing for the placeholder (no text, no file),
    /// which the resolver reports instead of passing an empty argument.
    func value(in payload: CommandPayload) -> Value? {
        switch self {
        case .paths:
            return .multiple(payload.paths)
        case .path:
            return payload.paths.first.map { .single($0) }
        case .text:
            return payload.text.map { .single($0) }
        case .textfile:
            return payload.textFile.map { .single($0) }
        case .urls:
            return .multiple(payload.urls)
        case .urlsfile:
            return payload.urlsFile.map { .single($0) }
        case .manifest:
            return payload.manifestFile.map { .single($0) }
        case .workdir:
            return .single(payload.workDirectory)
        case .outdir:
            return .single(URL(fileURLWithPath: payload.workDirectory, isDirectory: true)
                .appendingPathComponent("output", isDirectory: true).path)
        case .name:
            return payload.name.map { .single($0) }
        case .count:
            return .single(String(payload.count))
        }
    }

    /// The placeholder when the whole token is exactly `{name}`.
    static func exact(in token: String) -> CommandPlaceholder? {
        guard token.count > 2, token.first == "{", token.last == "}",
              token.dropFirst().dropLast().contains("{") == false else { return nil }
        return CommandPlaceholder(rawValue: String(token.dropFirst().dropLast()))
    }
}

/// A small shell-like tokenizer for the safe `argv` mode.
///
/// It understands single quotes, double quotes and backslashes — enough for
/// "paste the command you would type" — and nothing else: no variables, no
/// globs, no pipes, no command substitution. Those belong to `shell` mode, and
/// staying literal here is the point.
enum CommandLineTokenizer {
    static func tokenize(_ line: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var quote: Character?
        var index = line.startIndex

        func advance(_ position: inout String.Index) {
            position = line.index(after: position)
        }

        while index < line.endIndex {
            let character = line[index]
            if let active = quote {
                if character == active {
                    quote = nil
                    advance(&index)
                    continue
                }
                if active == "\"", character == "\\" {
                    advance(&index)
                    if index < line.endIndex {
                        current.append(line[index])
                        advance(&index)
                    } else {
                        throw CommandResolutionError.unterminatedQuote
                    }
                    continue
                }
                current.append(character)
                advance(&index)
                continue
            }

            switch character {
            case "\"", "'":
                quote = character
                hasToken = true
                advance(&index)
            case "\\":
                advance(&index)
                if index < line.endIndex {
                    current.append(line[index])
                    advance(&index)
                } else {
                    current.append("\\")
                }
                hasToken = true
            case " ", "\t", "\n", "\r":
                if hasToken {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
                advance(&index)
            default:
                current.append(character)
                hasToken = true
                advance(&index)
            }
        }

        if quote != nil { throw CommandResolutionError.unterminatedQuote }
        if hasToken { tokens.append(current) }
        return tokens
    }

    /// Single-quotes a value for `/bin/zsh`. Every `'` becomes `'\''`, the one
    /// form that survives spaces, `$`, backticks, `;` and newlines.
    static func shellQuote(_ value: String) -> String {
        guard value.isEmpty == false else { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
