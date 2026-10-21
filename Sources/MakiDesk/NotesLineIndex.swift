import Foundation

enum NotesLineIndex {
    /// Update only the edited text span; existing line offsets after it shift
    /// by the character delta without rescanning the document's contents.
    static func updating(_ starts: [Int], text: NSString, editedRange: NSRange, delta: Int) -> [Int] {
        let oldEnd = NSMaxRange(editedRange) - delta
        var result = starts.prefix { $0 <= editedRange.location }.map { $0 }
        var location = editedRange.location
        while location < NSMaxRange(editedRange) {
            let found = text.range(of: "\n", range: NSRange(location: location,
                                        length: NSMaxRange(editedRange) - location))
            if found.location == NSNotFound { break }
            result.append(found.location + 1)
            location = found.location + 1
        }
        result += starts.drop(while: { $0 <= oldEnd }).map { $0 + delta }
        return result
    }
}
