import AppKit
import OSLog
import SwiftUI

struct DockerGroupHeaderBackground: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> DockerGroupHeaderBackgroundProbe {
        DockerGroupHeaderBackgroundProbe()
    }

    func updateNSView(_ view: DockerGroupHeaderBackgroundProbe, context: Context) {
        view.update(color: NSColor(color))
    }

    static func dismantleNSView(_ view: DockerGroupHeaderBackgroundProbe, coordinator: ()) {
        view.detach()
    }
}

final class DockerGroupHeaderBackgroundProbe: NSView {
    private static let logger = Logger(subsystem: "com.makidesk.app.docker",
                                       category: "GroupHeader")
    private let fill = DockerGroupHeaderFillView()
    private var color = NSColor.clear
    private var pendingUpdate = false

    func update(color: NSColor) {
        self.color = color
        fill.layer?.backgroundColor = color.cgColor
        scheduleUpdate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            detach()
        } else {
            scheduleUpdate()
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleUpdate()
    }

    func detach() {
        fill.removeFromSuperview()
    }

    private func scheduleUpdate() {
        guard window != nil, !pendingUpdate else { return }
        pendingUpdate = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingUpdate = false
            guard self.window != nil else { return }
            self.attach()
        }
    }

    private func attach() {
        var child: NSView = self
        var ancestor = superview
        while let view = ancestor {
            if let row = view as? NSTableRowView, row.isGroupRowStyle {
                if fill.superview !== row {
                    detach()
                    fill.frame = row.bounds
                    fill.autoresizingMask = [.width, .height]
                    fill.wantsLayer = true
                    fill.layer?.backgroundColor = color.cgColor
                    row.addSubview(fill, positioned: .below, relativeTo: child)
                }
                return
            }
            child = view
            ancestor = view.superview
        }
        Self.logger.error("Could not locate Docker container group header for theming")
    }
}

private final class DockerGroupHeaderFillView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
