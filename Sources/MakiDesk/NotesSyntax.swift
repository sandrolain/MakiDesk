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

    /// The colour a tree-sitter capture name maps to. Capture names nest
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

/// Builds — and caches — the tree-sitter configuration of a language: the
/// parser from its SwiftPM product and the `highlights.scm` query compiled
/// into the app (see `NotesGrammarQueries`).
enum NotesGrammar {
    private static var cache: [NotesLanguage: LanguageConfiguration] = [:]

    static func configuration(for language: NotesLanguage) -> LanguageConfiguration? {
        if let cached = cache[language] { return cached }
        guard let (parser, query) = rawConfiguration(for: language) else { return nil }
        let tsLanguage = Language(parser())
        guard let compiled = try? Query(language: tsLanguage, data: Data(query.utf8)) else { return nil }
        let configuration = LanguageConfiguration(tsLanguage, name: language.label,
                                                  queries: [.highlights: compiled])
        cache[language] = configuration
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


/// Applies tree-sitter highlighting to an `NSTextView`.
///
/// The original plan named Neon for this layer, but Neon's `TreeSitterClient`
/// no longer compiles with the current Swift toolchain (it calls a main-actor
/// initializer from a nonisolated context). The work it did for us is small:
/// parse the buffer, run the `highlights.scm` query, paint the captures. Doing
/// it here keeps the same tree-sitter engine with one dependency fewer — and
/// the highlighting is a debounced whole-document pass, which is the right
/// trade-off for notes rather than for a code editor.
@MainActor
final class NotesHighlighter {
    /// Above this size a note stays plain: a full parse on every pause would
    /// cost more than the colour is worth.
    static let maximumLength = 300_000

    private weak var textView: NSTextView?
    private let configuration: LanguageConfiguration
    private let query: Query
    private let parser = Parser()
    private var theme: NotesSyntaxTheme
    private var baseAttributes: [NSAttributedString.Key: Any]
    private var work: DispatchWorkItem?
    private let italicFont: NSFont?
    private let boldFont: NSFont?

    init?(textView: NSTextView, language: NotesLanguage, theme: NotesSyntaxTheme,
          baseAttributes: [NSAttributedString.Key: Any]) {
        guard let configuration = NotesGrammar.configuration(for: language),
              let query = configuration.queries[.highlights] else { return nil }
        self.textView = textView
        self.configuration = configuration
        self.query = query
        self.theme = theme
        self.baseAttributes = baseAttributes
        guard (try? parser.setLanguage(configuration.language)) != nil else { return nil }
        let font = baseAttributes[.font] as? NSFont
        italicFont = font.flatMap { NSFontManager.shared.convert($0, toHaveTrait: .italicFontMask) }
        boldFont = font.flatMap { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) }
    }

    func update(theme: NotesSyntaxTheme, baseAttributes: [NSAttributedString.Key: Any]) {
        self.theme = theme
        self.baseAttributes = baseAttributes
        apply()
    }

    /// Called on every edit: the pass runs when the typing pauses.
    func schedule() {
        work?.cancel()
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
        guard let textView, let storage = textView.textStorage else { return }
        let string = textView.string
        guard string.utf16.count <= Self.maximumLength, string.isEmpty == false else {
            clearStyles()
            return
        }
        guard let tree = parser.parse(string) else { return }

        // Collect before touching the storage: the cursor walks the tree, and
        // an attribute edit in the middle would only add work.
        var captures: [(name: String, range: NSRange)] = []
        for match in query.execute(in: tree) {
            for capture in match.captures {
                guard let name = capture.name else { continue }
                captures.append((name, capture.node.range))
            }
        }

        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: whole)
        for capture in captures {
            guard let color = theme.color(forCapture: capture.name) else { continue }
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if capture.name.contains("comment") || capture.name.contains("emphasis") {
                if let italicFont { attributes[.font] = italicFont }
            } else if capture.name.contains("keyword") || capture.name.contains("title")
                        || capture.name.contains("strong") || capture.name.contains("heading") {
                if let boldFont { attributes[.font] = boldFont }
            }
            storage.addAttributes(attributes, range: capture.range)
        }
        storage.endEditing()
        textView.typingAttributes = baseAttributes
        textView.needsDisplay = true
    }

    private func clearStyles() {
        guard let textView, let storage = textView.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: whole)
        storage.endEditing()
        textView.typingAttributes = baseAttributes
    }
}
