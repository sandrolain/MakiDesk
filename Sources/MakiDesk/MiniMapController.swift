import AppKit
import SwiftUI

final class MiniMapController {
    static let shared = MiniMapController()

    static let motionDuration: TimeInterval = 0.2
    fileprivate static let baseSize = CGSize(width: 320, height: 220)

    private var panel: NSPanel?
    private var hosting: NSHostingView<MiniMapView>?
    private var hideWorkItem: DispatchWorkItem?
    private var hoverTimer: Timer?

    func show(
        windows: [WorkspaceWindow],
        highlightedIDs: Set<UUID> = [],
        motionFrom: [UUID: CGRect] = [:]
    ) {
        let store = WorkspaceStore.shared
        let size = CGSize(width: Self.baseSize.width * store.overlayScale,
                          height: Self.baseSize.height * store.overlayScale)
        let map = MiniMapView(
            windows: windows,
            screenFrame: WindowController.axVisibleFrame(for: NSScreen.main),
            theme: store.theme,
            size: size,
            opacity: store.overlayOpacity,
            highlightedIDs: highlightedIDs,
            motionFrom: motionFrom,
            motionStartDate: Date()
        )
        let panel = self.panel ?? makePanel(size: size)
        panel.setContentSize(size)
        if let hosting {
            hosting.rootView = map
        } else {
            let hosting = NSHostingView(rootView: map)
            hosting.frame = CGRect(origin: .zero, size: size)
            panel.contentView = hosting
            self.hosting = hosting
        }
        place(panel)
        panel.orderFrontRegardless()
        self.panel = panel

        hideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak panel] in
            panel?.orderOut(nil)
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
        startHoverTracking()
    }

    /// Hides the overlay as soon as the pointer moves over it.
    private func startHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] timer in
            guard let self, let panel = self.panel, panel.isVisible else {
                timer.invalidate()
                self?.hoverTimer = nil
                return
            }
            if panel.frame.contains(NSEvent.mouseLocation) {
                self.hideWorkItem?.cancel()
                panel.orderOut(nil)
                timer.invalidate()
                self.hoverTimer = nil
            }
        }
    }

    private func makePanel(size: CGSize) -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Just below the palette so it never covers the switcher/search list.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) - 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        return panel
    }

    /// Places the panel at the configured screen position.
    private func place(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        panel.setFrameOrigin(WorkspaceStore.shared.miniMapPosition.origin(
            size: panel.frame.size, in: screen.visibleFrame))
    }
}

private struct MiniMapView: View {
    let windows: [WorkspaceWindow]
    let screenFrame: CGRect
    let theme: PaletteTheme
    let size: CGSize
    let opacity: Double
    let highlightedIDs: Set<UUID>
    let motionFrom: [UUID: CGRect]
    let motionStartDate: Date

    /// The area the map is scaled to. Deliberately *not* the union of every
    /// window: a window left on another display sits far off the side, and
    /// including it would shrink the screen to nothing. Off-screen windows are
    /// drawn as edge markers instead (A6).
    private var contentBounds: CGRect {
        screenFrame.insetBy(dx: -MiniMapView.margin, dy: -MiniMapView.margin)
    }

    private static let margin: CGFloat = 18

    /// True when a window only touches the screen through a thin strip.
    private func isOffScreen(_ frame: CGRect) -> Bool {
        let hit = screenFrame.intersection(frame)
        return hit.width < 8 || hit.height < 8
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60,
                                paused: highlightedIDs.isEmpty && motionFrom.isEmpty)) { timeline in
            Canvas { context, size in
                context.fill(
                    Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 12),
                    with: .color(theme.background.opacity(opacity))
                )

                let inset: CGFloat = 12
                let bounds = contentBounds
                let scale = min((size.width - inset * 2) / max(bounds.width, 1),
                                (size.height - inset * 2) / max(bounds.height, 1))
                let mapSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
                let origin = CGPoint(x: (size.width - mapSize.width) / 2,
                                     y: (size.height - mapSize.height) / 2)
                func mapRect(_ rect: CGRect) -> CGRect {
                    CGRect(x: origin.x + (rect.minX - bounds.minX) * scale,
                           y: origin.y + (rect.minY - bounds.minY) * scale,
                           width: rect.width * scale,
                           height: rect.height * scale)
                }

                // On-screen area marker (evident border).
                let screen = mapRect(screenFrame)
                context.fill(Path(roundedRect: screen, cornerRadius: 3), with: .color(.white.opacity(0.10)))
                context.stroke(Path(roundedRect: screen, cornerRadius: 3),
                               with: .color(theme.subtext.opacity(0.9)), lineWidth: 2)

                let elapsed = timeline.date.timeIntervalSince(motionStartDate)
                let t = min(max(elapsed / MiniMapController.motionDuration, 0), 1)
                let progress = 1 - pow(1 - t, 3)

                // Back-to-front: array is front-to-back, focused drawn last.
                let ordered = windows.enumerated().sorted { lhs, rhs in
                    let lh = highlightedIDs.contains(lhs.element.id)
                    let rh = highlightedIDs.contains(rhs.element.id)
                    if lh != rh { return !lh }
                    return lhs.offset > rhs.offset
                }

                for (_, window) in ordered {
                    let destination = CGRect(x: window.x, y: window.y, width: window.width, height: window.height)
                    guard destination.width > 0, destination.height > 0 else { continue }
                    var displayFrame = destination
                    if let from = motionFrom[window.id] {
                        displayFrame = CGRect(
                            x: from.minX + (destination.minX - from.minX) * progress,
                            y: from.minY + (destination.minY - from.minY) * progress,
                            width: from.width + (destination.width - from.width) * progress,
                            height: from.height + (destination.height - from.height) * progress
                        )
                    }
                    let isHighlighted = highlightedIDs.contains(window.id)
                    let color = Color(nsColor: WorkspaceStore.shared.color(for: window.appName))

                    // A window left largely off screen (on a detached display,
                    // or dragged beyond the edge): draw a bar on the edge it
                    // overhangs instead of a tiny sliver (A6).
                    guard !isOffScreen(displayFrame) else {
                        let screenRect = mapRect(screenFrame)
                        let onLeft = displayFrame.midX < screenFrame.midX
                        let barWidth: CGFloat = isHighlighted ? 6 : 4
                        let barHeight = max(6, min(screenRect.height * 0.5, screenRect.height * 0.5))
                        let centerY = min(max(mapRect(displayFrame).midY, screenRect.minY + barHeight / 2),
                                          screenRect.maxY - barHeight / 2)
                        let x = onLeft ? screenRect.minX - barWidth : screenRect.maxX
                        let bar = CGRect(x: x, y: centerY - barHeight / 2,
                                         width: barWidth, height: barHeight)
                        context.fill(Path(roundedRect: bar, cornerRadius: barWidth / 2),
                                     with: .color(color.opacity(isHighlighted ? 1 : 0.85)))
                        continue
                    }

                    let rect = mapRect(displayFrame)
                    let radius = min(4, rect.height / 5)
                    let path = Path(roundedRect: rect, cornerRadius: radius)
                    context.fill(path, with: .color(color.opacity(isHighlighted ? 0.95 : 0.72)))
                    context.stroke(path,
                                   with: .color(isHighlighted ? theme.accent : theme.background.opacity(0.5)),
                                   lineWidth: isHighlighted ? 3 : 1)

                    let titleBarHeight = min(max(3, rect.height * 0.18), rect.height)
                    let titleBar = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: titleBarHeight)
                    context.fill(Path(roundedRect: titleBar, cornerRadius: radius),
                                 with: .color(.black.opacity(0.3)))
                    if rect.width >= 38, rect.height >= 18 {
                        let label = window.title.isEmpty ? window.appName : window.title
                        context.draw(
                            Text(label).font(.system(size: 8, weight: .semibold)).foregroundColor(.white),
                            at: CGPoint(x: rect.minX + 4, y: rect.minY + 2),
                            anchor: .topLeading
                        )
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}
