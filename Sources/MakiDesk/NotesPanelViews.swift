import AppKit

/// The note panel's views: the drop target, the split with its divider, the
/// toolbar buttons and one row of the notes table (R05).
///
/// They lived in `NotesPanel.swift` beside the controller, which made a
/// 1.734-line file look monolithic when it was ten types. These five are leaf
/// views: nothing depends on their internals, so moving them costs no
/// visibility at all.

/// Accepts files dropped anywhere on the panel and opens them as notes.
@MainActor
final class NotesDropView: NSView {
    var onFiles: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func urls(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        return sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = urls(from: sender)
        guard urls.isEmpty == false else { return false }
        onFiles?(urls)
        return true
    }
}

/// A two-pane split with a fixed sidebar and a draggable divider. `NSSplitView`
/// kept ignoring its own divider position once the panes used Auto Layout, so
/// this small view does the one thing the notes panel needs: a remembered
/// sidebar width and a divider the user can drag (T20).
@MainActor
final class NotesSplitView: NSView {
    static let minimumSidebar: CGFloat = 190
    static let maximumSidebar: CGFloat = 360
    private static let defaultSidebar: CGFloat = 230

    var dividerColor: NSColor = .separatorColor {
        didSet { divider.lineColor = dividerColor }
    }

    private let divider = DividerView()
    private let sidebarHolder = NSView()
    private let detailHolder = NSView()
    private var sidebarWidth: NSLayoutConstraint!
    private var width: CGFloat = NotesSplitView.defaultSidebar

    init() {
        super.init(frame: .zero)
        let saved = Settings.double(.notesSidebarWidth)
        if saved >= Double(Self.minimumSidebar), saved <= Double(Self.maximumSidebar) {
            width = CGFloat(saved)
        }
        divider.lineColor = dividerColor
        divider.onDrag = { [weak self] delta in self?.drag(by: delta) }
        divider.onEnd = { [weak self] in
            guard let self else { return }
            Settings.set(Double(self.width), for: .notesSidebarWidth)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func addSides(sidebar: NSView, detail: NSView) {
        for view in [sidebarHolder, divider, detailHolder] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        detail.translatesAutoresizingMaskIntoConstraints = false
        sidebarHolder.addSubview(sidebar)
        detailHolder.addSubview(detail)

        sidebarWidth = sidebarHolder.widthAnchor.constraint(equalToConstant: width)
        NSLayoutConstraint.activate([
            sidebarHolder.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebarHolder.topAnchor.constraint(equalTo: topAnchor),
            sidebarHolder.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebarWidth,

            divider.leadingAnchor.constraint(equalTo: sidebarHolder.trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 3),

            detailHolder.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            detailHolder.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailHolder.topAnchor.constraint(equalTo: topAnchor),
            detailHolder.bottomAnchor.constraint(equalTo: bottomAnchor),

            sidebar.leadingAnchor.constraint(equalTo: sidebarHolder.leadingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: sidebarHolder.trailingAnchor),
            sidebar.topAnchor.constraint(equalTo: sidebarHolder.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: sidebarHolder.bottomAnchor),

            detail.leadingAnchor.constraint(equalTo: detailHolder.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: detailHolder.trailingAnchor),
            detail.topAnchor.constraint(equalTo: detailHolder.topAnchor),
            detail.bottomAnchor.constraint(equalTo: detailHolder.bottomAnchor),
        ])
    }

    private func drag(by delta: CGFloat) {
        let wanted = min(max(width + delta, Self.minimumSidebar), Self.maximumSidebar)
        guard wanted != width else { return }
        width = wanted
        sidebarWidth.constant = wanted
    }
}

/// The draggable hairline between the list and the editor.
@MainActor
final class DividerView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    var lineColor: NSColor = .separatorColor {
        didSet { needsDisplay = true }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        lineColor.setFill()
        NSRect(x: bounds.midX, y: 0, width: 1, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.deltaX)
    }

    override func mouseUp(with event: NSEvent) {
        onEnd?()
    }
}

/// A small toolbar button: an SF Symbol with a hover background, the way a
/// document toolbar looks in a slim titlebar.
/// A small toolbar button: an SF Symbol above its label, with a hover
/// background. The icon and label are drawn together so the pair stays
/// centred in the bar, the way a native toolbar item does.
@MainActor
final class IconButton: NSButton {
    static let labelFont = NSFont.systemFont(ofSize: 9, weight: .medium)

    var label: String? {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var icon: NSImage? {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private var hovered = false
    private var tracking: NSTrackingArea?
    private var tint: NSColor = .secondaryLabelColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        imagePosition = .imageOnly
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 5
        alignment = .center
        setButtonType(.momentaryChange)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isEnabled: Bool {
        didSet { updateBackground() }
    }

    override var intrinsicContentSize: NSSize {
        guard let label else { return NSSize(width: 24, height: 24) }
        let width = (label as NSString).size(withAttributes: [.font: Self.labelFont]).width
        return NSSize(width: max(34, ceil(width) + 10), height: 40)
    }

    /// The icon and its label share one colour, including the accent used for
    /// the active docking edge.
    func setTint(_ color: NSColor) {
        tint = color
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let icon, let label else { return }
        let tinted = icon.withSymbolConfiguration(.init(paletteColors: [tint])) ?? icon
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.labelFont,
            .foregroundColor: tint,
        ]
        let iconSize = tinted.size
        let labelSize = (label as NSString).size(withAttributes: attributes)
        // A fixed icon slot keeps every icon on the same line even though SF
        // Symbols have different heights; the labels share one baseline at
        // the bottom of the bar.
        let iconSlot: CGFloat = 18
        let gap: CGFloat = 2
        let bottomInset: CGFloat = 4
        let labelY = bounds.height - labelSize.height - bottomInset
        let slotY = labelY - gap - iconSlot
        let iconY = slotY + (iconSlot - iconSize.height) / 2
        // The button is flipped: y grows downwards.
        tinted.draw(in: NSRect(x: floor((bounds.width - iconSize.width) / 2),
                               y: floor(iconY),
                               width: iconSize.width, height: iconSize.height))
        (label as NSString).draw(at: NSPoint(x: floor((bounds.width - labelSize.width) / 2),
                                             y: floor(labelY)),
                                 withAttributes: attributes)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateBackground()
    }

    private func updateBackground() {
        guard isEnabled, hovered else {
            layer?.backgroundColor = NSColor.clear.cgColor
            return
        }
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
    }
}

/// A row of the notes list: title and a one-line detail.
@MainActor
final class NoteCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let dotView = NSView()

    private var onClose: (() -> Void)?
    private var theme: NotesSyntaxTheme?
    private var isCurrent = false
    private var isDirty = false
    private var isHovered = false
    private var tracking: NSTrackingArea?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 10.5)
        detailLabel.lineBreakMode = .byTruncatingTail

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close note")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.focusRingType = .none
        closeButton.refusesFirstResponder = true
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close the note"

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3.5
        dotView.toolTip = "Not saved to the file yet — hover to close"

        for subview in [titleLabel, detailLabel, dotView, closeButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            detailLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),

            dotView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -17),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 7),
            dotView.heightAnchor.constraint(equalToConstant: 7),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, detail: String, theme: NotesSyntaxTheme,
                   isDirty: Bool, isCurrent: Bool,
                   onClose: @escaping () -> Void) {
        self.theme = theme
        self.isDirty = isDirty
        self.isCurrent = isCurrent
        self.onClose = onClose
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        titleLabel.textColor = theme.text
        detailLabel.textColor = theme.subtext
        updateAccessory()
        needsDisplay = true
    }

    /// The open note stays marked even when the panel is not the key window,
    /// so it never blends into the rest of the list.
    override func draw(_ dirtyRect: NSRect) {
        guard isCurrent, let theme else { return }
        // Full-width row: the colour reaches the sidebar edges, the text keeps
        // its own padding.
        theme.accent.withAlphaComponent(0.16).setFill()
        bounds.fill()
        theme.accent.setFill()
        NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAccessory()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAccessory()
    }

    @objc private func closeClicked() {
        let close = onClose
        close?()
    }

    private func updateAccessory() {
        // A changed file shows the dot; hovering turns it into the close
        // button, exactly like a tab would.
        let showsDot = isDirty && isHovered == false
        dotView.isHidden = showsDot == false
        closeButton.isHidden = showsDot
        closeButton.contentTintColor = isHovered ? (theme?.text ?? .labelColor) : (theme?.subtext ?? .secondaryLabelColor)
        dotView.layer?.backgroundColor = NSColor.systemOrange.cgColor
    }
}
