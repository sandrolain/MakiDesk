import Foundation

/// The shortcut table as Markdown, generated from `ShortcutDefinitions` (S04).
///
/// `docs/USAGE.md` keeps this block between two markers and a test fails when
/// the file and the table disagree, so the list in the guide cannot drift from
/// the keys the app registers. Everything else in that section is prose.
enum ShortcutTableDocument {
    static let beginMarker = "<!-- shortcuts:begin -->"
    static let endMarker = "<!-- shortcuts:end -->"

    /// One row per command, grouped by the section the catalog shows.
    static func markdown() -> String {
        var lines = [beginMarker, ""]
        for section in ShortcutDefinitions.sections {
            guard section.definitions.isEmpty == false else { continue }
            lines.append("**\(section.title)**")
            lines.append("")
            lines.append("| Command | Keys | Where |")
            lines.append("|---|---|---|")
            for row in section.definitions {
                let keys = row.isGlobal ? "`\(row.display)`" : row.display
                let place = row.family?.name ?? "Gesture"
                lines.append("| \(escape(row.title)) | \(keys) | \(place) |")
            }
            lines.append("")
        }
        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    /// The block as it appears in a document, markers included.
    static func block(in text: String) -> String? {
        guard let start = text.range(of: beginMarker),
              let end = text.range(of: endMarker, range: start.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[start.lowerBound..<end.upperBound])
    }

    /// Replaces the block in `url` with the table in force. Throws when the
    /// document has no markers, which means it was never set up for this.
    static func rewrite(fileAt url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let current = block(in: text) else {
            throw DocumentError.missingMarkers
        }
        let updated = text.replacingOccurrences(of: current, with: markdown())
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }

    enum DocumentError: LocalizedError {
        case missingMarkers

        var errorDescription: String? {
            "The document has no \(beginMarker) / \(endMarker) block."
        }
    }

    /// A title's own pipes would end the cell early.
    private static func escape(_ title: String) -> String {
        title.replacingOccurrences(of: "|", with: "\\|")
    }
}
