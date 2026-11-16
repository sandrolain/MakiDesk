import AppKit
import OSLog
import SwiftUI

struct DockerTableHeaderTheme<Row>: NSViewRepresentable {
    let theme: DockerUITheme
    let columnTitles: [String]
    let sortOrder: [KeyPathComparator<Row>]
    let keyPaths: [PartialKeyPath<Row>]

    func makeNSView(context: Context) -> DockerTableHeaderThemeProbe {
        DockerTableHeaderThemeProbe()
    }

    func updateNSView(_ view: DockerTableHeaderThemeProbe, context: Context) {
        let current = sortOrder.first
        let index = current.flatMap { comparator in
            keyPaths.firstIndex(of: comparator.keyPath)
        }
        let sortTitle = index.flatMap { columnTitles.indices.contains($0) ? columnTitles[$0] : nil }
        view.update(theme: theme, titles: columnTitles, sortTitle: sortTitle,
                    ascending: current?.order != .reverse)
    }

    static func dismantleNSView(_ view: DockerTableHeaderThemeProbe, coordinator: ()) {
        view.detachHeader()
    }
}

final class DockerTableHeaderThemeProbe: NSView {
    private static let logger = Logger(subsystem: "com.makidesk.app.docker",
                                       category: "TableHeader")
    private var theme: DockerUITheme?
    private var titles: [String] = []
    private var sortTitle: String?
    private var ascending = true
    private var pendingUpdate = false
    private weak var table: NSTableView?
    private var originalHeader: NSTableHeaderView?
    private weak var themedHeader: DockerThemedTableHeaderView?

    func update(theme: DockerUITheme, titles: [String], sortTitle: String?, ascending: Bool) {
        self.theme = theme
        self.titles = titles
        self.sortTitle = sortTitle
        self.ascending = ascending
        scheduleUpdate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            detachHeader()
        } else {
            scheduleUpdate()
        }
    }

    private func scheduleUpdate() {
        guard window != nil, !pendingUpdate else { return }
        pendingUpdate = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingUpdate = false
            guard self.window != nil else { return }
            self.applyTheme()
        }
    }

    private func applyTheme() {
        guard let theme else { return }
        var ancestor = superview
        while let view = ancestor {
            if let table = Self.findTable(in: view, titles: titles),
               let header = table.headerView {
                if self.table !== table || themedHeader !== header {
                    detachHeader()
                    let replacement = DockerThemedTableHeaderView(frame: header.frame)
                    originalHeader = header
                    self.table = table
                    table.headerView = replacement
                    themedHeader = replacement
                }
                themedHeader?.update(theme: theme, sortTitle: sortTitle, ascending: ascending)
                return
            }
            ancestor = view.superview
        }
        Self.logger.error("Could not locate Docker resource table header for theming")
    }

    func detachHeader() {
        if let table, table.headerView === themedHeader, let originalHeader {
            table.headerView = originalHeader
        }
        table = nil
        originalHeader = nil
        themedHeader = nil
    }

    private static func findTable(in view: NSView, titles: [String]) -> NSTableView? {
        if let table = view as? NSTableView,
           table.tableColumns.map({ $0.headerCell.stringValue }).sorted() == titles.sorted() {
            return table
        }
        for subview in view.subviews {
            if let table = findTable(in: subview, titles: titles) {
                return table
            }
        }
        return nil
    }
}

final class DockerThemedTableHeaderView: NSTableHeaderView {
    private var backgroundColor = NSColor.controlBackgroundColor
    private var textColor = NSColor.labelColor
    private var borderColor = NSColor.separatorColor
    private var sortTitle: String?
    private var ascending = true

    func update(theme: DockerUITheme, sortTitle: String?, ascending: Bool) {
        backgroundColor = theme.nsSurface
        textColor = NSColor(theme.text)
        borderColor = NSColor(theme.border)
        self.sortTitle = sortTitle
        self.ascending = ascending
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        dirtyRect.fill()
        guard let tableView else { return }

        for (index, column) in tableView.tableColumns.enumerated() {
            let rect = headerRect(ofColumn: index)
            guard rect.intersects(dirtyRect) else { continue }
            let cell = column.headerCell
            let title = NSMutableAttributedString(attributedString: cell.attributedStringValue)
            title.addAttribute(.foregroundColor, value: textColor,
                               range: NSRange(location: 0, length: title.length))
            let isSorted = cell.stringValue == sortTitle
            let indicatorWidth: CGFloat = isSorted ? 18 : 0
            let textRect = NSRect(x: rect.minX + 8,
                                  y: rect.midY - title.size().height / 2,
                                  width: max(0, rect.width - 16 - indicatorWidth),
                                  height: title.size().height)
            title.draw(in: textRect)

            if isSorted,
               let indicator = NSImage(systemSymbolName: ascending ? "chevron.up" : "chevron.down",
                                       accessibilityDescription: nil) {
                let imageRect = NSRect(x: rect.maxX - 18, y: rect.midY - 5, width: 10, height: 10)
                indicator.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))?
                    .draw(in: imageRect)
            }
            borderColor.withAlphaComponent(0.5).setFill()
            NSRect(x: rect.maxX - 1, y: rect.minY + 5, width: 1,
                   height: max(0, rect.height - 10)).fill()
        }
    }
}
