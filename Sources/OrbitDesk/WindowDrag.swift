import AppKit
import SwiftUI

/// Ctrl+Opt+drag draws an overlay box (independent of the window) from where the
/// drag started to the pointer, snapping to the golden / half / full fractions
/// or parking past either edge. The window takes that frame on release.
final class WindowDrag {
    static let shared = WindowDrag()

    private var monitor: Any?
    private var element: AXUIElement?
    private var startMouse: CGPoint = .zero
    private var area: CGRect = .zero
    private var active = false
    private var preview: NSPanel?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handle(event)
        }
    }

    private var dragging: Bool { active }

    private func handle(_ event: NSEvent) {
        let combo = event.modifierFlags.contains(.control) && event.modifierFlags.contains(.option)
        switch event.type {
        case .leftMouseDown:
            guard combo else { active = false; return }
            let point = WindowController.flipPoint(NSEvent.mouseLocation)
            guard let hit = WindowController.window(at: point) else { return }
            active = true
            element = hit.element
            startMouse = point
            area = WindowController.axVisibleFrame(for: WindowController.screen(forAXFrame: hit.frame))
        case .leftMouseDragged:
            guard dragging, combo else { return }
            showPreview(targetFrame(to: WindowController.flipPoint(NSEvent.mouseLocation)))
        case .leftMouseUp:
            guard dragging else { return }
            if combo, let element {
                try? WindowController.setFrame(
                    targetFrame(to: WindowController.flipPoint(NSEvent.mouseLocation)), for: element)
            }
            hidePreview()
            active = false
            element = nil
        default:
            break
        }
    }

    /// The frame the window will take, computed only from the drag (independent
    /// of the window itself).
    private func targetFrame(to point: CGPoint) -> CGRect {
        // Dragging to either edge parks the window.
        if point.x >= area.maxX - 4 {
            return CGRect(x: area.maxX - WindowController.reservedStrip, y: area.minY,
                          width: area.width / TilingEngine.phi, height: area.height)
        }
        if point.x <= area.minX + 4 {
            return CGRect(x: area.minX - area.width / TilingEngine.phi + WindowController.reservedStrip,
                          y: area.minY, width: area.width / TilingEngine.phi, height: area.height)
        }
        var width = snap(max(200, abs(point.x - startMouse.x)), total: area.width)
        var height = snap(max(140, abs(point.y - startMouse.y)), total: area.height)
        width = min(width, area.width)
        height = min(height, area.height)
        let x = min(max(min(startMouse.x, point.x), area.minX), area.maxX - width)
        let y = min(max(min(startMouse.y, point.y), area.minY), area.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func snap(_ value: CGFloat, total: CGFloat) -> CGFloat {
        guard total > 0 else { return value }
        for fraction in [1 - 1 / TilingEngine.phi, 0.5, 1 / TilingEngine.phi, 1.0] {
            let candidate = fraction * total
            if abs(value - candidate) < 22 { return candidate }
        }
        return value
    }

    private func showPreview(_ axFrame: CGRect) {
        let panel = preview ?? makePreview()
        preview = panel
        panel.setFrame(WindowController.flip(axFrame), display: true)
        panel.orderFrontRegardless()
    }

    private func hidePreview() {
        preview?.orderOut(nil)
    }

    private func makePreview() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: DragPreviewBox())
        return panel
    }
}

private struct DragPreviewBox: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.orange.opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange, lineWidth: 3))
            .padding(1)
    }
}
