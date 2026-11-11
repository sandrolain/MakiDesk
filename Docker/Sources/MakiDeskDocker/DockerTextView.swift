import AppKit
import SwiftUI

/// A read-only text view for logs and inspect JSON. `NSTextView` is used
/// instead of a SwiftUI `Text` tree so a fast stream does not rebuild a view
/// for every line.
struct DockerTextView: NSViewRepresentable {
    var text: String
    var theme: DockerUITheme
    var followsOutput: Bool = false
    var searchable: Bool = false
    var syntaxHighlighted: Bool = false

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.textColor = NSColor(theme.text)
        textView.insertionPointColor = NSColor(theme.accent)
        textView.string = text
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        let colour = NSColor(theme.text)
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.textColor = colour
        textView.font = font
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: colour,
        ]
        let themeChanged = context.coordinator.theme != theme
        let syntaxModeChanged = context.coordinator.syntaxHighlighted != syntaxHighlighted
        let previous = textView.string
        let textChanged = previous != text
        var didAppend = false
        if textChanged {
            // Logs only grow while their buffer is below the limit; append the
            // new suffix instead of rebuilding a 20k-line string on every tick.
            if syntaxHighlighted == false, previous.isEmpty == false, text.hasPrefix(previous),
               let storage = textView.textStorage {
                let suffix = String(text.dropFirst(previous.count))
                storage.append(NSAttributedString(string: suffix, attributes: attributes))
                didAppend = true
            } else {
                textView.string = text
            }
        }
        if textChanged || themeChanged || syntaxModeChanged {
            context.coordinator.theme = theme
            context.coordinator.syntaxHighlighted = syntaxHighlighted
            let whole = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
            if didAppend == false, whole.length > 0 {
                textView.textStorage?.setAttributes(attributes, range: whole)
            }
            if syntaxHighlighted && (textChanged || themeChanged || syntaxModeChanged) {
                context.coordinator.highlight(text, theme: theme, font: font,
                                              baseAttributes: attributes)
            } else {
                context.coordinator.cancelHighlighting()
            }
        }
        if textChanged {
            if followsOutput {
                textView.scrollToEndOfDocument(nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var textView: NSTextView?
        var theme: DockerUITheme?
        var syntaxHighlighted = false
        private var revision: UInt64 = 0
        private var syntaxWork: DispatchWorkItem?
        private let syntaxQueue = DispatchQueue(label: "com.makidesk.docker-json-syntax",
                                                qos: .userInitiated)

        deinit {
            syntaxWork?.cancel()
        }

        func cancelHighlighting() {
            revision &+= 1
            syntaxWork?.cancel()
            syntaxWork = nil
        }

        func highlight(_ source: String, theme: DockerUITheme, font: NSFont,
                       baseAttributes: [NSAttributedString.Key: Any]) {
            cancelHighlighting()
            guard source.utf16.count <= 300_000 else { return }
            let currentRevision = revision
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let tokens = Self.tokens(in: source)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.revision == currentRevision,
                          self.syntaxHighlighted, let textView = self.textView,
                          textView.string == source, let storage = textView.textStorage else { return }
                    storage.beginEditing()
                    let fullRange = NSRange(location: 0, length: storage.length)
                    if fullRange.length > 0 {
                        storage.setAttributes(baseAttributes, range: fullRange)
                    }
                    for token in tokens {
                        storage.addAttribute(.foregroundColor,
                                             value: Self.color(for: token.kind, theme: theme),
                                             range: token.range)
                    }
                    storage.endEditing()
                }
            }
            syntaxWork = work
            syntaxQueue.async(execute: work)
        }

        private enum TokenKind {
            case key, string, number, literal, punctuation
        }

        private struct Token {
            let range: NSRange
            let kind: TokenKind
        }

        private static func tokens(in source: String) -> [Token] {
            let text = source as NSString
            var tokens: [Token] = []
            var index = 0
            while index < text.length {
                let value = text.character(at: index)
                if value == 0x22 {
                    let start = index
                    index += 1
                    while index < text.length {
                        let character = text.character(at: index)
                        if character == 0x5C {
                            index = min(text.length, index + 2)
                        } else if character == 0x22 {
                            index += 1
                            break
                        } else {
                            index += 1
                        }
                    }
                    var lookahead = index
                    while lookahead < text.length,
                          [0x20, 0x09, 0x0A, 0x0D].contains(text.character(at: lookahead)) {
                        lookahead += 1
                    }
                    let kind: TokenKind = lookahead < text.length
                        && text.character(at: lookahead) == 0x3A ? .key : .string
                    tokens.append(Token(range: NSRange(location: start, length: index - start),
                                        kind: kind))
                } else if [0x7B, 0x7D, 0x5B, 0x5D, 0x3A, 0x2C].contains(value) {
                    tokens.append(Token(range: NSRange(location: index, length: 1),
                                        kind: .punctuation))
                    index += 1
                } else if value == 0x2D || (value >= 0x30 && value <= 0x39) {
                    let start = index
                    index += 1
                    while index < text.length {
                        let character = text.character(at: index)
                        guard (character >= 0x30 && character <= 0x39)
                                || [0x2E, 0x45, 0x65, 0x2B, 0x2D].contains(character) else { break }
                        index += 1
                    }
                    tokens.append(Token(range: NSRange(location: start, length: index - start),
                                        kind: .number))
                } else if (value >= 0x41 && value <= 0x5A)
                            || (value >= 0x61 && value <= 0x7A) {
                    let start = index
                    while index < text.length {
                        let character = text.character(at: index)
                        guard (character >= 0x41 && character <= 0x5A)
                                || (character >= 0x61 && character <= 0x7A) else { break }
                        index += 1
                    }
                    let word = text.substring(with: NSRange(location: start, length: index - start))
                    if ["true", "false", "null"].contains(word) {
                        tokens.append(Token(range: NSRange(location: start, length: index - start),
                                            kind: .literal))
                    }
                } else {
                    index += 1
                }
            }
            return tokens
        }

        private static func color(for kind: TokenKind, theme: DockerUITheme) -> NSColor {
            let dark = theme.isDark
            let hex: String
            switch kind {
            case .key: hex = dark ? "#89DCEB" : "#179299"
            case .string: hex = dark ? "#A6E3A1" : "#40A02B"
            case .number: hex = dark ? "#FAB387" : "#FE640B"
            case .literal: hex = dark ? "#F38BA8" : "#D20F39"
            case .punctuation: return NSColor(theme.subtext)
            }
            return NSColor(hex: hex) ?? NSColor(theme.text)
        }
    }
}
