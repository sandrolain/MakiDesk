import AppKit

/// The text area of the notes panel: an `NSTextView` on TextKit 1, so the
/// line-number ruler and the syntax highlighting can use the layout manager
/// directly (T20).
@MainActor
final class NotesEditorView: NSView, NSTextViewDelegate, @MainActor NSTextStorageDelegate {
    let scrollView = NSScrollView()
    let textView: NSTextView
    private let ruler: LineNumberRulerView
    private(set) var theme: NotesSyntaxTheme

    var onTextChange: ((String) -> Void)?
    var onSelectionChange: ((NSRange) -> Void)?

    var fontSize: CGFloat = 13 {
        didSet { applyFont() }
    }

    init(theme: NotesSyntaxTheme) {
        self.theme = theme
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let view = NSTextView(frame: .zero, textContainer: container)
        self.textView = view
        self.ruler = LineNumberRulerView(textView: view, theme: theme)
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.background
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.verticalRulerView = ruler
        scrollView.clipsToBounds = true
        ruler.clipsToBounds = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = textView
        ruler.startObserving()

        textView.delegate = self
        textView.textStorage?.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFontPanel = false
        textView.isFieldEditor = false
        textView.drawsBackground = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isAutomaticLinkDetectionEnabled = false

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyTheme(theme)
        applyFont()
    }

    func applyTheme(_ theme: NotesSyntaxTheme) {
        self.theme = theme
        scrollView.backgroundColor = theme.background
        textView.backgroundColor = theme.background
        textView.textColor = theme.text
        textView.insertionPointColor = theme.cursor
        textView.selectedTextAttributes = [.backgroundColor: theme.selection]
        ruler.applyTheme(theme)
        textView.needsDisplay = true
    }

    private var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.defaultTabInterval = fontSize * 2.4
        style.tabStops = []
        style.lineSpacing = 1
        return style
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
         .foregroundColor: theme.text,
         .paragraphStyle: paragraphStyle]
    }

    private func applyFont() {
        let attributes = baseAttributes
        if let storage = textView.textStorage, storage.length > 0 {
            storage.beginEditing()
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }
        textView.typingAttributes = attributes
        textView.needsDisplay = true
        ruler.invalidateLineStarts()
        ruler.needsDisplay = true
    }

    func setText(_ text: String, cursor: Int) {
        let attributes = baseAttributes
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        textView.typingAttributes = attributes
        textView.undoManager?.removeAllActions()
        let length = (text as NSString).length
        let location = min(max(0, cursor), length)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        ruler.invalidateLineStarts()
        ruler.needsDisplay = true
    }

    var text: String { textView.string }

    func caretPosition(at offset: Int) -> (line: Int, column: Int) {
        ruler.caretPosition(at: offset)
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    func scrollToCursor() {
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        ruler.needsDisplay = true
        onTextChange?(textView.string)
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        ruler.recordEdit(text: textStorage.string as NSString, range: editedRange, delta: delta)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        onSelectionChange?(textView.selectedRange())
    }
}

/// Line numbers in the scroll view's vertical ruler. Only logical lines are
/// numbered: a line wrapped by the window does not get a second number.
@MainActor
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var theme: NotesSyntaxTheme
    private var lineStarts: [Int] = [0]
    private var lineStartsDirty = true
    private var observer: NSObjectProtocol?

    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    init(textView: NSTextView, theme: NotesSyntaxTheme) {
        self.textView = textView
        self.theme = theme
        super.init(scrollView: nil, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 38
    }

    /// Called once the ruler is in the scroll view: from then on, scrolling
    /// must repaint the numbers.
    func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView?.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func applyTheme(_ theme: NotesSyntaxTheme) {
        self.theme = theme
        needsDisplay = true
    }

    func invalidateLineStarts() {
        lineStartsDirty = true
        needsDisplay = true
    }

    func recordEdit(text: NSString, range: NSRange, delta: Int) {
        guard !lineStartsDirty else { return }
        guard range.location >= 0, NSMaxRange(range) <= text.length,
              range.length - delta >= 0 else { invalidateLineStarts(); return }
        lineStarts = NotesLineIndex.updating(lineStarts, text: text, editedRange: range, delta: delta)
        updateWidth()
        needsDisplay = true
    }

    private func rebuildLineStartsIfNeeded() {
        guard lineStartsDirty, let textView else { return }
        lineStartsDirty = false
        let string = textView.string as NSString
        var starts: [Int] = [0]
        var index = 0
        while index < string.length {
            let found = string.range(of: "\n", options: [],
                                     range: NSRange(location: index, length: string.length - index))
            if found.location == NSNotFound { break }
            starts.append(found.location + 1)
            index = found.location + 1
        }
        lineStarts = starts

        updateWidth()
    }

        // Reuse the line index built for painting. Previously each keystroke
        // also split the entire document into an array just to size the gutter.
    private func updateWidth() {
        let digits = max(1, String(lineStarts.count).count)
        let width = max(38, CGFloat(digits) * 7 + 20)
        if abs(ruleThickness - width) > 0.5 { ruleThickness = width }
    }

    private func lineNumber(at character: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= character { low = middle } else { high = middle - 1 }
        }
        return low + 1
    }

    func caretPosition(at offset: Int) -> (line: Int, column: Int) {
        rebuildLineStartsIfNeeded()
        let line = lineNumber(at: offset)
        return (line, offset - lineStarts[line - 1] + 1)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let scrollView = scrollView else { return }
        rebuildLineStartsIfNeeded()

        theme.background.setFill()
        bounds.fill()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        separator.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        theme.subtext.withAlphaComponent(0.18).setStroke()
        separator.lineWidth = 1
        separator.stroke()

        // Rulers are not clipped for us: without this the gutter paints its
        // numbers over the toolbar as soon as the text scrolls.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        bounds.intersection(rect).clip()

        let visibleRect = scrollView.contentView.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let inset = textView.textContainerInset.height
        let string = textView.string as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: theme.gutterText,
        ]

        if string.length == 0 {
            // An empty draft still has a line 1.
            let point = convert(NSPoint(x: 0, y: inset), from: textView)
            let label = "1" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: bounds.maxX - size.width - 8, y: point.y),
                       withAttributes: attributes)
            return
        }
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragmentRect, _, _, glyphRange, _ in
            let character = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let startsLine = character == 0 || (character > 0 && string.character(at: character - 1) == 10)
            guard startsLine else { return }
            let point = self.convert(NSPoint(x: 0, y: fragmentRect.minY + inset), from: textView)
            let label = "\(self.lineNumber(at: character))" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: self.bounds.maxX - size.width - 8, y: point.y),
                       withAttributes: attributes)
        }
    }
}
