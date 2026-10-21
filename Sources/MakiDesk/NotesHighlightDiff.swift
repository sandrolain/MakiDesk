import Foundation

struct NotesHighlightCapture: Hashable, Sendable {
    let name: String
    let range: NSRange
}

enum NotesHighlightDiff {
    /// Compare styles after translating old ranges through the text edit.
    /// An insertion near the start must not repaint an unchanged suffix.
    static func changedRanges(oldSource: String?, source: String,
                              old: [NotesHighlightCapture], new: [NotesHighlightCapture]) -> [NSRange] {
        let text = source as NSString
        guard let oldSource else { return text.length == 0 ? [] : [NSRange(location: 0, length: text.length)] }
        let previous = oldSource as NSString
        var prefix = 0
        while prefix < min(previous.length, text.length), previous.character(at: prefix) == text.character(at: prefix) {
            prefix += 1
        }
        if splitsPair(previous, at: prefix) || splitsPair(text, at: prefix) { prefix -= 1 }
        var suffix = 0
        while suffix < min(previous.length, text.length) - prefix,
              previous.character(at: previous.length - suffix - 1) == text.character(at: text.length - suffix - 1) {
            suffix += 1
        }
        while suffix > 0,
              splitsPair(previous, at: previous.length - suffix) || splitsPair(text, at: text.length - suffix) {
            suffix -= 1
        }
        let oldEnd = previous.length - suffix
        let newEnd = text.length - suffix
        let delta = text.length - previous.length
        var dirty = [NSRange(location: prefix, length: newEnd - prefix)]
        let translated: [NotesHighlightCapture] = old.map { capture in
            let range = capture.range
            if NSMaxRange(range) <= prefix { return capture }
            if range.location >= oldEnd {
                return NotesHighlightCapture(name: capture.name,
                    range: NSRange(location: range.location + delta, length: range.length))
            }
            let start = min(range.location, prefix)
            let end = max(newEnd, NSMaxRange(range) + delta)
            let adjusted = NSRange(location: start, length: max(0, end - start))
            dirty.append(adjusted)
            return NotesHighlightCapture(name: capture.name, range: adjusted)
        }
        let oldSet = Set(translated)
        let newSet = Set(new)
        dirty += translated.filter { !newSet.contains($0) }.map(\.range)
        dirty += new.filter { !oldSet.contains($0) }.map(\.range)
        let whole = NSRange(location: 0, length: text.length)
        var merged: [NSRange] = []
        for range in dirty.map({ NSIntersectionRange($0, whole) }).filter({ $0.length > 0 })
            .sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, NSMaxRange(last) >= range.location {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else { merged.append(range) }
        }
        return merged
    }

    private static func splitsPair(_ text: NSString, at index: Int) -> Bool {
        guard index > 0, index < text.length else { return false }
        return (0xD800...0xDBFF).contains(text.character(at: index - 1))
            && (0xDC00...0xDFFF).contains(text.character(at: index))
    }
}
