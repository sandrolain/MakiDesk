import AppKit
import MakiTerminalCore

/// The helper's find bar (F3 L2): one per pane, shown over the top-right corner
/// while a search session is open.
///
/// Ghostty does the matching; this view only collects the needle, shows the
/// match count and forwards next/previous/close. It stays a plain AppKit view so
/// the helper keeps its single window-controller structure.
final class TerminalFindBar: NSView, NSSearchFieldDelegate {
    var onNeedleChange: ((String) -> Void)?
    var onNavigate: ((TerminalSearchNavigation) -> Void)?
    var onClose: (() -> Void)?

    private let field = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()
    private var state = TerminalSearchState()

    var needle: String { field.stringValue }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = "Find"
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.delegate = self
        field.focusRingType = .none

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.alignment = .right

        configure(previousButton, symbol: "chevron.up", label: "Previous match")
        configure(nextButton, symbol: "chevron.down", label: "Next match")
        configure(closeButton, symbol: "xmark", label: "Close find bar")
        previousButton.target = self
        previousButton.action = #selector(previousAction(_:))
        nextButton.target = self
        nextButton.action = #selector(nextAction(_:))
        closeButton.target = self
        closeButton.action = #selector(closeAction(_:))

        let stack = NSStackView(views: [previousButton, field, countLabel,
                                        nextButton, closeButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(equalToConstant: 160),
            field.heightAnchor.constraint(equalToConstant: 22),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
            widthAnchor.constraint(equalToConstant: 360),
            heightAnchor.constraint(equalToConstant: 32),
        ])
        apply(theme: .fallback)
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    // MARK: - State

    func begin(needle: String) {
        field.stringValue = needle
        state = TerminalSearchState(needle: needle)
        updateCount()
        isHidden = false
        focus()
    }

    func finish() {
        isHidden = true
    }

    func apply(_ newState: TerminalSearchState) {
        state = newState
        updateCount()
    }

    func applyTotal(_ total: Int?) {
        state.apply(total: total)
        updateCount()
    }

    func applySelected(_ selected: Int?) {
        state.apply(selected: selected)
        updateCount()
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.utf16.count,
                                                       length: 0)
    }

    func apply(theme: TerminalUITheme) {
        layer?.backgroundColor = theme.surface.cgColor
        layer?.borderColor = theme.border.cgColor
        countLabel.textColor = theme.subtext
        field.textColor = theme.text
        let placeholder = NSAttributedString(
            string: "Find",
            attributes: [.foregroundColor: theme.subtext]
        )
        field.placeholderAttributedString = placeholder
        for button in [previousButton, nextButton, closeButton] {
            button.contentTintColor = theme.subtext
        }
    }

    private func updateCount() {
        countLabel.stringValue = state.countText
        let enabled = state.hasResults
        previousButton.isEnabled = enabled
        nextButton.isEnabled = enabled
    }

    private func configure(_ button: NSButton, symbol: String, label: String) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .inline
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.toolTip = label
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
    }

    // MARK: - Actions

    @objc private func previousAction(_ sender: Any?) {
        onNavigate?(.previous)
    }

    @objc private func nextAction(_ sender: Any?) {
        onNavigate?(.next)
    }

    @objc private func closeAction(_ sender: Any?) {
        onClose?()
    }

    // MARK: - Field delegate

    func controlTextDidChange(_ notification: Notification) {
        // The count belongs to the previous needle until Ghostty answers for
        // the new one; drop it rather than show a stale number.
        state = TerminalSearchState(needle: field.stringValue)
        updateCount()
        onNeedleChange?(field.stringValue)
    }

    func control(_ control: NSControl,
                 textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            onNavigate?(backwards ? .previous : .next)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
