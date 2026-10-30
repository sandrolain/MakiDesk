import Foundation

/// One edit the editor applies as a single, undoable change (T65).
///
/// The formatter never mutates a text view: it returns the range to replace,
/// what to put there and where the selection goes afterwards, so the rules can
/// be checked without AppKit.
struct NotesMarkdownChange: Equatable {
    let range: NSRange
    let replacement: String
    /// The selection in the text as it is after the edit.
    let selection: NSRange
}

enum NotesMarkdownList: Equatable {
    case bullet
    case numbered
    case checkbox
}

/// The deterministic Markdown commands of the notes editor (T65).
///
/// Everything here is plain string work on UTF-16 ranges — the editor's own
/// coordinate space — so emoji and surrogate pairs cannot split a marker. The
/// model never writes Markdown: this code does, and T66 reuses it to serialise
/// what the on-device model returns.
enum NotesMarkdownFormat {
    // MARK: - Styles

    static func bold(in text: String, selection: NSRange) -> NotesMarkdownChange? {
        toggleWrap("**", in: text, selection: selection)
    }

    static func italic(in text: String, selection: NSRange) -> NotesMarkdownChange? {
        toggleWrap("*", in: text, selection: selection)
    }

    static func code(in text: String, selection: NSRange) -> NotesMarkdownChange? {
        toggleWrap("`", in: text, selection: selection)
    }

    /// `[label](url)`, with `url` selected so typing replaces the placeholder.
    /// Anywhere inside an existing link — label or url — the command unwraps it.
    static func link(in text: String, selection: NSRange) -> NotesMarkdownChange? {
        let text = text as NSString
        let range = effectiveRange(in: text, selection: selection)
        if let full = enclosingLink(in: text, around: range) {
            let labelRange = text.range(of: "]", options: [],
                                        range: NSRange(location: full.location,
                                                       length: full.length))
            let label = labelRange.location == NSNotFound
                ? ""
                : text.substring(with: NSRange(location: full.location + 1,
                                               length: labelRange.location - full.location - 1))
            return NotesMarkdownChange(
                range: full, replacement: label,
                selection: NSRange(location: full.location,
                                   length: (label as NSString).length)
            )
        }
        let label = text.substring(with: range)
        let replacement = "[\(label)](url)"
        let urlStart = range.location + 1 + (label as NSString).length + 2
        return NotesMarkdownChange(
            range: range, replacement: replacement,
            selection: NSRange(location: urlStart, length: 3)
        )
    }

    // MARK: - Blocks

    static func toggleList(_ kind: NotesMarkdownList, in text: String,
                           selection: NSRange) -> NotesMarkdownChange? {
        let text = text as NSString
        let block = lineRange(in: text, selection: selection)
        guard block.length > 0 else { return nil }
        var parsed: [(parts: LineParts, ending: String)] = []
        var allHave = true
        for line in lineRanges(of: block, in: text) {
            let (body, ending) = splitEnding(text.substring(with: line))
            let parts = parse(body)
            parsed.append((parts, ending))
            if parts.kind != kind { allHave = false }
        }
        var output = ""
        var number = 1
        for (parts, ending) in parsed {
            var line = parts.indent
            if parts.quoted { line += "> " }
            if allHave == false {
                switch kind {
                case .bullet: line += "- "
                case .checkbox: line += "- [ ] "
                case .numbered:
                    line += "\(number). "
                    number += 1
                }
            }
            line += parts.content + ending
            output += line
        }
        return blockChange(range: block, replacement: output)
    }

    static func toggleQuote(in text: String, selection: NSRange) -> NotesMarkdownChange? {
        let text = text as NSString
        let block = lineRange(in: text, selection: selection)
        guard block.length > 0 else { return nil }
        var parsed: [(parts: LineParts, ending: String, body: String)] = []
        var allQuoted = true
        for line in lineRanges(of: block, in: text) {
            let (body, ending) = splitEnding(text.substring(with: line))
            let parts = parse(body)
            parsed.append((parts, ending, body))
            if parts.quoted == false { allQuoted = false }
        }
        var output = ""
        for (parts, ending, _) in parsed {
            var line = parts.indent
            if allQuoted == false { line += "> " }
            line += parts.content + ending
            output += line
        }
        return blockChange(range: block, replacement: output)
    }

    /// Two spaces per level, the Markdown convention for a nested list.
    static func indent(in text: String, selection: NSRange,
                       outdent: Bool = false) -> NotesMarkdownChange? {
        let text = text as NSString
        let block = lineRange(in: text, selection: selection)
        guard block.length > 0 else { return nil }
        var output = ""
        for line in lineRanges(of: block, in: text) {
            let (body, ending) = splitEnding(text.substring(with: line))
            if body.isEmpty {
                output += body + ending
                continue
            }
            if outdent {
                var stripped = body
                if stripped.hasPrefix("\t") {
                    stripped.removeFirst()
                } else if stripped.hasPrefix("  ") {
                    stripped.removeFirst(2)
                } else if stripped.hasPrefix(" ") {
                    stripped.removeFirst()
                }
                output += stripped + ending
            } else {
                output += "  " + body + ending
            }
        }
        return blockChange(range: block, replacement: output)
    }

    /// Wraps the selected lines in a fenced block, or removes the fence when the
    /// selection already is one. The language comes from the note, so the fence
    /// is closed with the grammar Tree-sitter already knows.
    static func toggleFence(in text: String, selection: NSRange,
                            language: String) -> NotesMarkdownChange? {
        let text = text as NSString
        let block = lineRange(in: text, selection: selection)
        guard block.length > 0 else { return nil }
        let content = text.substring(with: block)
        let lines = lineRanges(of: block, in: text)
        let (firstBody, _) = splitEnding(text.substring(with: lines[0]))
        let (lastBody, _) = splitEnding(text.substring(with: lines[lines.count - 1]))
        if lines.count >= 2, firstBody.hasPrefix("```"), lastBody == "```" {
            // Remove the two fence lines and keep what is inside.
            let innerRange = NSRange(location: NSMaxRange(lines[0]),
                                     length: lines[lines.count - 1].location - NSMaxRange(lines[0]))
            let inner = text.substring(with: innerRange)
            return NotesMarkdownChange(
                range: block, replacement: inner,
                selection: NSRange(location: block.location,
                                   length: (inner as NSString).length)
            )
        }
        let opening = "```" + language + "\n"
        let endsWithNewline = content.hasSuffix("\n")
        var output = opening + content
        if endsWithNewline == false { output += "\n" }
        output += "```"
        if endsWithNewline { output += "\n" }
        return blockChange(range: block, replacement: output)
    }

    /// Reformats the selected lines as a GFM table with the columns aligned on
    /// their longest cell. An existing separator row keeps its alignments.
    static func table(in text: String, selection: NSRange) -> NotesMarkdownChange? {
        let text = text as NSString
        let block = lineRange(in: text, selection: selection)
        guard block.length > 0 else { return nil }
        // A table needs cells: plain prose is not turned into a one-column table.
        guard text.substring(with: block).contains("|") else { return nil }
        var rows: [[String]] = []
        var alignments: [String] = []
        var endsWithNewline = false
        for (index, line) in lineRanges(of: block, in: text).enumerated() {
            let (body, ending) = splitEnding(text.substring(with: line))
            if index == lineRanges(of: block, in: text).count - 1 {
                endsWithNewline = ending.isEmpty == false
            }
            let cells = body.components(separatedBy: "|")
                .drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            var values = cells.map { $0.trimmingCharacters(in: .whitespaces) }
            if values.last?.isEmpty == true { values.removeLast() }
            guard values.isEmpty == false else { continue }
            if values.allSatisfy({ isSeparator($0) }) {
                alignments = values
                continue
            }
            rows.append(values)
        }
        guard rows.isEmpty == false else { return nil }
        let columns = max(rows.map(\.count).max() ?? 0, alignments.count)
        guard columns > 0 else { return nil }
        var widths = Array(repeating: 3, count: columns)
        for row in rows {
            for (column, cell) in row.enumerated() where column < columns {
                widths[column] = max(widths[column], (cell as NSString).length)
            }
        }
        func padded(_ cell: String, _ width: Int) -> String {
            let value = cell as NSString
            let short = max(0, width - value.length)
            return cell + String(repeating: " ", count: short)
        }
        func separator(_ column: Int) -> String {
            var marker = String(repeating: "-", count: widths[column])
            let alignment = column < alignments.count ? alignments[column] : "---"
            let left = alignment.hasPrefix(":")
            let right = alignment.hasSuffix(":")
            if left && right {
                marker = ":" + String(repeating: "-", count: max(1, widths[column] - 2)) + ":"
            } else if right {
                marker = String(repeating: "-", count: max(2, widths[column] - 1)) + ":"
            } else if left {
                marker = ":" + String(repeating: "-", count: max(2, widths[column] - 1))
            }
            return padded(marker, widths[column])
        }
        func row(_ cells: [String]) -> String {
            var line = "|"
            for column in 0..<columns {
                let cell = column < cells.count ? cells[column] : ""
                line += " " + padded(cell, widths[column]) + " |"
            }
            return line
        }
        var output = row(rows[0]) + "\n"
        var header = "|"
        for column in 0..<columns {
            header += " " + separator(column) + " |"
        }
        output += header + "\n"
        for cells in rows.dropFirst() { output += row(cells) + "\n" }
        if endsWithNewline == false, output.hasSuffix("\n") { output.removeLast() }
        return blockChange(range: block, replacement: output)
    }

    // MARK: - Ranges

    /// The word under a caret, or the selection as it is. On punctuation a caret
    /// is used as it is, so a pair of markers can be typed and filled in.
    static func effectiveRange(in text: NSString, selection: NSRange) -> NSRange {
        let length = text.length
        let location = min(max(selection.location, 0), length)
        guard selection.length > 0 else {
            var start = location
            var end = location
            while start > 0, isWordCharacter(text.character(at: start - 1)) { start -= 1 }
            while end < length, isWordCharacter(text.character(at: end)) { end += 1 }
            guard end > start else { return NSRange(location: location, length: 0) }
            return NSRange(location: start, length: end - start)
        }
        let end = min(max(NSMaxRange(selection), location), length)
        return NSRange(location: location, length: end - location)
    }

    /// The whole lines the selection touches, line endings included.
    static func lineRange(in text: NSString, selection: NSRange) -> NSRange {
        let length = text.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        let start = min(max(selection.location, 0), length)
        let end = min(max(NSMaxRange(selection), start), length)
        let first = text.lineRange(for: NSRange(location: min(start, length - 1), length: 0))
        let last = end > start
            ? text.lineRange(for: NSRange(location: max(start, end - 1), length: 0))
            : first
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }

    // MARK: - Pieces

    private struct LineParts {
        let indent: String
        let kind: NotesMarkdownList?
        let quoted: Bool
        let content: String
    }

    private static func toggleWrap(_ marker: String, in text: String,
                                   selection: NSRange) -> NotesMarkdownChange? {
        let text = text as NSString
        let range = effectiveRange(in: text, selection: selection)
        let length = (marker as NSString).length
        // Already wrapped inside the selection.
        if range.length >= 2 * length {
            let selected = text.substring(with: range) as NSString
            if selected.hasPrefix(marker), selected.hasSuffix(marker) {
                let inner = NSRange(location: range.location + length,
                                    length: range.length - 2 * length)
                let content = text.substring(with: inner)
                return NotesMarkdownChange(
                    range: range, replacement: content,
                    selection: NSRange(location: range.location,
                                       length: (content as NSString).length)
                )
            }
        }
        // Markers just outside the selection.
        if range.location >= length, NSMaxRange(range) + length <= text.length {
            let before = text.substring(with: NSRange(location: range.location - length,
                                                      length: length))
            let after = text.substring(with: NSRange(location: NSMaxRange(range),
                                                     length: length))
            if before == marker, after == marker {
                // A single `*` next to a `**` would break a bold marker.
                let startsBold = marker == "*" && range.location >= 2
                    && text.substring(with: NSRange(location: range.location - 2, length: 2)) == "**"
                let endsBold = marker == "*" && NSMaxRange(range) + 2 <= text.length
                    && text.substring(with: NSRange(location: NSMaxRange(range), length: 2)) == "**"
                if startsBold == false, endsBold == false {
                    let full = NSRange(location: range.location - length,
                                       length: range.length + 2 * length)
                    let content = text.substring(with: range)
                    return NotesMarkdownChange(
                        range: full, replacement: content,
                        selection: NSRange(location: full.location,
                                           length: (content as NSString).length)
                    )
                }
            }
        }
        let content = text.substring(with: range)
        let replacement = marker + content + marker
        let selectionAfter = range.length == 0
            ? NSRange(location: range.location + length, length: 0)
            : NSRange(location: range.location + length,
                      length: (content as NSString).length)
        return NotesMarkdownChange(range: range, replacement: replacement,
                                   selection: selectionAfter)
    }

    private static func blockChange(range: NSRange, replacement: String) -> NotesMarkdownChange {
        NotesMarkdownChange(range: range, replacement: replacement,
                            selection: NSRange(location: range.location,
                                               length: (replacement as NSString).length))
    }

    /// `[label](url)` around the range, when the range sits inside one.
    private static func enclosingLink(in text: NSString, around range: NSRange) -> NSRange? {
        guard text.length > 0 else { return nil }
        var open = min(range.location, text.length)
        while open > 0 {
            let character = text.character(at: open - 1)
            if character == 0x0A { return nil }
            if character == 0x5B { break }
            open -= 1
        }
        guard open > 0, text.character(at: open - 1) == 0x5B else { return nil }
        let bracket = open - 1
        // The label closes at the first "]" after the "["; the selection may be
        // in the label or in the url that follows it.
        var close = bracket + 1
        while close < text.length,
              text.character(at: close) != 0x5D, text.character(at: close) != 0x0A {
            close += 1
        }
        guard close < text.length, text.character(at: close) == 0x5D,
              close + 1 < text.length, text.character(at: close + 1) == 0x28 else { return nil }
        var end = close + 2
        while end < text.length,
              text.character(at: end) != 0x29, text.character(at: end) != 0x0A {
            end += 1
        }
        guard end < text.length, text.character(at: end) == 0x29 else { return nil }
        guard range.location >= bracket, NSMaxRange(range) <= end + 1 else { return nil }
        return NSRange(location: bracket, length: end + 1 - bracket)
    }

    private static func isWordCharacter(_ character: unichar) -> Bool {
        if character >= 0x30, character <= 0x39 { return true }
        if character >= 0x41, character <= 0x5A { return true }
        if character >= 0x61, character <= 0x7A { return true }
        return character == 0x5F
    }

    private static func isSeparator(_ cell: String) -> Bool {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        var core = trimmed
        if core.hasPrefix(":") { core.removeFirst() }
        if core.hasSuffix(":") { core.removeLast() }
        return core.isEmpty == false && core.allSatisfy { $0 == "-" }
    }

    private static func lineRanges(of block: NSRange, in text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = block.location
        while location < NSMaxRange(block) {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            ranges.append(line)
            let next = NSMaxRange(line)
            guard next > location else { break }
            location = next
        }
        return ranges
    }

    private static func splitEnding(_ raw: String) -> (body: String, ending: String) {
        var end = raw.endIndex
        while end > raw.startIndex {
            let before = raw.index(before: end)
            let character = raw[before]
            if character == "\n" || character == "\r" { end = before } else { break }
        }
        return (String(raw[..<end]), String(raw[end...]))
    }

    /// The indentation, a list marker if there is one, a quote marker, and the
    /// rest of the line. The markers are recognised so switching between list
    /// kinds replaces them instead of stacking.
    private static func parse(_ body: String) -> LineParts {
        let text = body as NSString
        var index = 0
        while index < text.length {
            let character = text.character(at: index)
            if character == 0x20 || character == 0x09 { index += 1 } else { break }
        }
        let indent = text.substring(to: index)
        var quoted = false
        var cursor = index
        if cursor + 1 < text.length,
           text.character(at: cursor) == 0x3E, text.character(at: cursor + 1) == 0x20 {
            quoted = true
            cursor += 2
        }
        var kind: NotesMarkdownList?
        // "- [ ] " and "- [x] ".
        if cursor + 5 < text.length,
           text.character(at: cursor) == 0x2D || text.character(at: cursor) == 0x2A,
           text.character(at: cursor + 1) == 0x20,
           text.character(at: cursor + 2) == 0x5B,
           text.character(at: cursor + 4) == 0x5D,
           text.character(at: cursor + 5) == 0x20 {
            let mark = text.character(at: cursor + 3)
            if mark == 0x20 || mark == 0x78 || mark == 0x58 {
                kind = .checkbox
                cursor += 6
            }
        }
        // "- ", "* " and "+ ".
        if kind == nil, cursor + 1 < text.length,
           [0x2D, 0x2A, 0x2B].contains(text.character(at: cursor)),
           text.character(at: cursor + 1) == 0x20 {
            kind = .bullet
            cursor += 2
        }
        // "1. " and "1) ".
        if kind == nil {
            var digits = cursor
            while digits < text.length, (0x30...0x39).contains(text.character(at: digits)) {
                digits += 1
            }
            if digits > cursor, digits + 1 < text.length,
               text.character(at: digits) == 0x2E || text.character(at: digits) == 0x29,
               text.character(at: digits + 1) == 0x20 {
                kind = .numbered
                cursor = digits + 2
            }
        }
        return LineParts(indent: indent, kind: kind, quoted: quoted,
                         content: text.substring(from: cursor))
    }
}
