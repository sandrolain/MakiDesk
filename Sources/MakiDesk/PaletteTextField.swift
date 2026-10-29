import AppKit
import SwiftUI

/// An `NSTextField` for the panels that take a query (T38, T37).
///
/// It reports the keys a list needs while the field keeps the keyboard: the
/// arrows, Tab, Return, Escape. Return says whether Command was held, which is
/// how the application launcher tells "open" from "open another instance".
struct PaletteTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var fontSize: CGFloat = 18
    let onSubmit: (Bool) -> Void
    let onCancel: () -> Void
    let onMove: (Int) -> Void
    var onTab: () -> Void = {}

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = NSColor(WorkspaceStore.shared.theme.text)
        field.placeholderString = placeholder
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        context.coordinator.field = field
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        if nsView.currentEditor() == nil, nsView.window?.firstResponder !== nsView.currentEditor() {
            DispatchQueue.main.async {
                guard nsView.window?.firstResponder !== nsView.currentEditor() else { return }
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onCancel: onCancel,
                    onMove: onMove, onTab: onTab)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        weak var field: NSTextField?
        private let text: Binding<String>
        private let onSubmit: (Bool) -> Void
        private let onCancel: () -> Void
        private let onMove: (Int) -> Void
        private let onTab: () -> Void

        init(text: Binding<String>, onSubmit: @escaping (Bool) -> Void,
             onCancel: @escaping () -> Void, onMove: @escaping (Int) -> Void,
             onTab: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
            self.onMove = onMove
            self.onTab = onTab
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                onMove(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                onMove(1)
                return true
            case #selector(NSResponder.insertTab(_:)):
                onTab()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                let commandHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
                onSubmit(commandHeld)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
                return true
            default:
                return false
            }
        }
    }
}
