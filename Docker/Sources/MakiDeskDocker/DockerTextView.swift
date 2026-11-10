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
        textView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
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
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textView.textColor = colour
        textView.font = font
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: colour,
        ]
        if context.coordinator.theme != theme {
            context.coordinator.theme = theme
            let whole = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
            textView.textStorage?.setAttributes(attributes, range: whole)
        }
        let previous = textView.string
        if previous != text {
            // Logs only grow while their buffer is below the limit; append the
            // new suffix instead of rebuilding a 20k-line string on every tick.
            if previous.isEmpty == false, text.hasPrefix(previous),
               let storage = textView.textStorage {
                let suffix = String(text.dropFirst(previous.count))
                storage.append(NSAttributedString(string: suffix, attributes: attributes))
            } else {
                textView.string = text
                textView.font = font
                textView.textColor = colour
                let whole = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
                textView.textStorage?.setAttributes(attributes, range: whole)
            }
            if followsOutput {
                textView.scrollToEndOfDocument(nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var textView: NSTextView?
        var theme: DockerUITheme?
    }
}
