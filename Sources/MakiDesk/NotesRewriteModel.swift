import Foundation

/// What a rewrite is asked to do (T66).
enum NotesRewriteAction: String, CaseIterable, Identifiable, Sendable {
    /// Clearer prose, same meaning and structure.
    case improve
    /// A structured Markdown note: title, sections, lists, tables.
    case format
    /// A short summary followed by the key points.
    case summarize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .improve: return "Improve Wording"
        case .format: return "Format as Markdown"
        case .summarize: return "Summarize"
        }
    }

    var symbol: String {
        switch self {
        case .improve: return "wand.and.stars"
        case .format: return "textformat"
        case .summarize: return "list.bullet.rectangle"
        }
    }

    var menuTitle: String {
        switch self {
        case .improve: return "Improve wording"
        case .format: return "Format as Markdown"
        case .summarize: return "Summarize"
        }
    }
}

/// The structure a rewrite produces, before Markdown (T66).
///
/// The on-device model fills this, and `NotesMarkdownSerializer` turns it into
/// text: the model never writes Markdown markers, so a fence cannot be left
/// open and a table cannot be misaligned.
struct NotesRewriteDraft: Equatable, Sendable {
    struct Section: Equatable, Sendable {
        /// 1…3, mapped to `#`…`###` under the title.
        var level: Int = 2
        var heading: String = ""
        var paragraphs: [String] = []
        var bullets: [String] = []
        /// The first row is the header; the separator is generated.
        var table: [[String]] = []

        var isEmpty: Bool {
            heading.isEmpty && paragraphs.isEmpty && bullets.isEmpty && table.isEmpty
        }
    }

    var title: String = ""
    var summary: String = ""
    var sections: [Section] = []

    var isEmpty: Bool {
        title.isEmpty && summary.isEmpty && sections.allSatisfy(\.isEmpty)
    }
}

/// Renders the structure as Markdown with the same conventions as the editor's
/// commands: `- ` bullets, `##` headings, aligned GFM tables (T65).
enum NotesMarkdownSerializer {
    static func render(_ draft: NotesRewriteDraft, action: NotesRewriteAction) -> String {
        let blocks: [String]
        switch action {
        case .improve:
            var parts: [String] = []
            for section in draft.sections {
                parts += section.paragraphs.map(clean).filter { $0.isEmpty == false }
                let bullets = section.bullets.map(clean).filter { $0.isEmpty == false }
                if bullets.isEmpty == false {
                    parts.append(bullets.map { "- " + $0 }.joined(separator: "\n"))
                }
            }
            if parts.isEmpty, draft.summary.isEmpty == false {
                parts.append(draft.summary)
            }
            blocks = parts
        case .format:
            var parts: [String] = []
            let title = clean(draft.title)
            if title.isEmpty == false { parts.append("# " + title) }
            for section in draft.sections {
                if let body = sectionBody(section, hasTitle: title.isEmpty == false) {
                    parts.append(body)
                }
            }
            blocks = parts
        case .summarize:
            var parts: [String] = []
            if clean(draft.summary).isEmpty == false { parts.append(clean(draft.summary)) }
            let points = draft.sections.flatMap(\.bullets)
                + draft.sections.flatMap(\.paragraphs)
            if points.isEmpty == false {
                parts.append(points.prefix(8).map { "- " + clean($0) }.joined(separator: "\n"))
            }
            blocks = parts
        }
        let text = blocks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: "\n\n")
        return text.isEmpty ? "" : text + "\n"
    }

    /// One aligned GFM table; `rows[0]` is the header.
    static func table(_ rows: [[String]]) -> String? {
        // A model keeps a leading list marker or a stray pipe in a cell: the
        // renderer owns the shape, so the text is cleaned before it gets there.
        NotesMarkdownTable.render(rows: rows.map { $0.map(clean) })
    }

    private static func sectionBody(_ section: NotesRewriteDraft.Section,
                                    hasTitle: Bool) -> String? {
        var blocks: [String] = []
        let heading = clean(section.heading)
        if heading.isEmpty == false {
            let level = min(max(section.level + (hasTitle ? 1 : 0), 1), 6)
            blocks.append(String(repeating: "#", count: level) + " " + heading)
        }
        let paragraphs = section.paragraphs.map(clean).filter { $0.isEmpty == false }
        if paragraphs.isEmpty == false {
            blocks.append(paragraphs.joined(separator: "\n\n"))
        }
        let bullets = section.bullets.map(clean).filter { $0.isEmpty == false }
        if bullets.isEmpty == false {
            blocks.append(bullets.map { "- " + $0 }.joined(separator: "\n"))
        }
        if let table = table(section.table) { blocks.append(table) }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }

    /// Models sometimes keep a leading list marker in a bullet: the renderer
    /// owns the marker, so a stray one is removed instead of doubled.
    private static func clean(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("- ") || value.hasPrefix("* ") {
            value = String(value.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return value
    }
}

/// The instructions and the excerpt handed to the model (T66).
enum NotesRewritePrompt {
    /// About 4k tokens of context: a note longer than this is cut at a line.
    static let maximumCharacters = 6000

    static func source(_ text: String, selection: NSRange) -> String {
        let text = text as NSString
        if selection.length > 0, NSMaxRange(selection) <= text.length {
            return text.substring(with: selection)
        }
        guard text.length > maximumCharacters else { return text as String }
        var end = maximumCharacters
        // Do not cut a surrogate pair in half.
        while end > 0, (text.character(at: end - 1) & 0xFC00) == 0xD800 { end -= 1 }
        let prefix = text.substring(to: end)
        if let lastLine = prefix.lastIndex(of: "\n") { return String(prefix[..<lastLine]) }
        return prefix
    }

    static func instructions(for action: NotesRewriteAction) -> String {
        switch action {
        case .improve:
            return """
            You edit a personal note. Rewrite it so it is clear and concise, keeping the meaning, \
            the language and every list item. Do not add facts, headings, summaries or tags. Put \
            prose in paragraphs and items in bullets. Never write Markdown markers: the fields are \
            plain text.
            """
        case .format:
            return """
            You structure a personal note as Markdown through the schema: a short title, then \
            sections with a level from 1 to 3, a heading, paragraphs, bullets for lists and a table \
            when the note has tabular data (the first row is the header). Keep the language and \
            every fact; never invent content. Do not write Markdown markers in the fields: the \
            title, headings, paragraphs and cells are plain text.
            """
        case .summarize:
            return """
            You summarise a personal note: one short paragraph, then the key points as bullets, at \
            most eight, in the note's own language. Do not add facts. Never write Markdown markers: \
            the fields are plain text.
            """
        }
    }

    static func prompt(for action: NotesRewriteAction, source: String) -> String {
        instructions(for: action) + "\n\nNOTE:\n" + source
    }
}
