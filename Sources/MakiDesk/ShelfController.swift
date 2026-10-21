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

    private var theme = PaletteTheme.all[0]
    private var themeObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var shakeMonitor: Any?
    private var detector = ShakeDetector()
    private var dragSourceBundle: String?
    private var session = UUID()
    private var openedByShake = false
    private var dropReceived = false
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
            DispatchQueue.main.async { self?.handleShake(event) }
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
        root.onDrop = { [weak self] pasteboard in self?.accept(pasteboard) ?? false }
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
        table.onDrag = { [weak self] event in self?.dragRows(event) }
        table.onMenu = { [weak self] event in self?.contextMenu(for: event) }

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
        let hint = NSTextField(labelWithString: "Space · ⌫ · esc")
        hint.font = .systemFont(ofSize: 9)
        hint.alignment = .right

        for view in [header, footer, separatorTop, separatorBottom, scroll, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        for view in [title, count, clear, close] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        for view in [handle, save, notes, hint] {
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
            scroll.bottomAnchor.constraint(equalTo: separatorBottom.topAnchor),

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
            hint.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -12),
            hint.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: notes.trailingAnchor, constant: 8),

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
        return panel
    }

    private func targetFrame(near point: CGPoint?) -> NSRect? {
        let origin = point ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(origin) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return nil }
        let size = Self.size
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
        try? FileManager.default.removeItem(at: staging)
        self.staging = nil
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
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: destination, options: [:],
                                          operationQueue: promiseQueue) { [weak self] url, error in
                Task { @MainActor in
                    guard let self, self.session == token, error == nil, self.isVisible else { return }
                    self.add(.file(url, staged: true))
                }
            }
        }
        HUDController.shared.show("Receiving files…", symbol: "arrow.down.circle")
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

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

    private func remove(itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        let item = items.remove(at: index)
        if case let .file(url, staged) = item.content, staged {
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
            DispatchQueue.main.async {
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

    private func dragRows(_ event: NSEvent) {
        guard let table else { return }
        let point = table.convert(event.locationInWindow, from: nil)
        var row = table.row(at: point)
        if row < 0 { row = table.selectedRow }
        guard row >= 0, row < items.count else { return }
        if table.selectedRowIndexes.contains(row) == false {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        let selection = selectedItems
        beginDrag(selection.isEmpty ? [items[row]] : selection, from: table, event: event)
    }

    private func dragAll(_ event: NSEvent) {
        guard items.isEmpty == false, let table else { return }
        beginDrag(items, from: table, event: event)
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
        for (index, item) in items.enumerated() {
            guard let writer = item.pasteboardWriter else { continue }
            let draggingItem = NSDraggingItem(pasteboardWriter: writer)
            let frame = NSRect(x: point.x - 22 + CGFloat(index) * 8,
                               y: point.y - 22,
                               width: 44, height: 44)
            draggingItem.setDraggingFrame(frame, contents: item.icon)
            dragging.append(draggingItem)
        }
        guard dragging.isEmpty == false else { return }
        let session = view.beginDraggingSession(with: dragging, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
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
        HUDController.shared.show("Transferring shelf items…", symbol: "folder")
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
                }
            }
            let wasCancelled = control.isCancelled
            Task { @MainActor [weak self] in
                guard let self else { return }
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
            switch event.keyCode {
            case 126: self.moveSelection(by: -1); return nil   // Up
            case 125: self.moveSelection(by: 1); return nil    // Down
            case 116: self.moveSelection(by: -6); return nil   // Page Up
            case 121: self.moveSelection(by: 6); return nil    // Page Down
            case 115: self.moveSelection(to: 0); return nil    // Home
            case 119: self.moveSelection(to: self.items.count - 1); return nil // End
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

    // MARK: - Shake

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
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// MARK: - Views

final class ShelfRootView: NSView {
    var onDrop: ((NSPasteboard) -> Bool)?

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
        .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop?(sender.draggingPasteboard) ?? false
    }
}

final class ShelfTableView: NSTableView {
    var onDrag: ((NSEvent) -> Void)?
    var onMenu: ((NSEvent) -> NSMenu?)?
    private var downPoint: NSPoint?

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard abs(point.x - downPoint.x) + abs(point.y - downPoint.y) > 3 else { return }
        onDrag?(event)
    }

    override func mouseUp(with event: NSEvent) {
        downPoint = nil
        super.mouseUp(with: event)
    }

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

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let downPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard abs(point.x - downPoint.x) + abs(point.y - downPoint.y) > 3 else { return }
        onDrag?(event)
    }

    override func mouseUp(with event: NSEvent) {
        downPoint = nil
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
