import AppKit
import ImageIO
import QuartzCore
import QuickLookUI
import UniformTypeIdentifiers

private enum ShelfTransferPayload: @unchecked Sendable {
    case file(URL)
    case text(String)
    case image(NSImage)
    case link(URL)
}

private struct ShelfTransferRequest: @unchecked Sendable {
    let id: UUID
    let name: String
    let payload: ShelfTransferPayload
    let move: Bool
}

private struct ShelfTransferResult: Sendable {
    let id: UUID
    let error: String?
}

private final class ShelfTransferControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

// MARK: - Item

struct ShelfItem: Identifiable {
    enum Content {
        case file(URL, staged: Bool)
        case text(String)
        case image(NSImage)
        case link(URL)
    }

    let id = UUID()
    let content: Content
    let name: String
    let detail: String
    let icon: NSImage
    var imageWriter: ShelfImageWriter? = nil

    static func file(_ url: URL, staged: Bool = false) -> ShelfItem {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        let isDirectory = values?.isDirectory ?? false
        let detail: String
        if isDirectory {
            detail = "Folder"
        } else if let size = values?.fileSize {
            detail = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        } else {
            detail = "File"
        }
        let icon = ShelfThumbnail.file(url) ?? NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        return ShelfItem(content: .file(url, staged: staged),
                         name: url.lastPathComponent, detail: detail, icon: icon)
    }

    static func text(_ text: String) -> ShelfItem {
        let line = text.split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.trimmingCharacters(in: .whitespaces).isEmpty == false } ?? ""
        let collapsed = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let name = collapsed.isEmpty ? "Text" : String(collapsed.prefix(60))
        let lines = text.components(separatedBy: "\n").count
        let size = text.count == 1 ? "1 character" : "\(text.count) characters"
        let detail = lines > 1 ? "\(lines) lines · \(size)" : size
        let icon = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "Text")
            ?? NSImage()
        return ShelfItem(content: .text(text), name: name, detail: detail, icon: icon)
    }

    static func image(_ image: NSImage) -> ShelfItem {
        let size = image.size
        let detail = size.width > 0 && size.height > 0
            ? "\(Int(size.width)) × \(Int(size.height))"
            : "Image"
        return ShelfItem(content: .image(image), name: "Image", detail: detail,
                         icon: ShelfThumbnail.image(image), imageWriter: ShelfImageWriter(image: image))
    }

    static func link(_ url: URL) -> ShelfItem {
        let name = url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
        let detail = url.absoluteString
        let icon = NSImage(systemSymbolName: "link", accessibilityDescription: "Link")
            ?? NSImage()
        return ShelfItem(content: .link(url), name: String(name.prefix(60)),
                         detail: String(detail.prefix(90)), icon: icon)
    }

    var pasteboardWriter: NSPasteboardWriting? {
        switch content {
        case let .file(url, _):
            return url as NSURL
        case let .text(text):
            return text as NSString
        case let .link(url):
            return url as NSURL
        case .image:
            return imageWriter
        }
    }

    var fileURL: URL? {
        switch content {
        case let .file(url, _): return url
        case let .link(url): return url
        default: return nil
        }
    }

    var text: String? {
        if case let .text(text) = content { return text }
        return nil
    }

    /// A file that was moved or deleted while on the shelf is not draggable
    /// any more (the shelf keeps references, not copies).
    var isAvailable: Bool {
        if case let .file(url, _) = content {
            return FileManager.default.fileExists(atPath: url.path)
        }
        return true
    }

    var dedupeKey: String? {
        switch content {
        case let .file(url, _): return "file:" + url.standardizedFileURL.path
        case let .text(text): return "text:" + text
        case let .link(url): return "link:" + url.absoluteString
        case .image: return nil
        }
    }
}

extension NSImage {
    var shelfPNGData: Data? {
        guard let image = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { return nil }
        return data as Data
    }
}

// MARK: - Controller

@MainActor
final class ShelfController: NSObject, NSWindowDelegate,
                             NSTableViewDataSource, NSTableViewDelegate,
                             NSDraggingSource, @preconcurrency QLPreviewPanelDataSource,
                             QLPreviewPanelDelegate {
    static let shared = ShelfController()

    private(set) var items: [ShelfItem] = []

    private var panel: ShelfPanel?
    private var root: ShelfRootView?
    private var transferInFlight = false
    private var transferControl: ShelfTransferControl?
    private static let maximumItems = 100
    private static let maximumTextItemBytes = 1 * 1024 * 1024
    private static let maximumTextPayloadBytes = 8 * 1024 * 1024
    private static let maximumImageBytes = 64 * 1024 * 1024
    private static let maximumImagePayloadBytes = 128 * 1024 * 1024
    private var table: ShelfTableView?
    private var scroll: NSScrollView?
    private var countLabel: NSTextField?
    private var emptyLabel: NSTextField?
    private var clearButton: NSButton?
    private var saveButton: ShelfTextButton?
    private var notesButton: ShelfTextButton?
    private var dragHandle: ShelfDragHandle?
    private var headerBar: NSView?
    private var footerBar: NSView?
    private var headerSeparator: NSView?
    private var footerSeparator: NSView?
    private var hintLabel: NSTextField?
    private var dropzonesButton: NSButton?
    private var runLabel: NSTextField?
    private var stopButton: ShelfTextButton?
    private var runZoneID: UUID?
    private var runStarted: Date?
    private var runTimer: Timer?
    private var dropzoneKeyboardMode = false
    private var dropzoneStrip: ShelfDropzoneStripView?
    private var dropzoneStripHeight: NSLayoutConstraint?
    private var dropzoneStripVisible = false
    /// Bumped on every external mouse-down so a delayed strip hide from the
    /// previous drag cannot hide the strip during the next one.
    private var dragSequence = 0
    private var dragProbeChangeCount = -1
    private static let dropzoneStripHeightValue = ShelfDropzoneStripView.preferredHeight

    private var theme = PaletteTheme.all[0]
    private var themeObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var shakeMonitor: Any?
    private var detector = ShakeDetector()
    private var dragSourceBundle: String?
    private var session = UUID()
    private var openedByShake = false
    private var dropReceived = false
    private var draggingItemIDs: [UUID] = []
    private let focusReturn = PanelFocusReturn()

    private var staging: URL?
    private var previewFiles: [UUID: URL] = [:]
    private var previewGeneration: UInt64 = 0
    private var previewLoading = false
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private static let size = NSSize(width: 380, height: 440)
    private static let byteFormatter = ByteCountFormatter()

    private override init() {
        super.init()
        theme = WorkspaceStore.shared.theme
        themeObserver = NotificationCenter.default.addObserver(
            forName: .makiDeskThemeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.theme = WorkspaceStore.shared.theme
                self.applyTheme()
            }
        }
    }

    var isVisible: Bool { panel?.isVisible == true }

    // MARK: - Lifecycle

    /// The shake listener runs from launch; the shelf itself is built on demand.
    func start() {
        guard shakeMonitor == nil else { return }
        shakeMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            DispatchQueue.main.async { self?.handleDragEvent(event) }
        }
    }

    func shutdown() {
        hide(restoringFocus: false)
        if let shakeMonitor {
            NSEvent.removeMonitor(shakeMonitor)
            self.shakeMonitor = nil
        }
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
            self.themeObserver = nil
        }
    }

    func toggle() {
        isVisible ? hide() : show(at: NSEvent.mouseLocation, activating: true)
    }

    func show(at point: CGPoint?, activating: Bool) {
        if isVisible {
            if activating {
                if panel?.isKeyWindow != true { focusReturn.capture() }
                NSApp.activate(ignoringOtherApps: true)
                panel?.makeKeyAndOrderFront(nil)
                panel?.makeFirstResponder(table)
            }
            return
        }
        focusReturn.capture()
        theme = WorkspaceStore.shared.theme
        openedByShake = activating == false
        dropReceived = false
        makeStaging()
        let panel = buildIfNeeded()
        applyTheme()
        reload()
        refreshDropzones()
        place(panel, near: point)
        if activating {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(table)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.panel?.makeFirstResponder(self.table)
            }
        } else {
            panel.orderFrontRegardless()
        }
        installKeyMonitor()
    }

    func hide(restoringFocus: Bool = true) {
        setDropzoneStripVisible(false)
        let restoreFocus = focusReturn.takeRestoreAction(
            ownsKeyboard: restoringFocus && panel?.isKeyWindow == true)
        previewGeneration &+= 1
        previewLoading = false
        openedByShake = false
        dropReceived = false
        removeKeyMonitor()
        if QLPreviewPanel.shared()?.isVisible == true {
            QLPreviewPanel.shared()?.orderOut(nil)
        }
        panel?.orderOut(nil)
        clearAllItems()
        restoreFocus?()
    }

    /// Adds text from the clipboard history (T21), opening the shelf if needed.
    /// Puts an image on the shelf as a staged PNG (T40).
    ///
    /// The shelf is temporary, so the file lives in its staging folder: it goes
    /// away with the shelf, and dragging it out copies it where the user drops
    /// it. Returns the file, so the caller can also copy it to the clipboard.
    @discardableResult
    func add(image: CGImage, name: String) -> URL? {
        guard let data = NSBitmapImageRep(cgImage: image)
            .representation(using: .png, properties: [:]) else { return nil }
        makeStaging()
        guard let staging else { return nil }
        var url = staging.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let base = (name as NSString).deletingPathExtension
            url = staging.appendingPathComponent("\(base)-\(counter).png")
            counter += 1
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        add(ShelfItem.file(url, staged: true))
        show(at: NSEvent.mouseLocation, activating: false)
        return url
    }

    func add(text: String) {
        guard text.isEmpty == false else { return }
        if isVisible == false {
            show(at: NSEvent.mouseLocation, activating: true)
        }
        add(ShelfItem.text(text))
    }

    private func buildIfNeeded() -> ShelfPanel {
        if let panel { return panel }

        let panel = ShelfPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                               styleMask: [.borderless],
                               backing: .buffered, defer: false)
        panel.title = "Shelf"
        panel.setAccessibilityLabel("Shelf")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.delegate = self
        panel.setContentSize(Self.size)

        let root = ShelfRootView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        root.onDropAt = { [weak self] point, pasteboard in
            self?.performDrop(at: point, pasteboard: pasteboard) ?? false
        }
        root.onDragUpdate = { [weak self] point, pasteboard in
            self?.dropzoneDragUpdate(at: point, pasteboard: pasteboard) ?? .copy
        }
        root.onDragExit = { [weak self] in
            self?.dropzoneStrip?.setHovered(nil)
            // Keep the strip while the drag is alive: hiding it on a brief exit
            // and relying on the next mouse-dragged event to rebuild it added a
            // window where a drop could still land on the shelf. The mouse-up
            // (outside or after the drop) is the reliable end.
        }
        root.onDragEnd = { [weak self] in
            self?.dropzoneStrip?.setHovered(nil)
            // Defer even this: `draggingEnded` is documented after
            // `performDragOperation`, but a hide in the same turn must never
            // win over the drop that is still being delivered.
            DispatchQueue.main.async { [weak self] in
                self?.setDropzoneStripVisible(false)
            }
        }
        panel.contentView = root

        let header = ShelfHeaderView()
        let footer = NSView()
        let separatorTop = NSView()
        let separatorBottom = NSView()
        let title = NSTextField(labelWithString: "Shelf")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let count = NSTextField(labelWithString: "0 items")
        count.font = .systemFont(ofSize: 10.5)
        let clear = NSButton()
        clear.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Clear the shelf")
        clear.isBordered = false
        clear.imagePosition = .imageOnly
        clear.target = self
        clear.action = #selector(clearClicked)
        clear.toolTip = "Empty the shelf"
        let close = NSButton()
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close the shelf")
        close.isBordered = false
        close.imagePosition = .imageOnly
        close.target = self
        close.action = #selector(closeClicked)
        close.toolTip = "Close the shelf (Esc)"

        let table = ShelfTableView()
        table.headerView = nil
        table.rowHeight = 52
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("shelf")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.onMenu = { [weak self] event in self?.contextMenu(for: event) }
        table.dragOperationMask = { [weak self] in
            guard let self else { return .copy }
            let selected = self.selectedItems
            return Self.dragOperations(for: selected.isEmpty ? self.items : selected)
        }
        table.onDragEnded = { [weak self] operation in self?.tableDragEnded(operation) }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let empty = NSTextField(labelWithString: "Drop files, links, text or images here")
        empty.font = .systemFont(ofSize: 11.5)
        empty.alignment = .center
        empty.lineBreakMode = .byWordWrapping
        empty.maximumNumberOfLines = 2

        let handle = ShelfDragHandle()
        handle.onDrag = { [weak self] event in self?.dragAll(event) }
        let save = ShelfTextButton(title: "Save…")
        save.target = self
        save.action = #selector(saveClicked)
        save.toolTip = "Copy or move everything to a folder"
        let notes = ShelfTextButton(title: "To Notes")
        notes.target = self
        notes.action = #selector(insertInNotes)
        notes.toolTip = "Insert the selected text in the open note"
        let hint = NSTextField(labelWithString: "Space · ⌫ · ⌘D")
        hint.font = .systemFont(ofSize: 9)
        hint.alignment = .right

        let zones = NSButton()
        zones.image = NSImage(systemSymbolName: "bolt.square",
                              accessibilityDescription: "Run a dropzone on the selection")
        zones.isBordered = false
        zones.imagePosition = .imageOnly
        zones.target = self
        zones.action = #selector(toggleDropzoneStrip)
        zones.toolTip = "Run a dropzone on the selected items (⌘D)"

        let runLabel = NSTextField(labelWithString: "")
        runLabel.font = .systemFont(ofSize: 9.5)
        runLabel.alignment = .right
        runLabel.lineBreakMode = .byTruncatingMiddle
        runLabel.isHidden = true
        runLabel.setAccessibilityLabel("Running dropzone")

        let stop = ShelfTextButton(title: "Stop")
        stop.target = self
        stop.action = #selector(stopZoneRun)
        stop.toolTip = "Stop the running command"
        stop.isHidden = true

        let strip = ShelfDropzoneStripView()
        strip.isHidden = true
        let stripHeight = strip.heightAnchor.constraint(equalToConstant: 0)

        for view in [header, footer, separatorTop, separatorBottom, scroll, empty, strip] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        for view in [title, count, clear, close] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        for view in [handle, save, notes, zones, hint, runLabel, stop] {
            view.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(view)
        }

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),

            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            count.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            count.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 22),
            close.heightAnchor.constraint(equalToConstant: 22),
            clear.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4),
            clear.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            clear.widthAnchor.constraint(equalToConstant: 22),
            clear.heightAnchor.constraint(equalToConstant: 22),

            separatorTop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separatorTop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separatorTop.topAnchor.constraint(equalTo: header.bottomAnchor),
            separatorTop.heightAnchor.constraint(equalToConstant: 1),

            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separatorTop.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: strip.topAnchor),

            strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            strip.bottomAnchor.constraint(equalTo: separatorBottom.topAnchor),
            stripHeight,

            separatorBottom.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separatorBottom.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separatorBottom.bottomAnchor.constraint(equalTo: footer.topAnchor),
            separatorBottom.heightAnchor.constraint(equalToConstant: 1),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 44),

            handle.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12),
            handle.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            handle.widthAnchor.constraint(equalToConstant: 108),
            handle.heightAnchor.constraint(equalToConstant: 26),
            save.leadingAnchor.constraint(equalTo: handle.trailingAnchor, constant: 6),
            save.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            save.widthAnchor.constraint(equalToConstant: 52),
            save.heightAnchor.constraint(equalToConstant: 26),
            notes.leadingAnchor.constraint(equalTo: save.trailingAnchor, constant: 6),
            notes.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            notes.widthAnchor.constraint(equalToConstant: 64),
            notes.heightAnchor.constraint(equalToConstant: 26),
            zones.leadingAnchor.constraint(equalTo: notes.trailingAnchor, constant: 4),
            zones.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            zones.widthAnchor.constraint(equalToConstant: 22),
            zones.heightAnchor.constraint(equalToConstant: 22),
            hint.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -12),
            hint.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: zones.trailingAnchor, constant: 8),
            runLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -12),
            runLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            runLabel.leadingAnchor.constraint(greaterThanOrEqualTo: zones.trailingAnchor, constant: 8),
            stop.trailingAnchor.constraint(equalTo: runLabel.leadingAnchor, constant: -6),
            stop.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            stop.widthAnchor.constraint(equalToConstant: 44),
            stop.heightAnchor.constraint(equalToConstant: 24),

            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.leadingAnchor, constant: 24),
            empty.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor, constant: -24),
        ])

        self.panel = panel
        self.root = root
        self.table = table
        self.scroll = scroll
        self.countLabel = count
        self.emptyLabel = empty
        self.clearButton = clear
        self.saveButton = save
        self.notesButton = notes
        self.dragHandle = handle
        self.headerBar = header
        self.footerBar = footer
        self.headerSeparator = separatorTop
        self.footerSeparator = separatorBottom
        self.hintLabel = hint
        self.dropzonesButton = zones
        self.runLabel = runLabel
        self.stopButton = stop
        self.dropzoneStrip = strip
        self.dropzoneStripHeight = stripHeight
        return panel
    }

    private func targetFrame(near point: CGPoint?) -> NSRect? {
        let origin = point ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(origin) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return nil }
        let size = currentSize
        var x = origin.x + 18
        var y = origin.y - size.height / 2
        if x + size.width > visible.maxX { x = origin.x - size.width - 18 }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func place(_ panel: NSWindow, near point: CGPoint?) {
        guard let target = targetFrame(near: point) else { return }
        panel.setFrame(target, display: false)
    }

    /// A second shake moves the open shelf to the pointer. The move is the one
    /// animation of the panel: Settings ▸ Animations sets whether and how fast.
    private func move(_ panel: NSWindow, near point: CGPoint?) {
        guard let target = targetFrame(near: point) else { return }
        let store = WorkspaceStore.shared
        guard store.effectiveAnimationsEnabled else {
            panel.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = store.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    // MARK: - Theme and reload

    private func applyTheme() {
        guard let root else { return }
        root.layer?.backgroundColor = NSColor(theme.background).cgColor
        dropzoneStrip?.applyTheme(theme)
        root.needsLayout = true

        for label in [emptyLabel, hintLabel] {
            label?.textColor = NSColor(theme.subtext)
        }
        headerBar?.wantsLayer = true
        footerBar?.wantsLayer = true
        headerSeparator?.wantsLayer = true
        footerSeparator?.wantsLayer = true
        headerSeparator?.layer?.backgroundColor = NSColor(theme.border).withAlphaComponent(0.6).cgColor
        footerSeparator?.layer?.backgroundColor = NSColor(theme.border).withAlphaComponent(0.6).cgColor
        headerBar?.layer?.backgroundColor = NSColor(theme.background).cgColor
        footerBar?.layer?.backgroundColor = NSColor(theme.background).cgColor

        if let titleLabel = headerBar?.subviews.first as? NSTextField {
            titleLabel.textColor = NSColor(theme.text)
        }
        countLabel?.textColor = NSColor(theme.subtext)
        clearButton?.contentTintColor = NSColor(theme.subtext)
        for button in (headerBar?.subviews.compactMap { $0 as? NSButton } ?? []) {
            button.contentTintColor = NSColor(theme.subtext)
        }
        saveButton?.apply(theme: theme, enabled: items.isEmpty == false)
        notesButton?.apply(theme: theme, enabled: items.contains { $0.text != nil })
        dropzonesButton?.contentTintColor = NSColor(theme.subtext)
        runLabel?.textColor = NSColor(theme.text)
        stopButton?.apply(theme: theme, enabled: true)
        dragHandle?.apply(theme: theme)
        table?.backgroundColor = .clear
        table?.reloadData()
    }

    private func reload() {
        table?.reloadData()
        let count = items.count
        countLabel?.stringValue = count == 1 ? "1 item" : "\(count) items"
        emptyLabel?.isHidden = count > 0
        clearButton?.isEnabled = count > 0
        clearButton?.contentTintColor = NSColor(theme.subtext).withAlphaComponent(count > 0 ? 1 : 0.35)
        saveButton?.apply(theme: theme, enabled: count > 0)
        notesButton?.apply(theme: theme, enabled: items.contains { $0.text != nil })
        dropzonesButton?.isEnabled = count > 0 && !DropzoneCoordinator.shared.zones.filter(\.enabled).isEmpty
        dropzonesButton?.contentTintColor = dropzonesButton?.isEnabled == true
            ? NSColor(theme.subtext)
            : NSColor(theme.subtext).withAlphaComponent(0.35)
        dragHandle?.isEnabled = count > 0
        if count > 0, let row = table?.selectedRow, row >= 0 {
            table?.scrollRowToVisible(row)
        }
    }

    private func add(_ item: ShelfItem) {
        if let key = item.dedupeKey, items.contains(where: { $0.dedupeKey == key }) {
            return
        }
        guard items.count < Self.maximumItems else {
            HUDController.shared.show("Shelf limit reached (100 items)", symbol: "exclamationmark.triangle.fill")
            return
        }
        if let text = item.text {
            let itemBytes = text.lengthOfBytes(using: .utf8)
            let existingBytes = items.compactMap(\.text).reduce(0) { $0 + $1.lengthOfBytes(using: .utf8) }
            guard itemBytes <= Self.maximumTextItemBytes,
                  existingBytes + itemBytes <= Self.maximumTextPayloadBytes else {
                HUDController.shared.show("Text exceeds the shelf memory limit", symbol: "exclamationmark.triangle.fill")
                return
            }
        }
        if case let .image(image) = item.content {
            let imageBytes = Self.estimatedDecodedImageBytes(image)
            let existingBytes = items.reduce(Int64(0)) { total, existing in
                guard case let .image(existingImage) = existing.content else { return total }
                return total + Self.estimatedDecodedImageBytes(existingImage)
            }
            guard imageBytes <= Self.maximumImageBytes,
                  existingBytes + imageBytes <= Self.maximumImagePayloadBytes else {
                HUDController.shared.show("Image exceeds the shelf memory limit", symbol: "exclamationmark.triangle.fill")
                return
            }
        }
        items.append(item)
        item.imageWriter?.prepare()
        reload()
        if let row = items.indices.last {
            table?.selectRowIndexes([row], byExtendingSelection: false)
            table?.scrollRowToVisible(row)
        }
    }

    private static func estimatedDecodedImageBytes(_ image: NSImage) -> Int64 {
        let largest = image.representations.map { rep in
            Int64(max(1, rep.pixelsWide)) * Int64(max(1, rep.pixelsHigh))
        }.max() ?? Int64(max(1, image.size.width * 2) * max(1, image.size.height * 2))
        return largest * 4
    }

    private func clearAllItems() {
        guard !transferInFlight else { return }
        session = UUID()
        items.removeAll()
        previewFiles.removeAll()
        ShelfImageWriter.clearCache()
        removeStaging()
        table?.reloadData()
        countLabel?.stringValue = "0 items"
        emptyLabel?.isHidden = false
        clearButton?.isEnabled = false
        saveButton?.apply(theme: theme, enabled: false)
        notesButton?.apply(theme: theme, enabled: false)
        dragHandle?.isEnabled = false
    }

    // MARK: - Staging

    private func makeStaging() {
        guard staging == nil else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDesk-Shelf-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        staging = url
    }

    private func removeStaging() {
        guard let staging else { return }
        self.staging = nil
        // The same race as a drag out: a file just handed to another app may
        // still be read. A few seconds are enough, and the folder is temporary
        // anyway.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            try? FileManager.default.removeItem(at: staging)
        }
    }

    // MARK: - Drop

    private func accept(_ pasteboard: NSPasteboard) -> Bool {
        guard isVisible else { return false }

        // Promises first: apps such as Photos and Safari only deliver promised
        // files, and the data is only readable inside this operation.
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self],
                                               options: nil) as? [NSFilePromiseReceiver] ?? []
        if receivers.isEmpty == false {
            receivePromises(receivers)
            dropReceived = true
            return true
        }

        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] ?? []
        if fileURLs.isEmpty == false {
            for url in fileURLs { add(.file(url)) }
            dropReceived = true
            return true
        }

        if let image = NSImage(pasteboard: pasteboard) {
            add(.image(image))
            dropReceived = true
            return true
        }

        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: false
        ]) as? [URL] ?? []
        let links = urls.filter { $0.scheme == "http" || $0.scheme == "https" }
        if links.isEmpty == false {
            for url in links { add(.link(url)) }
            dropReceived = true
            return true
        }

        if let text = pasteboard.string(forType: .string), text.isEmpty == false {
            add(.text(text))
            dropReceived = true
            return true
        }
        return false
    }

    private func receivePromises(_ receivers: [NSFilePromiseReceiver]) {
        makeStaging()
        guard let staging else { return }
        let destination = staging.appendingPathComponent("promises-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let token = session
        let progress = HUDController.shared.showProgress("Receiving files…",
                                                         symbol: "arrow.down.circle")
        let group = DispatchGroup()
        for receiver in receivers {
            group.enter()
            receiver.receivePromisedFiles(atDestination: destination, options: [:],
                                          operationQueue: promiseQueue) { [weak self] url, error in
                Task { @MainActor in
                    guard let self, self.session == token, error == nil, self.isVisible else { return }
                    self.add(.file(url, staged: true))
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            HUDController.shared.finishProgress(progress)
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row >= 0, row < items.count, items[row].isAvailable else { return nil }
        return items[row].pasteboardWriter
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        tableDraggedIDs = rowIndexes.compactMap { $0 < items.count ? items[$0].id : nil }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ShelfCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ShelfCellView
            ?? ShelfCellView(identifier: identifier)
        let item = items[row]
        cell.configure(item: item, theme: theme, available: item.isAvailable,
                       onRemove: { [weak self] in
            self?.remove(itemID: item.id)
        })
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = ShelfRowView()
        rowView.theme = theme
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Drawing the selection in the row view keeps it independent of the
        // window's key state; a reload here would clear the selection.
        updateNotesButton()
    }

    private func updateNotesButton() {
        let selected = selectedItems
        let hasText = (selected.isEmpty ? items : selected).contains { $0.text != nil }
        notesButton?.apply(theme: theme, enabled: hasText)
    }

    private var selectedItems: [ShelfItem] {
        guard let table else { return [] }
        return table.selectedRowIndexes.compactMap { $0 < items.count ? items[$0] : nil }
    }

    private func remove(itemID: UUID, deleteStagedFile: Bool = true) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        let item = items.remove(at: index)
        if case let .file(url, staged) = item.content, staged, deleteStagedFile {
            try? FileManager.default.removeItem(at: url)
        }
        previewFiles[itemID] = nil
        table?.reloadData()
        reload()
    }

    @objc private func doubleClicked() {
        toggleQuickLook()
    }

    @objc private func clearClicked() {
        clearAllItems()
        makeStaging()
    }

    @objc private func closeClicked() {
        hide()
    }

    // MARK: - Quick Look

    @objc func toggleQuickLook() {
        guard let preview = QLPreviewPanel.shared() else { return }
        if preview.isVisible {
            preview.orderOut(nil)
            return
        }
        if previewLoading {
            previewGeneration &+= 1
            previewLoading = false
            return
        }
        guard let row = table?.selectedRow, items.indices.contains(row), let staging else { return }
        let item = items[row]
        let payload: ShelfTransferPayload
        switch item.content {
        case let .file(url, _): payload = .file(url)
        case let .text(text): payload = .text(text)
        case let .image(image): payload = .image(image)
        case .link:
            HUDController.shared.show("Nothing to preview", symbol: "eye.slash")
            return
        }
        previewGeneration &+= 1
        let generation = previewGeneration
        let session = self.session
        let cached = previewFiles[item.id]
        let directory = staging.appendingPathComponent("preview-\(item.id.uuidString)", isDirectory: true)
        let name = Self.previewName(item) + (item.imageWriter == nil ? ".txt" : ".png")
        previewLoading = true
        promiseQueue.addOperation { [weak self] in
            let url: URL?
            do {
                if case let .file(file) = payload {
                    url = FileManager.default.fileExists(atPath: file.path) ? file : nil
                } else if let cached, FileManager.default.fileExists(atPath: cached.path) {
                    url = cached
                } else {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try Self.writeTransfer(ShelfTransferRequest(id: item.id, name: name,
                                                                payload: payload, move: false), to: directory)
                    url = directory.appendingPathComponent(name)
                }
            } catch { url = nil }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isVisible, self.session == session else {
                    let obsolete = self?.staging != staging ? staging : directory
                    DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: obsolete) }
                    return
                }
                guard self.previewGeneration == generation else { return }
                self.previewLoading = false
                guard let url else {
                    HUDController.shared.show("Nothing to preview", symbol: "eye.slash")
                    return
                }
                self.previewFiles[item.id] = url
                guard self.panel?.isKeyWindow == true, NSApp.isActive,
                      let selected = self.table?.selectedRow, self.items.indices.contains(selected),
                      self.items[selected].id == item.id else { return }
                self.previewItem = url as NSURL
                preview.dataSource = self
                preview.delegate = self
                preview.reloadData()
                preview.makeKeyAndOrderFront(nil)
            }
        }
    }

    private var previewItem: NSURL?

    private static func previewName(_ item: ShelfItem) -> String {
        let cleaned = item.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.isEmpty == false else { return "Shelf item" }
        return String(cleaned.prefix(50))
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewItem == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewItem
    }

    // MARK: - Dragging out

    private var tableDraggedIDs: [UUID] = []

    private func dragAll(_ event: NSEvent) {
        guard items.isEmpty == false, let table else { return }
        beginDrag(items, from: table, event: event)
    }

    private func tableDragEnded(_ operation: NSDragOperation) {
        let ids = tableDraggedIDs
        tableDraggedIDs.removeAll()
        guard operation.contains(.move) else { return }
        // Remove after the table finishes its own drag teardown; reloading its
        // rows inside the ended callback can leave the next session stuck.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for id in ids { self.remove(itemID: id) }
        }
    }

    private func beginDrag(_ items: [ShelfItem], from view: NSView, event: NSEvent) {
        let available = items.filter(\.isAvailable)
        if available.count < items.count {
            HUDController.shared.show("Some files are no longer available",
                                      symbol: "exclamationmark.triangle")
            table?.reloadData()
        }
        guard available.isEmpty == false else { return }
        let items = available
        let point = view.convert(event.locationInWindow, from: nil)
        var dragging: [NSDraggingItem] = []
        var draggingIDs: [UUID] = []
        for (index, item) in items.enumerated() {
            guard let writer = item.pasteboardWriter else { continue }
            let draggingItem = NSDraggingItem(pasteboardWriter: writer)
            let frame = NSRect(x: point.x - 22 + CGFloat(index) * 8,
                               y: point.y - 22,
                               width: 44, height: 44)
            draggingItem.setDraggingFrame(frame, contents: item.icon)
            dragging.append(draggingItem)
            draggingIDs.append(item.id)
        }
        guard dragging.isEmpty == false else { return }
        draggingItemIDs = draggingIDs
        let session = view.beginDraggingSession(with: dragging, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    /// Shelf files are references to the user's own items, so a destination may
    /// move them: Finder then removes the original on the same volume. Text,
    /// links and images have no source file to move, so they stay copy-only.
    static func dragOperations(for items: [ShelfItem]) -> NSDragOperation {
        guard items.isEmpty == false else { return .copy }
        let allFiles = items.allSatisfy { item in
            if case .file = item.content { return true }
            return false
        }
        return allFiles ? [.copy, .move] : .copy
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        let dragged = draggingItemIDs.compactMap { id in items.first(where: { $0.id == id }) }
        return Self.dragOperations(for: dragged)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        let draggedIDs = draggingItemIDs
        draggingItemIDs.removeAll()
        // A moved file no longer lives at the URL the shelf references, so the
        // entry would only linger as unavailable. The staged file itself is
        // **not** deleted here: a destination that copies rather than moves may
        // still be reading it, and deleting it under the copy truncated the
        // image — a half-written PNG that Preview opens and the Finder cannot
        // thumbnail (T40). The staging folder takes it away on close.
        guard operation.contains(.move) else { return }
        for id in draggedIDs { remove(itemID: id, deleteStagedFile: false) }
    }

    // MARK: - Menu and folders

    private func contextMenu(for event: NSEvent) -> NSMenu? {
        guard let table else { return nil }
        let point = table.convert(event.locationInWindow, from: nil)
        let row = table.row(at: point)
        if row >= 0, table.selectedRowIndexes.contains(row) == false {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        let selected = selectedItems.isEmpty ? items : selectedItems
        guard selected.isEmpty == false else { return nil }

        let menu = NSMenu()
        let preview = NSMenuItem(title: "Quick Look", action: #selector(toggleQuickLook), keyEquivalent: "")
        preview.target = self
        menu.addItem(preview)

        if selected.contains(where: { $0.text != nil }) {
            let notes = NSMenuItem(title: "Insert in Notes", action: #selector(insertInNotes), keyEquivalent: "")
            notes.target = self
            menu.addItem(notes)
        }
        if selected.count == 1, let file = selected[0].fileURL, file.isFileURL {
            let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(revealSelected), keyEquivalent: "")
            reveal.target = self
            menu.addItem(reveal)
        }
        menu.addItem(.separator())
        let copy = NSMenuItem(title: "Copy All to Folder…", action: #selector(copyAllToFolder), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        let move = NSMenuItem(title: "Move All to Folder…", action: #selector(moveAllToFolder), keyEquivalent: "")
        move.target = self
        menu.addItem(move)
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove", action: #selector(removeSelected), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        return menu
    }

    @objc private func removeSelected() {
        guard !transferInFlight else { return }
        let ids = selectedItems.map(\.id)
        for id in ids { remove(itemID: id) }
    }

    @objc private func revealSelected() {
        guard let file = selectedItems.first?.fileURL, file.isFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    @objc private func saveClicked(_ sender: NSButton) {
        let menu = NSMenu()
        if transferInFlight {
            let cancel = NSMenuItem(title: "Cancel Transfer", action: #selector(cancelTransfer), keyEquivalent: "")
            cancel.target = self
            menu.addItem(cancel)
            menu.addItem(.separator())
        }
        let copy = NSMenuItem(title: "Copy All to Folder…", action: #selector(copyAllToFolder), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        let move = NSMenuItem(title: "Move All to Folder…", action: #selector(moveAllToFolder), keyEquivalent: "")
        move.target = self
        menu.addItem(move)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func copyAllToFolder() { transfer(.copy) }
    @objc private func moveAllToFolder() { transfer(.move) }

    @objc private func cancelTransfer() {
        transferControl?.cancel()
    }

    private enum Transfer { case copy, move }

    private func transfer(_ mode: Transfer) {
        guard items.isEmpty == false, panel != nil, !transferInFlight else { return }
        let open = NSOpenPanel()
        open.title = mode == .copy ? "Copy the shelf to a folder" : "Move the shelf to a folder"
        open.prompt = mode == .copy ? "Copy" : "Move"
        open.canChooseFiles = false
        open.canChooseDirectories = true
        open.allowsMultipleSelection = false
        // A sheet cannot always attach to a borderless panel: run the picker as
        // a normal modal window instead.
        open.begin { [weak self] response in
            guard response == .OK, let folder = open.url else { return }
            self?.performTransfer(mode, to: folder)
        }
    }

    private func performTransfer(_ mode: Transfer, to folder: URL) {
        let requests = items.compactMap { item -> ShelfTransferRequest? in
            let payload: ShelfTransferPayload
            let fileName: String
            switch item.content {
            case let .file(url, _):
                payload = .file(url)
                fileName = url.lastPathComponent
            case let .text(text):
                payload = .text(text)
                fileName = "Shelf text.txt"
            case let .image(image):
                payload = .image(image)
                fileName = "Shelf image.png"
            case let .link(url):
                payload = .link(url)
                fileName = "Link.webloc"
            }
            return ShelfTransferRequest(id: item.id, name: fileName, payload: payload,
                                        move: mode == .move)
        }
        guard requests.count == items.count, !requests.isEmpty else {
            HUDController.shared.show("An image could not be prepared for transfer", symbol: "exclamationmark.triangle.fill")
            return
        }
        transferInFlight = true
        let control = ShelfTransferControl()
        transferControl = control
        let progress = HUDController.shared.showProgress("Transferring shelf items…",
                                                         symbol: "folder")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var results: [ShelfTransferResult] = []
            for (index, request) in requests.enumerated() {
                guard !control.isCancelled else { break }
                do {
                    try Self.writeTransfer(request, to: folder)
                    results.append(ShelfTransferResult(id: request.id, error: nil))
                } catch {
                    results.append(ShelfTransferResult(id: request.id, error: error.localizedDescription))
                }
                let completed = index + 1
                Task { @MainActor [weak self] in
                    self?.hintLabel?.stringValue = "Transferring \(completed) of \(requests.count)…"
                    HUDController.shared.updateProgress(
                        progress,
                        text: "Transferring \(completed) of \(requests.count)…",
                        detail: nil
                    )
                }
            }
            let wasCancelled = control.isCancelled
            Task { @MainActor [weak self] in
                guard let self else { return }
                HUDController.shared.finishProgress(progress)
                self.transferInFlight = false
                self.transferControl = nil
                if mode == .move {
                    for result in results where result.error == nil { self.remove(itemID: result.id) }
                }
                self.reload()
                if wasCancelled {
                    HUDController.shared.show("Transfer cancelled after \(results.count) of \(requests.count) items", symbol: "xmark.circle")
                } else if let first = results.first(where: { $0.error != nil })?.error {
                    let alert = NSAlert()
                    alert.messageText = "Some items could not be transferred"
                    alert.informativeText = first
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                } else {
                    HUDController.shared.show(
                        "\(mode == .copy ? "Copied" : "Moved") \(results.count) items",
                        symbol: "folder"
                    )
                }
            }
        }
    }

    nonisolated private static func writeTransfer(_ request: ShelfTransferRequest, to folder: URL) throws {
        let basename = (request.name as NSString).deletingPathExtension
        let ext = (request.name as NSString).pathExtension
        var destination = folder.appendingPathComponent(request.name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let name = ext.isEmpty ? "\(basename) \(suffix)" : "\(basename) \(suffix).\(ext)"
            destination = folder.appendingPathComponent(name)
            suffix += 1
        }
        switch request.payload {
        case let .file(url):
            if request.move { try FileManager.default.moveItem(at: url, to: destination) }
            else { try FileManager.default.copyItem(at: url, to: destination) }
        case let .text(text):
            try text.write(to: destination, atomically: true, encoding: .utf8)
        case let .image(image):
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw NSError(domain: "MakiDeskShelf", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The image could not be prepared for transfer."])
            }
            guard let destinationWriter = CGImageDestinationCreateWithURL(
                destination as CFURL, UTType.png.identifier as CFString, 1, nil
            ) else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(destinationWriter, cgImage, nil)
            guard CGImageDestinationFinalize(destinationWriter) else { throw CocoaError(.fileWriteUnknown) }
        case let .link(url):
            let plist: [String: String] = ["URL": url.absoluteString]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: destination)
        }
    }

    // MARK: - Text to Notes

    @objc private func insertInNotes() {
        let selected = selectedItems.isEmpty ? items : selectedItems
        let texts = selected.compactMap(\.text)
        guard texts.isEmpty == false else {
            HUDController.shared.show("No text in the selection", symbol: "note.text")
            return
        }
        NotesController.shared.insertText(texts.joined(separator: "\n\n"))
        HUDController.shared.show("Inserted in Notes", symbol: "note.text")
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            // The shelf can stay visible while the notes (or another window)
            // has the keyboard: only take keys when the shelf, or Quick Look,
            // is the key window.
            let shelfIsKey = self.panel?.isKeyWindow == true
            let quickLookIsKey = QLPreviewPanel.shared()?.isKeyWindow == true
            guard shelfIsKey || quickLookIsKey else { return event }
            if QLPreviewPanel.shared()?.isVisible == true {
                if event.keyCode == 49 || event.keyCode == 53 {
                    QLPreviewPanel.shared()?.orderOut(nil)
                    self.panel?.makeKeyAndOrderFront(nil)
                    self.panel?.makeFirstResponder(self.table)
                    return nil
                }
                return event
            }
            // Keyboard mode of the dropzone strip (T47): the drag owns the
            // events while it lasts, so the strip is reached from here.
            if self.dropzoneKeyboardMode {
                switch event.keyCode {
                case 123: self.dropzoneStrip?.moveHighlight(by: -1); return nil
                case 124: self.dropzoneStrip?.moveHighlight(by: 1); return nil
                case 126: self.leaveDropzoneKeyboardMode(); return nil
                case 36, 76: self.runHighlightedZone(); return nil
                case 53: self.leaveDropzoneKeyboardMode(); return nil
                default: return event
                }
            }
            switch event.keyCode {
            case 126: self.moveSelection(by: -1); return nil   // Up
            case 125:                                           // Down
                if self.table?.selectedRow == self.items.count - 1,
                   (self.dropzoneStrip?.zoneCount ?? 0) > 0 {
                    self.enterDropzoneKeyboardMode()
                } else {
                    self.moveSelection(by: 1)
                }
                return nil
            case 116: self.moveSelection(by: -6); return nil   // Page Up
            case 121: self.moveSelection(by: 6); return nil    // Page Down
            case 115: self.moveSelection(to: 0); return nil    // Home
            case 119: self.moveSelection(to: self.items.count - 1); return nil // End
            case 2 where event.modifierFlags.contains(.command): // ⌘D
                self.toggleDropzoneStrip()
                return nil
            case 49:                                    // Space: Quick Look
                self.toggleQuickLook()
                return nil
            case 51, 117:                               // Delete / forward delete
                self.removeSelected()
                return nil
            case 53:                                    // Esc
                self.hide()
                return nil
            default:
                return event
            }
        }
    }

    private func moveSelection(by delta: Int) {
        guard items.isEmpty == false, let table else { return }
        let current = table.selectedRow
        let target: Int
        if current < 0 {
            target = delta > 0 ? 0 : items.count - 1
        } else {
            target = min(max(0, current + delta), items.count - 1)
        }
        moveSelection(to: target)
    }

    private func moveSelection(to row: Int) {
        guard let table, row >= 0, row < items.count else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        updateNotesButton()
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    // MARK: - Dropzones

    private var currentSize: NSSize {
        NSSize(width: Self.size.width,
               height: Self.size.height + (dropzoneStripVisible ? Self.dropzoneStripHeightValue : 0))
    }

    private func refreshDropzones() {
        let coordinator = DropzoneCoordinator.shared
        coordinator.reloadIfNeeded()
        let zones = coordinator.zones.filter(\.enabled)
        dropzoneStrip?.update(zones: zones, theme: theme)
        dropzoneStrip?.setCompatibility([:])
        dropzoneStrip?.setPreviews([:])
        dropzoneStrip?.clearHighlight()
        dragProbeChangeCount = -1
        if zones.isEmpty { setDropzoneStripVisible(false) }
    }

    private func setDropzoneStripVisible(_ visible: Bool) {
        guard let strip = dropzoneStrip, let height = dropzoneStripHeight else { return }
        let shouldShow = visible && strip.zoneCount > 0
        guard shouldShow != dropzoneStripVisible else { return }
        dropzoneStripVisible = shouldShow
        strip.isHidden = shouldShow == false
        height.constant = shouldShow ? Self.dropzoneStripHeightValue : 0
        if shouldShow { strip.scrollToLeading() }
        strip.setHovered(nil)
        strip.clearHighlight()
        if shouldShow == false {
            strip.setCompatibility([:])
            strip.setPreviews([:])
            dropzoneKeyboardMode = false
        }
        // Resize around the panel's current position. Re-placing it with
        // `targetFrame(near: NSEvent.mouseLocation)` here moved the shelf toward
        // the pointer the moment a drag started; the pointer is usually outside
        // the panel then, so the shelf jumped away and the release became a
        // shelf drop (or hit the gutter). Keep the bottom-left instead: the
        // strip is inserted above the footer and the panel grows upward, which
        // is exactly reversed when the strip hides.
        guard let panel else { return }
        var frame = panel.frame
        frame.size.height = Self.size.height + (shouldShow ? Self.dropzoneStripHeightValue : 0)
        if let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSPoint(x: frame.midX, y: panel.frame.midY))
        }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.origin.x, visible.minX + 8),
                                 visible.maxX - frame.width - 8)
            frame.origin.y = min(max(frame.origin.y, visible.minY + 8),
                                 visible.maxY - frame.height - 8)
        }
        panel.setFrame(frame, display: true)
    }

    /// During the drag the matcher works on types only: no file is read. A
    /// promise keeps every zone active because its type is unknown until the
    /// drop, and the coordinator validates the real payload then.
    /// True when the shelf is open with at least one selected item: the menu
    /// enables *Run dropzone* only then (T47).
    var hasSelection: Bool { !selectedItems.isEmpty }

    /// Runs `zone` on the selected shelf items, without a drag. The same
    /// coordinator path as a drop, so confirmation, overwrite checks and
    /// reporting are identical (T47).
    func runSelectedDropzone(_ zone: DropzoneConfig) {
        guard isVisible else {
            HUDController.shared.show("Open the Shelf and select something first",
                                      symbol: "tray")
            return
        }
        let selected = selectedItems
        guard !selected.isEmpty else {
            HUDController.shared.show("Select something in the Shelf first",
                                      symbol: "cursorarrow")
            return
        }
        var drop = DropzoneDrop()
        var texts: [String] = []
        for item in selected {
            switch item.content {
            case let .file(url, _):
                drop.files.append(url)
            case let .text(text):
                texts.append(text)
            case let .image(image):
                if let data = image.shelfPNGData {
                    drop.images.append(.init(data: data, name: item.name))
                }
            case let .link(url):
                drop.urls.append(url)
            }
        }
        if texts.isEmpty == false { drop.text = texts.joined(separator: "\n") }
        guard !drop.isEmpty else {
            HUDController.shared.show("Nothing runnable in the selection",
                                      symbol: "nosign")
            return
        }
        runDropzone(zone, drop: drop)
    }

    /// Type-only descriptors for the current selection, so the strip can say
    /// which zones accept it before anything is read from disk (T47).
    private func selectionItemInfos() -> [DropItemInfo] {
        var items: [DropItemInfo] = []
        var index = 0
        for item in selectedItems {
            switch item.content {
            case let .file(url, _):
                let uti = url.hasDirectoryPath
                    ? "public.folder"
                    : (url.pathExtension.isEmpty ? nil
                        : UTType(filenameExtension: url.pathExtension)?.identifier)
                items.append(DropItemInfo(kind: .file, uti: uti, name: item.name, index: index))
            case .text:
                items.append(DropItemInfo(kind: .text, name: "Text", index: index))
            case .image:
                items.append(DropItemInfo(kind: .image, name: item.name, index: index))
            case let .link(url):
                items.append(DropItemInfo(kind: .url, name: url.host ?? url.absoluteString,
                                          index: index))
            }
            index += 1
        }
        return items
    }

    @objc private func toggleDropzoneStrip() {
        if dropzoneKeyboardMode || dropzoneStripVisible {
            leaveDropzoneKeyboardMode()
        } else {
            enterDropzoneKeyboardMode()
        }
    }

    /// Shows the strip without a drag and highlights the first zone that
    /// accepts the selection. Return runs it (T47).
    private func enterDropzoneKeyboardMode() {
        guard let strip = dropzoneStrip else { return }
        guard hasSelection else {
            HUDController.shared.show("Select something in the Shelf first",
                                      symbol: "cursorarrow")
            return
        }
        let infos = selectionItemInfos()
        refreshDropzones()
        var compatibility: [UUID: Bool] = [:]
        var previews: [UUID: String] = [:]
        for zone in DropzoneCoordinator.shared.zones where zone.enabled {
            let match = DropzoneMatcher.match(infos, zone: zone)
            compatibility[zone.id] = match.isAccepted
            if case let .accepted(accepted) = match {
                previews[zone.id] = DropzoneMatcher.summary(for: accepted)
            }
        }
        strip.setPreviews(previews)
        strip.setCompatibility(compatibility)
        guard compatibility.values.contains(true) else {
            HUDController.shared.show("No dropzone accepts these items",
                                      symbol: "nosign")
            return
        }
        setDropzoneStripVisible(true)
        strip.highlightFirst()
        dropzoneKeyboardMode = true
        panel?.makeFirstResponder(table)
        HUDController.shared.show("← → choose · ↩ run · Esc back",
                                  symbol: "bolt.square")
    }

    private func leaveDropzoneKeyboardMode() {
        dropzoneKeyboardMode = false
        dropzoneStrip?.clearHighlight()
        setDropzoneStripVisible(false)
        panel?.makeFirstResponder(table)
    }

    private func runHighlightedZone() {
        guard let zone = dropzoneStrip?.highlightedZone else { return }
        leaveDropzoneKeyboardMode()
        runSelectedDropzone(zone)
    }

    /// Keeps the strip response while a zone runs so the footer can show the
    /// elapsed time and a Stop button (T47).
    private func beginZoneRun(_ zone: DropzoneConfig) {
        runTimer?.invalidate()
        runZoneID = zone.id
        runStarted = Date()
        runLabel?.stringValue = "Running \(zone.name)…"
        runLabel?.isHidden = false
        runLabel?.setAccessibilityValue("Running \(zone.name)")
        stopButton?.isHidden = false
        stopButton?.apply(theme: theme, enabled: true)
        hintLabel?.isHidden = true
        dropzonesButton?.isHidden = true
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRunLabel() }
        }
        runTimer = timer
    }

    private func updateRunLabel() {
        guard let runStarted, let runZoneID,
              let zone = DropzoneCoordinator.shared.zone(id: runZoneID) else { return }
        let elapsed = Int(Date().timeIntervalSince(runStarted))
        runLabel?.stringValue = "\(zone.name) · \(elapsed)s"
        runLabel?.setAccessibilityValue("Running \(zone.name), \(elapsed) seconds")
    }

    private func endZoneRun() {
        runTimer?.invalidate()
        runTimer = nil
        runZoneID = nil
        runStarted = nil
        runLabel?.isHidden = true
        stopButton?.isHidden = true
        hintLabel?.isHidden = false
        dropzonesButton?.isHidden = false
        if isVisible, items.isEmpty { hide() }
    }

    @objc private func stopZoneRun() {
        guard let runZoneID else { return }
        stopButton?.isEnabled = false
        runLabel?.stringValue = "Stopping…"
        Task { await DropzoneCoordinator.shared.cancel(zoneID: runZoneID) }
    }

    /// Delivers what the command produced to the clipboard or the Shelf.
    /// `.stdout` is already handled by the notice; `.reveal` by the toggle.
    private func deliverOutput(_ result: CommandResult, zone: DropzoneConfig) {
        let output = zone.feedback.showOutput
        guard output == .clipboard || output == .shelf else { return }
        let expected = DropzoneCoordinator.shared.lastRun(zoneID: zone.id)?.outputPath
        guard let payload = DropzoneOutput.payload(result: result, expectedOutput: expected) else {
            return
        }
        switch output {
        case .clipboard:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if payload.fileURLs.isEmpty == false {
                pasteboard.writeObjects(payload.fileURLs as [NSURL])
                HUDController.shared.show(payload.fileURLs.count == 1
                                          ? "1 file on the clipboard"
                                          : "\(payload.fileURLs.count) files on the clipboard",
                                          symbol: "doc.on.clipboard")
            } else if let text = payload.text {
                pasteboard.setString(text, forType: .string)
                HUDController.shared.show("Output on the clipboard",
                                          symbol: "doc.on.clipboard")
            }
        case .shelf:
            if isVisible == false {
                show(at: nil, activating: false)
                // Not a shake: do not auto-close on the next mouse release.
                openedByShake = false
            }
            if payload.fileURLs.isEmpty == false {
                for url in payload.fileURLs { add(.file(url)) }
                HUDController.shared.show(payload.fileURLs.count == 1
                                          ? "1 file added to the Shelf"
                                          : "\(payload.fileURLs.count) files added to the Shelf",
                                          symbol: "tray.and.arrow.down.fill")
            } else if let text = payload.text {
                add(.text(text))
                HUDController.shared.show("Output added to the Shelf",
                                          symbol: "tray.and.arrow.down.fill")
            }
        case .none, .stdout, .reveal:
            break
        }
    }

    private func dropzoneDragUpdate(at point: NSPoint, pasteboard: NSPasteboard) -> NSDragOperation {
        guard let strip = dropzoneStrip else { return .copy }
        let firstEntry = dropzoneStripVisible == false
        if firstEntry {
            // The strip is still hidden. Load the zones and remove the ones that
            // do not accept this drag before it appears, so the user never sees
            // an incompatible tile (or a hole left by hiding it afterwards).
            refreshDropzones()
            _ = updateDropzoneCompatibility(pasteboard)
            setDropzoneStripVisible(true)
            // Showing the strip changes the panel height and the tile frames;
            // force one layout pass before hit-testing this same point.
            root?.layoutSubtreeIfNeeded()
        } else if updateDropzoneCompatibility(pasteboard) {
            // The drag types changed: reflow the remaining tiles before the
            // next hit-test.
            root?.layoutSubtreeIfNeeded()
        }
        let local = strip.convert(point, from: root)
        guard let zone = strip.zone(at: local) else {
            strip.setHovered(nil)
            // The strip owns its whole band: the gutters are not a drop target
            // for the shelf list just above it.
            return strip.frame.contains(point) ? [] : .copy
        }
        strip.setHovered(zone.id)
        return strip.isZoneCompatible(zone.id) ? .copy : []
    }

    @discardableResult
    private func updateDropzoneCompatibility(_ pasteboard: NSPasteboard) -> Bool {
        guard let strip = dropzoneStrip, pasteboard.changeCount != dragProbeChangeCount else { return false }
        dragProbeChangeCount = pasteboard.changeCount
        guard let items = dragItems(from: pasteboard) else {
            strip.setCompatibility([:])
            strip.setPreviews([:])
            return true
        }
        var map: [UUID: Bool] = [:]
        var previews: [UUID: String] = [:]
        for zone in DropzoneCoordinator.shared.zones where zone.enabled {
            let match = DropzoneMatcher.match(items, zone: zone)
            map[zone.id] = match.isAccepted
            if case let .accepted(accepted) = match {
                previews[zone.id] = DropzoneMatcher.summary(for: accepted)
            }
        }
        strip.setPreviews(previews)
        strip.setCompatibility(map)
        return true
    }

    private func dragItems(from pasteboard: NSPasteboard) -> [DropItemInfo]? {
        // A promised file has no type yet: keep every zone available and let
        // the real validation decide.
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes
        if pasteboard.types?.contains(where: { promiseTypes.contains($0.rawValue) }) == true {
            return nil
        }
        var items: [DropItemInfo] = []
        var index = 0
        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] ?? []
        for url in fileURLs {
            let uti: String?
            if url.hasDirectoryPath {
                uti = "public.folder"
            } else {
                uti = url.pathExtension.isEmpty
                    ? nil
                    : UTType(filenameExtension: url.pathExtension)?.identifier
            }
            items.append(DropItemInfo(kind: .file, uti: uti, name: url.lastPathComponent, index: index))
            index += 1
        }
        if fileURLs.isEmpty, isImageDrag(pasteboard) {
            items.append(DropItemInfo(kind: .image, name: "Image", index: index))
            index += 1
        }
        if fileURLs.isEmpty {
            let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [
                .urlReadingFileURLsOnly: false
            ]) as? [URL] ?? []).filter { $0.isFileURL == false && ($0.scheme == "http" || $0.scheme == "https") }
            for url in urls {
                items.append(DropItemInfo(kind: .url, name: url.host ?? url.absoluteString, index: index))
                index += 1
            }
            if urls.isEmpty, pasteboard.string(forType: .string)?.isEmpty == false {
                items.append(DropItemInfo(kind: .text, name: "Text", index: index))
            }
        }
        return items.isEmpty ? nil : items
    }

    private func isImageDrag(_ pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        return types.contains(.tiff) || types.contains(.png)
    }

    /// A drop on a tile runs its zone; everything else keeps adding to the
    /// shelf.
    private func performDrop(at point: NSPoint, pasteboard: NSPasteboard) -> Bool {
        if dropzoneStripVisible, let strip = dropzoneStrip {
            let local = strip.convert(point, from: root)
            if let zone = strip.zone(at: local) {
                strip.setHovered(nil)
                dropReceived = true
                guard strip.isZoneCompatible(zone.id) else {
                    HUDController.shared.show("This dropzone does not accept these items",
                                              symbol: "nosign")
                    setDropzoneStripVisible(false)
                    return true
                }
                startDropzone(zone, pasteboard: pasteboard)
                return true
            }
            if strip.frame.contains(point) {
                strip.setHovered(nil)
                dropReceived = true
                HUDController.shared.show(strip.visibleZoneCount == 0
                                          ? "No dropzone accepts these items"
                                          : "Drop on a dropzone tile",
                                          symbol: "arrow.up.left")
                setDropzoneStripVisible(false)
                return true
            }
        }
        return accept(pasteboard)
    }

    private func startDropzone(_ zone: DropzoneConfig, pasteboard: NSPasteboard) {
        var drop = dropzoneDrop(from: pasteboard)
        drop.sourceApp = dragSourceBundle

        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self],
                                               options: nil) as? [NSFilePromiseReceiver] ?? []
        guard receivers.isEmpty == false else {
            leaveShelfForDropzone()
            runDropzone(zone, drop: drop)
            return
        }

        // Promised files go to their own directory: `hide()` clears the shelf
        // staging, and this drop must outlive the panel.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDesk-DropzoneDrop-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = NSLock()
        var urls: [URL] = []
        var failure: String?
        let group = DispatchGroup()
        let progress = HUDController.shared.showProgress("Receiving files…",
                                                         symbol: "arrow.down.circle")
        for receiver in receivers {
            group.enter()
            receiver.receivePromisedFiles(atDestination: directory, options: [:],
                                          operationQueue: promiseQueue) { url, error in
                lock.lock()
                if let error {
                    failure = error.localizedDescription
                } else {
                    urls.append(url)
                }
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            HUDController.shared.finishProgress(progress)
            guard let self else { return }
            lock.lock()
            let received = urls
            let error = failure
            lock.unlock()
            if let error {
                try? FileManager.default.removeItem(at: directory)
                HUDController.shared.show("Could not receive the files: \(Self.short(error))",
                                          symbol: "exclamationmark.triangle")
                return
            }
            drop.files.append(contentsOf: received)
            self.leaveShelfForDropzone()
            self.runDropzone(zone, drop: drop, cleanup: directory)
        }
    }

    /// A zone drop does not throw away what the shelf already holds: an empty,
    /// transient shelf closes. The run row keeps it open until the command
    /// ends, so the elapsed time and Stop stay reachable (T47).
    private func leaveShelfForDropzone() {
        dropReceived = true
        setDropzoneStripVisible(false)
        dropzoneKeyboardMode = false
    }

    private func dropzoneDrop(from pasteboard: NSPasteboard) -> DropzoneDrop {
        var drop = DropzoneDrop()
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] ?? []
        if files.isEmpty == false {
            drop.files = files
            return drop
        }
        if let image = NSImage(pasteboard: pasteboard), let data = image.shelfPNGData {
            drop.images = [.init(data: data, name: "Image")]
            return drop
        }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: false
        ]) as? [URL] ?? []).filter { $0.isFileURL == false && ($0.scheme == "http" || $0.scheme == "https") }
        if urls.isEmpty == false {
            drop.urls = urls
            return drop
        }
        if let text = pasteboard.string(forType: .string), text.isEmpty == false {
            drop.text = text
        }
        return drop
    }

    private func runDropzone(_ zone: DropzoneConfig, drop: DropzoneDrop, cleanup: URL? = nil) {
        // The footer shows the elapsed time and Stop while the zone runs (T47).
        beginZoneRun(zone)
        Task { @MainActor [weak self] in
            defer {
                if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
                self?.endZoneRun()
            }
            let coordinator = DropzoneCoordinator.shared
            var outcome = await coordinator.run(zoneID: zone.id, drop: drop)
            if case let .needsConfirmation(pending) = outcome {
                guard let self, self.confirmDropzoneRun(pending) else {
                    return
                }
                let hash = DropzoneConfig.confirmationHash(for: pending.command)
                switch coordinator.confirm(zoneID: pending.id, approvedCommandHash: hash) {
                case .confirmed:
                    outcome = await coordinator.run(zoneID: pending.id, drop: drop)
                case .commandChanged:
                    HUDController.shared.show("\(pending.name) changed during confirmation; try again",
                                              symbol: "exclamationmark.triangle")
                    if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
                    return
                case .unavailable:
                    HUDController.shared.show("\(pending.name) is no longer available",
                                              symbol: "questionmark.circle")
                    if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
                    return
                case let .saveFailed(message):
                    HUDController.shared.show("Could not save the confirmation for \(pending.name): \(Self.short(message))",
                                              symbol: "externaldrive.badge.xmark")
                    if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
                    return
                }
            }
            if case let .needsOverwriteConfirmation(pending, path) = outcome {
                guard let self else {
                    if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
                    return
                }
                guard self.confirmDropzoneOverwrite(pending, path: path) else {
                    HUDController.shared.show("\(pending.name) cancelled",
                                              symbol: "xmark.circle")
                    if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
                    return
                }
                outcome = await coordinator.run(zoneID: pending.id, drop: drop,
                                                confirmedOverwritePath: path)
            }
            if case .needsConfirmation = outcome {
                outcome = .failed("The command changed during confirmation. Drop the item again to review it.")
            } else if case .needsOverwriteConfirmation = outcome {
                outcome = .failed("The output changed during confirmation. Drop the item again to review it.")
            }
            self?.report(outcome, zone: zone)
            if case let .finished(result) = outcome {
                self?.deliverOutput(result, zone: zone)
            }
            if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
        }
    }

    private func confirmDropzoneOverwrite(_ zone: DropzoneConfig, path: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace an existing file?"
        alert.informativeText = """
        “\(zone.name)” may replace:

        \(path)

        Continue?
        """
        alert.addButton(withTitle: "Run Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmDropzoneRun(_ zone: DropzoneConfig) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Run “\(zone.name)”?"
        alert.informativeText = """
        This dropzone runs:
        \(zone.command.line)

        Only run commands you trust.
        """
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func report(_ outcome: DropzoneCoordinator.Outcome, zone: DropzoneConfig) {
        switch outcome {
        case let .rejected(reason):
            HUDController.shared.show(Self.short(reason.errorDescription ?? "Drop rejected"),
                                      symbol: "nosign")
        case .cancelled:
            HUDController.shared.show("\(zone.name) cancelled",
                                      symbol: "xmark.circle")
        case let .failed(message):
            HUDController.shared.show("\(zone.name): \(Self.short(message))",
                                      symbol: "exclamationmark.triangle")
        case .needsConfirmation, .needsOverwriteConfirmation:
            break
        case let .finished(result):
            if result.succeeded {
                if zone.feedback.notifyOnSuccess {
                    HUDController.shared.show("\(zone.name) done", symbol: "checkmark.circle.fill")
                }
                if zone.feedback.revealOutput {
                    let output = result.workDirectory.appendingPathComponent("output", isDirectory: true)
                    if FileManager.default.fileExists(atPath: output.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([output])
                    }
                }
            } else if result.cancelled {
                HUDController.shared.show("\(zone.name) cancelled", symbol: "xmark.circle")
            } else if result.timedOut {
                HUDController.shared.show("\(zone.name) timed out",
                                          symbol: "clock.badge.exclamationmark")
            } else {
                let detail = Self.firstLine(result.stderrExcerpt)
                HUDController.shared.show("\(zone.name) failed\(detail.isEmpty ? "" : ": \(detail)")",
                                          symbol: "exclamationmark.triangle")
            }
        }
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return short(line)
    }

    private static func short(_ text: String) -> String {
        let limit = 140
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    // MARK: - Shake

    private func handleDragEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // A new drag starts clean: the strip was not shown yet, and any
            // compatibility map from the previous drag must not survive.
            dragSequence &+= 1
            dragProbeChangeCount = -1
            setDropzoneStripVisible(false)
        case .leftMouseUp:
            // Do not hide the strip in the same turn as the mouse-up: AppKit is
            // still delivering the drop to `performDragOperation`, and hiding
            // the strip first made every zone drop fall through to the shelf.
            // The drop itself hides it immediately; otherwise let the drag end
            // first and hide shortly after.
            if panel?.frame.contains(NSEvent.mouseLocation) == true {
                let sequence = dragSequence
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.dragSequence == sequence else { return }
                    self.setDropzoneStripVisible(false)
                }
            } else {
                setDropzoneStripVisible(false)
            }
        default:
            break
        }
        handleShake(event)
    }

    private func handleShake(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            detector.reset()
            dragSourceBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        case .leftMouseDragged:
            let store = WorkspaceStore.shared
            guard store.shelfShakeEnabled else { return }
            if let source = dragSourceBundle,
               store.shelfExcludedApps.contains(where: { $0.caseInsensitiveCompare(source) == .orderedSame }) {
                return
            }
            if detector.drag(to: NSEvent.mouseLocation, at: event.timestamp,
                             preset: store.shelfShakeSensitivity.preset) {
                if isVisible {
                    // Already on screen: a new shake just brings it to the
                    // pointer, keeping what it holds and not taking the focus.
                    openedByShake = false
                    if let panel {
                        move(panel, near: NSEvent.mouseLocation)
                        panel.orderFrontRegardless()
                    }
                } else {
                    show(at: NSEvent.mouseLocation, activating: false)
                }
            }
        case .leftMouseUp:
            detector.reset()
            dragSourceBundle = nil
            if openedByShake {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.openedByShake, self.dropReceived == false else { return }
                    self.hide()
                }
            }
        default:
            break
        }
    }

    // MARK: - Window delegate

    func windowDidBecomeKey(_ notification: Notification) {
        panel?.makeFirstResponder(table)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panel?.makeFirstResponder(self.table)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // An empty shelf is just a hint: a click elsewhere dismisses it. With
        // content it stays, so a trip to another app does not lose the items.
        if items.isEmpty { hide(restoringFocus: false) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}

final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The only surface that moves the panel: the header. The footer must never
/// drag the window, or “Drag all out” would move the shelf at the same time.
final class ShelfHeaderView: NSView {
    /// A shake-opened shelf is visible without owning the keyboard. Without
    /// this, the first click only activates the window and is swallowed, so the
    /// user has to click once and drag a second time.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// MARK: - Views

final class ShelfRootView: NSView {
    var onDropAt: ((NSPoint, NSPasteboard) -> Bool)?
    var onDragUpdate: ((NSPoint, NSPasteboard) -> NSDragOperation)?
    var onDragExit: (() -> Void)?
    var onDragEnd: (() -> Void)?

    private var isPerformingDrop = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([
            .fileURL, .URL, .string, .tiff, .png,
            NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragUpdate?(convert(sender.draggingLocation, from: nil), sender.draggingPasteboard) ?? .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragUpdate?(convert(sender.draggingLocation, from: nil), sender.draggingPasteboard) ?? .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExit?()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isPerformingDrop = true
        defer { isPerformingDrop = false }
        return onDropAt?(convert(sender.draggingLocation, from: nil), sender.draggingPasteboard) ?? false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        // Do not collapse the strip while the drop is being delivered; the
        // handler hides it when the drop is actually processed. This runs for
        // a cancelled drag too, which is the deterministic cleanup.
        guard isPerformingDrop == false else { return }
        onDragEnd?()
    }
}

final class ShelfTableView: NSTableView {
    var onMenu: ((NSEvent) -> NSMenu?)?
    var dragOperationMask: (() -> NSDragOperation)?
    var onDragEnded: ((NSDragOperation) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenu?(event)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            selectAll(nil)
            return
        }
        super.keyDown(with: event)
    }

    // The table owns the drag session through pasteboardWriterForRow, so
    // AppKit tracks the mouse instead of our mouseDragged override. The custom
    // path stopped starting drags after the first session, once NSTableView
    // stayed in its own tracking loop.
    override func draggingSession(_ session: NSDraggingSession,
                                  sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        dragOperationMask?() ?? .copy
    }

    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                                  operation: NSDragOperation) {
        onDragEnded?(operation)
        super.draggingSession(session, endedAt: screenPoint, operation: operation)
    }
}

final class ShelfRowView: NSTableRowView {
    var theme: PaletteTheme?

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected, let theme else { return }
        NSColor(theme.accent).withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 6, yRadius: 6).fill()
    }
}

/// Small, square thumbnails for images: a dropped image shows what it is,
/// and an image file shows its picture instead of a generic document icon.
enum ShelfThumbnail {
    static let size: CGFloat = 32

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp", "avif"
    ]

    static func image(_ image: NSImage, size: CGFloat = ShelfThumbnail.size) -> NSImage {
        let target = NSSize(width: size, height: size)
        let canvas = NSImage(size: target)
        canvas.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: target).fill()
        let source = image.size
        guard source.width > 0, source.height > 0 else {
            canvas.unlockFocus()
            return canvas
        }
        let scale = max(size / source.width, size / source.height)
        let scaled = NSSize(width: source.width * scale, height: source.height * scale)
        image.draw(in: NSRect(x: (size - scaled.width) / 2, y: (size - scaled.height) / 2,
                              width: scaled.width, height: scaled.height),
                   from: .zero, operation: .sourceOver, fraction: 1)
        canvas.unlockFocus()
        canvas.size = target
        return canvas
    }

    static func file(_ url: URL, size: CGFloat = ShelfThumbnail.size) -> NSImage? {
        guard imageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(size * 2)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: size, height: size))
    }
}

final class ShelfCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var onRemove: (() -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 4
        iconView.layer?.masksToBounds = true
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.lineBreakMode = .byTruncatingMiddle

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.focusRingType = .none
        closeButton.target = self
        closeButton.action = #selector(removeClicked)

        for view in [iconView, nameLabel, detailLabel, closeButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(item: ShelfItem, theme: PaletteTheme, available: Bool,
                   onRemove: @escaping () -> Void) {
        self.onRemove = onRemove
        iconView.image = item.icon
        nameLabel.stringValue = item.name
        detailLabel.stringValue = available ? item.detail : "Not available"
        nameLabel.textColor = NSColor(theme.text)
        detailLabel.textColor = available ? NSColor(theme.subtext) : .systemOrange
        closeButton.contentTintColor = NSColor(theme.subtext)
    }

    @objc private func removeClicked() {
        let remove = onRemove
        remove?()
    }
}

final class ShelfDragHandle: NSView {
    var onDrag: ((NSEvent) -> Void)?
    var isEnabled = true {
        didSet { alphaValue = isEnabled ? 1 : 0.4 }
    }

    private let label = NSTextField(labelWithString: "Drag all out")
    private let icon = NSImageView()
    private var downPoint: NSPoint?
    private var theme = PaletteTheme.all[0]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        icon.image = NSImage(systemSymbolName: "hand.draw", accessibilityDescription: "Drag all out")
        icon.imageScaling = .scaleProportionallyDown
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        for view in [icon, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        resetCursorRects()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(theme: PaletteTheme) {
        self.theme = theme
        layer?.backgroundColor = NSColor(theme.surface).cgColor
        label.textColor = NSColor(theme.text)
        icon.contentTintColor = NSColor(theme.accent)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    /// The shelf can be visible without being key; a drag from the handle must
    /// still start on the first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var downEvent: NSEvent?

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        downEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let downPoint, let downEvent else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard abs(point.x - downPoint.x) + abs(point.y - downPoint.y) > 3 else { return }
        self.downPoint = nil
        self.downEvent = nil
        onDrag?(downEvent)
    }

    override func mouseUp(with event: NSEvent) {
        downPoint = nil
        downEvent = nil
    }
}

final class ShelfTextButton: NSButton {
    private var theme = PaletteTheme.all[0]
    private var isOn = true

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        font = .systemFont(ofSize: 10.5, weight: .medium)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 5
        setButtonType(.momentaryChange)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(theme: PaletteTheme, enabled: Bool) {
        self.theme = theme
        isOn = enabled
        isEnabled = enabled
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: enabled ? NSColor(theme.text) : NSColor(theme.subtext).withAlphaComponent(0.4),
        ])
        layer?.backgroundColor = NSColor(theme.surface).withAlphaComponent(enabled ? 1 : 0.5).cgColor
    }
}
