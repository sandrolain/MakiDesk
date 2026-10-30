import Foundation

/// What Writing Tools must leave alone in a note (T64).
///
/// The editor is a plain-text Markdown note: a fenced code block is not prose,
/// and letting the system rewrite it would mangle an example. This is a pure
/// scan of the text, so the rule can be checked without AppKit.
enum NotesWritingTools {
    /// The fenced code blocks that intersect `range`, as UTF-16 ranges.
    ///
    /// A fence opens on a line with up to three spaces and at least three
    /// backticks or tildes; it closes on a line with the same character, at
    /// least as many of them and nothing else. A fence that never closes runs to
    /// the end of the note, which is what the editor shows anyway.
    static func ignoredRanges(in range: NSRange, of text: String) -> [NSRange] {
        let text = text as NSString
        guard text.length > 0, range.length > 0 || range.location < text.length else { return [] }
        var blocks: [NSRange] = []
        var open: (range: NSRange, marker: unichar, count: Int)?
        var location = 0
        while location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            let content = text.substring(with: line)
            let fence = fence(in: withoutLineEnding(content))
            if let fence {
                if let current = open {
                    let isCloser = fence.marker == current.marker
                        && fence.count >= current.count
                        && fence.rest.trimmingCharacters(in: .whitespaces).isEmpty
                    if isCloser {
                        blocks.append(NSRange(location: current.range.location,
                                              length: NSMaxRange(line) - current.range.location))
                        open = nil
                    }
                } else {
                    open = (line, fence.marker, fence.count)
                }
            }
            let next = NSMaxRange(line)
            guard next > location else { break }
            location = next
        }
        if let current = open {
            blocks.append(NSRange(location: current.range.location,
                                  length: text.length - current.range.location))
        }
        return blocks.compactMap { block in
            let inside = NSIntersectionRange(block, range)
            return inside.length > 0 ? inside : nil
        }
    }

    /// The line without its terminator: a closing fence ends with `\n` inside
    /// the line range, and that is not part of what follows the marker run.
    private static func withoutLineEnding(_ line: String) -> String {
        var text = line
        while let last = text.last, last == "\n" || last == "\r" {
            text.removeLast()
        }
        return text
    }

    /// A fence line, with what follows the marker run (an info string when it
    /// opens, nothing but spaces when it closes).
    private static func fence(in line: String) -> (marker: unichar, count: Int, rest: String)? {
        let characters = Array(line.utf16)
        var index = 0
        var spaces = 0
        while index < characters.count, characters[index] == 0x20, spaces < 4 {
            index += 1
            spaces += 1
        }
        guard spaces <= 3, index < characters.count else { return nil }
        let marker = characters[index]
        guard marker == 0x60 || marker == 0x7E else { return nil }
        var count = 0
        while index < characters.count, characters[index] == marker {
            count += 1
            index += 1
        }
        guard count >= 3 else { return nil }
        let rest = String(decoding: characters[index...], as: UTF16.self)
        return (marker, count, rest)
    }
}
