import AppKit
import SwiftTreeSitter
import TreeSitterSwift
import TreeSitterJSON
import TreeSitterMarkdown
import TreeSitterBash
import TreeSitterPython
import TreeSitterJavaScript
import TreeSitterTypeScript
import TreeSitterHTML
import TreeSitterCSS

/// Colours of the editor, derived from the palette theme so the notes look
/// like the rest of the app (T20).
struct NotesSyntaxTheme {
    let background: NSColor
    let text: NSColor
    let subtext: NSColor
    let accent: NSColor
    let selection: NSColor
    let cursor: NSColor
    let gutter: NSColor
    let gutterText: NSColor

    let comment: NSColor
    let keyword: NSColor
    let string: NSColor
    let number: NSColor
    let function: NSColor
    let type: NSColor
    let constant: NSColor
    let property: NSColor
    let punctuation: NSColor

    init(theme: PaletteTheme) {
        background = NSColor(theme.background)
        text = NSColor(theme.text)
        subtext = NSColor(theme.subtext)
        accent = NSColor(theme.accent)
        selection = NSColor(theme.accent).withAlphaComponent(0.28)
        cursor = NSColor(theme.accent)
        gutter = NSColor(theme.background)
        gutterText = NSColor(theme.subtext).withAlphaComponent(0.65)

        let dark = background.luminance < 0.5
        comment = dark ? NSColor(hex: 0x7F849C) : NSColor(hex: 0x8C8FA1)
        keyword = NSColor(theme.accent)
        string = NSColor(hex: dark ? 0xA6E3A1 : 0x40A02B)
        number = NSColor(hex: dark ? 0xFAB387 : 0xFE640B)
        function = NSColor(hex: dark ? 0x89B4FA : 0x1E66F5)
        type = NSColor(hex: dark ? 0xF9E2AF : 0xDF8E1D)
        constant = NSColor(hex: dark ? 0xF38BA8 : 0xD20F39)
        property = NSColor(hex: dark ? 0x89DCEB : 0x179299)
        punctuation = NSColor(theme.subtext)
    }

    /// The colour a grammar capture name maps to. Capture names nest
    /// (`function.method`, `string.special`, …): the longest known prefix wins.
    func color(forCapture name: String) -> NSColor? {
        if name.contains("comment") { return comment }
        if name.contains("keyword") || name.contains("include") || name.contains("conditional")
            || name.contains("repeat") || name.contains("exception") { return keyword }
        if name.contains("string") || name.contains("character") || name.contains("escape") { return string }
        if name.contains("number") || name.contains("float") || name.contains("integer") { return number }
        if name.contains("function") || name.contains("method") { return function }
        if name.contains("type") || name.contains("class") || name.contains("struct")
            || name.contains("enum") || name.contains("interface") || name.contains("namespace") { return type }
        if name.contains("constant") || name.contains("boolean") || name.contains("builtin") { return constant }
        if name.contains("property") || name.contains("field") || name.contains("attribute") { return property }
        if name.contains("operator") || name.contains("punctuation") || name.contains("bracket")
            || name.contains("delimiter") { return punctuation }
        if name.contains("tag") || name.contains("selector") { return keyword }
        // Markdown: headings, code, links and labels.
        if name.contains("text.title") || name.contains("heading") { return keyword }
        if name.contains("text.literal") { return string }
        if name.contains("text.reference") || name.contains("text.uri") || name.contains("link") { return function }
        if name.contains("label") { return property }
        return nil
    }
}

extension NSColor {
    var luminance: CGFloat {
        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }

    convenience init(hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

/// Builds — and caches — the grammar configuration of a language: the
/// parser from its SwiftPM product and the `highlights.scm` query compiled
/// into the app (see `NotesGrammarQueries`).
enum NotesGrammar {
    /// All access, including first-time query compilation, holds this lock.
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var values: [NotesLanguage: LanguageConfiguration] = [:]
    }
    private static let cache = Cache()

    static func configuration(for language: NotesLanguage) -> LanguageConfiguration? {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let cached = cache.values[language] { return cached }
        guard let (parser, query) = rawConfiguration(for: language) else { return nil }
        let tsLanguage = Language(parser())
        guard let compiled = try? Query(language: tsLanguage, data: Data(query.utf8)) else { return nil }
        let configuration = LanguageConfiguration(tsLanguage, name: language.label,
                                                  queries: [.highlights: compiled])
        cache.values[language] = configuration
        return configuration
    }

    static func supports(_ language: NotesLanguage) -> Bool {
        configuration(for: language) != nil
    }

    private static func rawConfiguration(for language: NotesLanguage) -> (() -> OpaquePointer, String)? {
        switch language {
        case .plain: return nil
        case .swift: return ({ tree_sitter_swift() }, NotesGrammarQueries.swift)
        case .json: return ({ tree_sitter_json() }, NotesGrammarQueries.json)
        case .markdown: return ({ tree_sitter_markdown() }, NotesGrammarQueries.markdown)
        case .bash: return ({ tree_sitter_bash() }, NotesGrammarQueries.bash)
        case .python: return ({ tree_sitter_python() }, NotesGrammarQueries.python)
        case .javascript: return ({ tree_sitter_javascript() }, NotesGrammarQueries.javascript)
        case .typescript: return ({ tree_sitter_typescript() }, NotesGrammarQueries.typescript)
        case .html: return ({ tree_sitter_html() }, NotesGrammarQueries.html)
        case .css: return ({ tree_sitter_css() }, NotesGrammarQueries.css)
        }
    }
}


/// Applies syntax highlighting to an `NSTextView`.
///
/// The highlighter parses the buffer, runs the grammar's highlight query and
/// paints the captures. A debounced whole-document pass is the right trade-off
/// for notes rather than for a code editor.
@MainActor
final class NotesHighlighter {
    /// Above this size a note stays plain: a full parse on every pause would
    /// cost more than the colour is worth.
    static let maximumLength = 300_000

    private weak var textView: NSTextView?
    private let engine: NotesSyntaxEngine
    private let parserQueue = DispatchQueue(label: "com.makidesk.notes-syntax", qos: .userInitiated)
    private var parserWork: DispatchWorkItem?
    private var revision: UInt64 = 0
    private var styledSource: String?
    private var styledCaptures: [NotesHighlightCapture] = []
    private var stylesCleared = false
    private var theme: NotesSyntaxTheme
    private var baseAttributes: [NSAttributedString.Key: Any]
    private var work: DispatchWorkItem?
    private var italicFont: NSFont?
    private var boldFont: NSFont?
    /// Writing Tools shows its own preview: while a session runs, scheduled
    /// passes are dropped so the preview is not re-styled under it (T64).
    private var suspended = false

    init?(textView: NSTextView, language: NotesLanguage, theme: NotesSyntaxTheme,
          baseAttributes: [NSAttributedString.Key: Any]) {
        guard let configuration = NotesGrammar.configuration(for: language),
              let query = configuration.queries[.highlights] else { return nil }
        self.textView = textView
        guard let engine = NotesSyntaxEngine(configuration: configuration, query: query) else { return nil }
        self.engine = engine
        self.theme = theme
        self.baseAttributes = baseAttributes
        let font = baseAttributes[.font] as? NSFont
        italicFont = font.flatMap { NSFontManager.shared.convert($0, toHaveTrait: .italicFontMask) }
        boldFont = font.flatMap { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) }
    }

    func update(theme: NotesSyntaxTheme, baseAttributes: [NSAttributedString.Key: Any]) {
        self.theme = theme
        self.baseAttributes = baseAttributes
        let font = baseAttributes[.font] as? NSFont
        italicFont = font.flatMap { NSFontManager.shared.convert($0, toHaveTrait: .italicFontMask) }
        boldFont = font.flatMap { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) }
        styledSource = nil
        stylesCleared = false
        apply()
    }

    /// Stops colouring while a system Writing Tools session owns the text, and
    /// colours once more when it ends (T64).
    func setSuspended(_ value: Bool) {
        suspended = value
        if value {
            work?.cancel()
            work = nil
            parserWork?.cancel()
        } else {
            apply()
        }
    }

    /// Called on every edit: the pass runs when the typing pauses.
    func schedule() {
        guard suspended == false else { return }
        work?.cancel()
        revision &+= 1
        parserWork?.cancel()
        guard let textView else { return }
        guard textView.string.utf16.count <= Self.maximumLength else {
            clearStyles()
            return
        }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.apply() }
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    func apply() {
        work?.cancel()
        work = nil
        guard let textView, textView.textStorage != nil else { return }
        let string = textView.string
        guard string.utf16.count <= Self.maximumLength, string.isEmpty == false else {
            clearStyles()
            return
        }
        revision &+= 1
        let currentRevision = revision
        let engine = self.engine
        let previous = styledSource
        let previousCaptures = styledCaptures
        parserWork?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let captures = engine.captures(in: string) else { return }
            let ranges = NotesHighlightDiff.changedRanges(oldSource: previous, source: string,
                                                         old: previousCaptures, new: captures)
            let patches = ranges.map { range in
                (range, captures.filter { NSIntersectionRange($0.range, range).length > 0 })
            }
            DispatchQueue.main.async {
                guard let self, self.revision == currentRevision,
                      let textView = self.textView, textView.string == string,
                      let storage = textView.textStorage else { return }
                storage.beginEditing()
                for (range, captures) in patches {
                    storage.setAttributes(self.baseAttributes, range: range)
                    for capture in captures {
                        guard let color = self.theme.color(forCapture: capture.name) else { continue }
                        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
                        if capture.name.contains("comment") || capture.name.contains("emphasis") {
                            if let font = self.italicFont { attributes[.font] = font }
                        } else if ["keyword", "title", "strong", "heading"].contains(where: capture.name.contains) {
                            if let font = self.boldFont { attributes[.font] = font }
                        }
                        storage.addAttributes(attributes, range: NSIntersectionRange(range, capture.range))
                    }
                }
                storage.endEditing()
                self.styledSource = string
                self.styledCaptures = captures
                self.stylesCleared = false
                textView.typingAttributes = self.baseAttributes
            }
        }
        parserWork = task
        parserQueue.async(execute: task)
    }

    private func clearStyles() {
        revision &+= 1
        parserWork?.cancel()
        guard !stylesCleared else { return }
        stylesCleared = true
        styledSource = nil
        styledCaptures.removeAll()
        guard let textView, let storage = textView.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: whole)
        storage.endEditing()
        textView.typingAttributes = baseAttributes
    }

}

/// Parser and trees are accessed exclusively by the highlighter serial queue.
private final class NotesSyntaxEngine: @unchecked Sendable {
    private let query: Query
    private let parser = Parser()
    private var tree: MutableTree?
    private var parsedSource: String?

    init?(configuration: LanguageConfiguration, query: Query) {
        self.query = query
        guard (try? parser.setLanguage(configuration.language)) != nil else { return nil }
    }

    func captures(in source: String) -> [NotesHighlightCapture]? {
        guard let tree = parseIncrementally(source) else { return nil }
        return query.execute(in: tree).flatMap { match in
            match.captures.compactMap { capture in
                capture.name.map { NotesHighlightCapture(name: $0, range: capture.node.range) }
            }
        }
    }

    /// Reuses Tree-sitter's previous tree and edits only the changed span.
    /// Captures are still recollected for the complete document so styling
    /// stays correct when a small edit changes a surrounding syntax node.
    private func parseIncrementally(_ source: String) -> MutableTree? {
        guard let previous = parsedSource, let oldTree = tree else {
            let initial = parser.parse(source)
            parsedSource = source
            tree = initial
            return initial
        }
        if previous == source { return tree }

        let oldString = previous as NSString
        let newString = source as NSString
        let sharedLimit = min(oldString.length, newString.length)
        var prefixLength = 0
        while prefixLength < sharedLimit,
              oldString.character(at: prefixLength) == newString.character(at: prefixLength) {
            prefixLength += 1
        }
        if Self.splitsSurrogatePair(oldString, at: prefixLength)
            || Self.splitsSurrogatePair(newString, at: prefixLength) {
            prefixLength -= 1
        }
        var suffixLength = 0
        while suffixLength < oldString.length - prefixLength,
              suffixLength < newString.length - prefixLength,
              oldString.character(at: oldString.length - suffixLength - 1)
                == newString.character(at: newString.length - suffixLength - 1) {
            suffixLength += 1
        }
        while suffixLength > 0,
              Self.splitsSurrogatePair(oldString, at: oldString.length - suffixLength)
                || Self.splitsSurrogatePair(newString, at: newString.length - suffixLength) {
            suffixLength -= 1
        }

        let oldEnd = oldString.length - suffixLength
        let newEnd = newString.length - suffixLength
        let edit = InputEdit(
            startByte: prefixLength * 2,
            oldEndByte: oldEnd * 2,
            newEndByte: newEnd * 2,
            startPoint: Self.treeSitterPoint(in: oldString, offset: prefixLength),
            oldEndPoint: Self.treeSitterPoint(in: oldString, offset: oldEnd),
            newEndPoint: Self.treeSitterPoint(in: newString, offset: newEnd)
        )
        oldTree.edit(edit)
        guard let updatedTree = parser.parse(tree: oldTree, string: source) else {
            let replacement = parser.parse(source)
            parsedSource = source
            tree = replacement
            return replacement
        }
        parsedSource = source
        tree = updatedTree
        return updatedTree
    }

    private static func treeSitterPoint(in string: NSString, offset: Int) -> Point {
        var row = 0
        var column = 0
        if offset > 0 {
            for index in 0..<offset {
                if string.character(at: index) == 10 {
                    row += 1
                    column = 0
                } else {
                    column += 1
                }
            }
        }
        return Point(row: UInt32(row), column: UInt32(column * 2))
    }

    private static func splitsSurrogatePair(_ string: NSString, at offset: Int) -> Bool {
        guard offset > 0, offset < string.length else { return false }
        let before = string.character(at: offset - 1)
        let after = string.character(at: offset)
        return (0xD800...0xDBFF).contains(before) && (0xDC00...0xDFFF).contains(after)
    }
}
