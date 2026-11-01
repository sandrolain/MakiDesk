import Foundation

/// A Markdown table, written once (R05).
///
/// Two functions used to align tables: the formatter, which rewrites a table
/// the user typed and keeps its `:---:` alignment row, and the serializer,
/// which builds one from the rewrite model's output. They computed widths and
/// padding separately and disagreed on the measure — one counted UTF-16 units,
/// the other grapheme clusters — so a row holding an emoji came out a column
/// off. Only the layout lives here; what goes *into* a cell is the caller's
/// business, because the model's output needs cleaning and the user's text does
/// not.
enum NotesMarkdownTable {
    /// Renders `rows`, the first one being the header. `alignments` is the
    /// separator row the table already had, if any: it is preserved cell by
    /// cell, and an empty one means plain `---` in every column.
    ///
    /// Returns `nil` when there is nothing to render.
    static func render(rows: [[String]], alignments: [String] = []) -> String? {
        guard rows.isEmpty == false else { return nil }
        let columns = max(rows.map(\.count).max() ?? 0, alignments.count)
        guard columns > 0 else { return nil }

        // Three at least: `---` is the shortest separator Markdown takes.
        var widths = Array(repeating: 3, count: columns)
        for row in rows {
            for (column, cell) in row.enumerated() where column < columns {
                widths[column] = max(widths[column], width(of: cell))
            }
        }

        func line(_ cells: [String]) -> String {
            var output = "|"
            for column in 0..<columns {
                let cell = column < cells.count ? cells[column] : ""
                output += " " + padded(cell, to: widths[column]) + " |"
            }
            return output
        }

        var lines: [String] = [line(rows[0])]
        var header = "|"
        for column in 0..<columns {
            header += " " + separator(column: column, width: widths[column],
                                      alignment: column < alignments.count
                                          ? alignments[column] : "---") + " |"
        }
        lines.append(header)
        for cells in rows.dropFirst() { lines.append(line(cells)) }
        return lines.joined(separator: "\n")
    }

    /// UTF-16 units, the same measure the formatter has always used: a table is
    /// source text, and the source is counted the way the editor's ranges are.
    static func width(of cell: String) -> Int {
        (cell as NSString).length
    }

    static func padded(_ cell: String, to columnWidth: Int) -> String {
        cell + String(repeating: " ", count: max(0, columnWidth - width(of: cell)))
    }

    /// A separator cell that keeps the alignment the table already had.
    static func separator(column: Int, width columnWidth: Int, alignment: String) -> String {
        let left = alignment.hasPrefix(":")
        let right = alignment.hasSuffix(":")
        let dashes: Int
        if left && right {
            dashes = max(1, columnWidth - 2)
        } else if left || right {
            dashes = max(2, columnWidth - 1)
        } else {
            dashes = columnWidth
        }
        let marker = String(repeating: "-", count: dashes)
        if left && right { return ":" + marker + ":" }
        if left { return ":" + marker }
        if right { return marker + ":" }
        return marker
    }
}
