import AppKit

/// The insertion point and the selection take the theme accent.
///
/// A field with a system-blue caret looks like a different app next to our own
/// colours, and the Notes editor already paints its own; this brings every
/// other editable control — SwiftUI text fields, search fields, the checklist's
/// add field — to the same rule.
///
/// All of them edit through an `NSTextView`: the shared field editor AppKit
/// creates on demand. `NSText.didBeginEditingNotification` is posted by that
/// view, so one hook covers the fields that exist now and the ones built later,
/// without owning them.
@MainActor
final class ThemedTextCursor {
    static let shared = ThemedTextCursor()

    private var observers: [NSObjectProtocol] = []
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSText.didBeginEditingNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Read the object before the isolated block: the notification is
            // not Sendable, the view it carries is a main-actor AppKit type.
            let textView = note.object as? NSTextView
            MainActor.assumeIsolated {
                self?.apply(to: textView)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .makiDeskThemeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyToOpenEditors() }
        })
    }

    /// Applies the theme to one text view: the caret and the selection tint.
    func apply(to textView: NSTextView?) {
        guard let textView else { return }
        let accent = NSColor(WorkspaceStore.shared.theme.accent)
        textView.insertionPointColor = accent
        textView.selectedTextAttributes = [
            .backgroundColor: accent.withAlphaComponent(0.28)
        ]
    }

    /// A theme switch while a field is open: repaint it now instead of at the
    /// next time it begins editing.
    func applyToOpenEditors() {
        for window in NSApp.windows {
            if let editor = window.fieldEditor(false, for: nil) as? NSTextView {
                apply(to: editor)
            }
            guard let content = window.contentView else { continue }
            for textView in Self.textViews(in: content) {
                apply(to: textView)
            }
        }
    }

    private static func textViews(in view: NSView) -> [NSTextView] {
        var found: [NSTextView] = []
        if let textView = view as? NSTextView { found.append(textView) }
        for subview in view.subviews {
            found.append(contentsOf: textViews(in: subview))
        }
        return found
    }
}
