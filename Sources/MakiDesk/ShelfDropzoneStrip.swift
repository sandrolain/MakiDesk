import AppKit

/// The row of dropzone tiles shown inside the shelf while something is being
/// dragged. It is a passive view: it draws what the coordinator loaded, reports
/// which tile is under a point and lets the controller decide whether the drop
/// is accepted.
final class ShelfDropzoneStripView: NSView {
    static let preferredHeight: CGFloat = 100

    private static let tileSize = NSSize(width: 88, height: 88)
    private static let spacing: CGFloat = 4
    private static let padding: CGFloat = 6

    private let scrollView = NSScrollView()
    private let content = NSView()
    private let emptyLabel = NSTextField(labelWithString: "No dropzone accepts these items")
    private var tiles: [ShelfDropzoneTileView] = []
    private var zones: [DropzoneConfig] = []
    private var compatibility: [UUID: Bool] = [:]
    private var hovered: UUID?
    private var theme = PaletteTheme.all[0]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.borderType = .noBorder
        scrollView.documentView = content
        addSubview(scrollView)
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.isHidden = true
        addSubview(emptyLabel)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Dropzones")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Rebuilds the tiles from the enabled zones, keeping the hover if it still
    /// exists.
    func update(zones: [DropzoneConfig], theme: PaletteTheme) {
        guard zones != self.zones || theme != self.theme else { return }
        self.zones = zones
        self.theme = theme
        rebuild()
    }

    func applyTheme(_ theme: PaletteTheme) {
        self.theme = theme
        emptyLabel.textColor = NSColor(theme.subtext)
        for tile in tiles { tile.applyTheme(theme) }
        needsDisplay = true
    }

    /// `true` when the zone accepts what is being dragged; unknown zones stay
    /// active (best effort during the drag).
    func setCompatibility(_ map: [UUID: Bool]) {
        compatibility = map
        for tile in tiles {
            let compatible = map[tile.zone.id] ?? true
            tile.isDimmed = compatible == false
            // Incompatible zones disappear from the strip: the drop has no
            // valid target, and a dimmed tile still looked selectable.
            tile.isHidden = compatible == false
        }
        // The layout only arranges visible tiles, so hiding a zone removes its
        // slot instead of leaving a hole.
        needsLayout = true
        updateEmptyState()
        setAccessibilityChildren(tiles.filter { $0.isHidden == false })
        if let hovered, map[hovered] == false { setHovered(nil) }
    }

    func setHovered(_ id: UUID?) {
        guard hovered != id else { return }
        hovered = id
        for tile in tiles {
            tile.isHovered = tile.zone.id == id
        }
    }

    func isZoneCompatible(_ id: UUID) -> Bool {
        compatibility[id] ?? true
    }

    var zoneCount: Int { zones.count }
    /// Zones currently drawn as valid targets.
    var visibleZoneCount: Int { tiles.filter { $0.isHidden == false }.count }

    /// A new drag starts at the left edge, even if the previous one scrolled
    /// the strip to reach the last zones.
    func scrollToLeading() {
        let origin = scrollView.contentView.bounds.origin
        guard origin.x != 0 || origin.y != 0 else { return }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// The tile under `point`, which is in this view's coordinates. Hidden
    /// (incompatible) tiles keep their slot but never match.
    func zone(at point: NSPoint) -> DropzoneConfig? {
        let local = content.convert(point, from: self)
        return tiles.first { $0.isHidden == false && $0.frame.contains(local) }?.zone
    }

    private func rebuild() {
        for tile in tiles { tile.removeFromSuperview() }
        tiles = []
        hovered = nil
        for zone in zones {
            let tile = ShelfDropzoneTileView(zone: zone, theme: theme)
            let compatible = compatibility[zone.id] ?? true
            tile.isDimmed = compatible == false
            tile.isHidden = compatible == false
            content.addSubview(tile)
            tiles.append(tile)
        }
        updateEmptyState()
        setAccessibilityChildren(tiles.filter { $0.isHidden == false })
        needsLayout = true
        needsDisplay = true
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = tiles.isEmpty || tiles.contains { $0.isHidden == false }
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let visible = tiles.filter { $0.isHidden == false }
        let count = CGFloat(visible.count)
        let needed = Self.padding * 2 + count * Self.tileSize.width
            + max(0, count - 1) * Self.spacing
        let width = max(bounds.width, needed)
        content.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        let y = (bounds.height - Self.tileSize.height) / 2
        var x = Self.padding
        for tile in visible {
            tile.frame = NSRect(x: x, y: y, width: Self.tileSize.width, height: Self.tileSize.height)
            x += Self.tileSize.width + Self.spacing
        }
        emptyLabel.frame = NSRect(x: 12, y: (bounds.height - 32) / 2,
                                  width: max(0, bounds.width - 24), height: 32)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(theme.border).withAlphaComponent(0.5).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

/// One tile: icon, two-line name, hover ring. It is not clickable; the drop is
/// the interaction, so it exposes a group with its name for assistive tools.
final class ShelfDropzoneTileView: NSView {
    let zone: DropzoneConfig

    private let iconView = NSImageView()
    private let emojiLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private var theme: PaletteTheme

    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
        }
    }

    var isDimmed = false {
        didSet {
            guard isDimmed != oldValue else { return }
            alphaValue = isDimmed ? 0.45 : 1
        }
    }

    init(zone: DropzoneConfig, theme: PaletteTheme) {
        self.zone = zone
        self.theme = theme
        super.init(frame: .zero)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.imageAlignment = .alignCenter
        emojiLabel.alignment = .center
        emojiLabel.font = .systemFont(ofSize: 26)
        emojiLabel.drawsBackground = false
        emojiLabel.isBezeled = false
        emojiLabel.isEditable = false
        emojiLabel.isSelectable = false
        nameLabel.alignment = .center
        nameLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        nameLabel.maximumNumberOfLines = 2
        nameLabel.lineBreakMode = .byWordWrapping
        nameLabel.cell?.wraps = true
        nameLabel.cell?.isScrollable = false
        nameLabel.drawsBackground = false
        nameLabel.isBezeled = false
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        for view in [iconView, emojiLabel, nameLabel] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        nameLabel.stringValue = zone.name.isEmpty ? "Dropzone" : zone.name
        configureIcon()
        applyTheme(theme)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(nameLabel.stringValue)
        toolTip = zone.name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyTheme(_ theme: PaletteTheme) {
        self.theme = theme
        nameLabel.textColor = NSColor(theme.text)
        iconView.contentTintColor = NSColor(theme.text)
        needsDisplay = true
    }

    private func configureIcon() {
        switch zone.icon {
        case let .symbol(name):
            iconView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            iconView.isHidden = false
            emojiLabel.isHidden = true
        case let .emoji(value):
            iconView.image = nil
            iconView.isHidden = true
            emojiLabel.isHidden = false
            emojiLabel.stringValue = value
        case let .file(relative):
            let url = DropzoneStore.defaultFileURL
                .deletingLastPathComponent()
                .appendingPathComponent("DropzoneIcons", isDirectory: true)
                .appendingPathComponent(relative)
            if let image = NSImage(contentsOf: url) {
                iconView.image = image
                iconView.isHidden = false
            } else {
                iconView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
                iconView.isHidden = false
            }
            emojiLabel.isHidden = true
        }
    }

    override func layout() {
        super.layout()
        // Center the icon and the actual (one- or two-line) name as one block,
        // instead of anchoring the icon to the top and the label to the bottom.
        let icon = NSSize(width: 32, height: 32)
        let gap: CGFloat = 6
        let textWidth = max(0, bounds.width - 8)
        let fitting = nameLabel.sizeThatFits(NSSize(width: textWidth, height: 40))
        let nameHeight = min(max(fitting.height, 14), 34)
        let groupHeight = icon.height + gap + nameHeight
        let groupBottom = max(4, (bounds.height - groupHeight) / 2)
        nameLabel.frame = NSRect(x: 4, y: groupBottom, width: textWidth, height: nameHeight)
        let iconY = groupBottom + nameHeight + gap
        iconView.frame = NSRect(x: (bounds.width - icon.width) / 2, y: iconY,
                                width: icon.width, height: icon.height)
        emojiLabel.frame = iconView.frame
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 11, yRadius: 11)
        let fill = isHovered ? NSColor(theme.surfaceSelected) : NSColor(theme.surface)
        fill.withAlphaComponent(isHovered ? 0.95 : 0.55).setFill()
        path.fill()
        let stroke = isHovered ? NSColor(theme.accent) : NSColor(theme.border)
        stroke.withAlphaComponent(isHovered ? 1 : 0.6).setStroke()
        path.lineWidth = isHovered ? 2 : 1
        path.stroke()
    }
}
