import AppKit
import SwiftUI

private let miniMapDisplayMargin: CGFloat = 8
private let miniMapCanvasInset: CGFloat = 8
private let miniMapCaptionHeight: CGFloat = 24

@MainActor
final class MiniMapController {
    static let shared = MiniMapController()

    static let motionDuration: TimeInterval = 0.2
    fileprivate static let baseSize = CGSize(width: 320, height: 220)
    fileprivate static let multiDisplaySize = CGSize(width: 560, height: 380)

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
        let maximumSize = NSScreen.screens.count > 1 ? Self.multiDisplaySize : Self.baseSize
        let visible = NSScreen.main?.visibleFrame ?? CGRect(origin: .zero, size: maximumSize)
        let screenFrames = NSScreen.screens.map { WindowController.flip($0.frame) }
        let screenUnion = screenFrames.dropFirst().reduce(screenFrames.first ?? .zero) { $0.union($1) }
        let bounds = screenUnion.isEmpty
            ? CGRect(origin: .zero, size: maximumSize)
            : screenUnion.insetBy(dx: -miniMapDisplayMargin, dy: -miniMapDisplayMargin)
        let hasCaption = windows.contains { highlightedIDs.contains($0.id) }
        let captionHeight = hasCaption ? miniMapCaptionHeight : 0
        let maxWidth = min(maximumSize.width * store.overlayScale, visible.width * 0.88)
        let maxHeight = min(maximumSize.height * store.overlayScale, visible.height * 0.88)
        let scale = min(
            max(1, maxWidth - miniMapCanvasInset * 2) / max(bounds.width, 1),
            max(1, maxHeight - miniMapCanvasInset * 2 - captionHeight) / max(bounds.height, 1)
        )
        let size = CGSize(
            width: bounds.width * scale + miniMapCanvasInset * 2,
            height: bounds.height * scale + miniMapCanvasInset * 2 + captionHeight
        )
        let map = MiniMapView(
            windows: windows,
            screenFrames: screenFrames,
            theme: store.theme,
            tintWindows: store.paletteTintedCards,
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

    /// Hides the overlay now: the palette is about to highlight an application
    /// instead of a window, so keeping a stale window outline would mislead.
    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel?.orderOut(nil)
    }

    /// Hides the overlay as soon as the pointer moves over it.
    private func startHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
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
    let screenFrames: [CGRect]
    let theme: PaletteTheme
    let tintWindows: Bool
    let size: CGSize
    let opacity: Double
    let highlightedIDs: Set<UUID>
    let motionFrom: [UUID: CGRect]
    let motionStartDate: Date

    private var captionWindow: WorkspaceWindow? {
        windows.first(where: { highlightedIDs.contains($0.id) })
    }

    /// The map preserves the physical arrangement and relative dimensions of
    /// every connected display. Windows outside all displays use edge markers.
    private var contentBounds: CGRect {
        let union = screenFrames.dropFirst().reduce(screenFrames.first ?? .zero) { $0.union($1) }
        return union.insetBy(dx: -miniMapDisplayMargin, dy: -miniMapDisplayMargin)
    }

    /// Display on which a window has the most visible area, if any.
    private func display(for frame: CGRect) -> CGRect? {
        var best: CGRect?
        var bestArea: CGFloat = 0
        for screen in screenFrames {
            let intersection = screen.intersection(frame)
            guard intersection.width >= 8, intersection.height >= 8 else { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                best = screen
                bestArea = area
            }
        }
        return best
    }

    private func nearestDisplay(to frame: CGRect) -> CGRect? {
        screenFrames.min { lhs, rhs in
            let aX = lhs.midX - frame.midX
            let aY = lhs.midY - frame.midY
            let bX = rhs.midX - frame.midX
            let bY = rhs.midY - frame.midY
            let a = aX * aX + aY * aY
            let b = bX * bX + bY * bY
            return a < b
        }
    }

    private func titleForCaption(_ window: WorkspaceWindow, width: CGFloat) -> String {
        let title = window.title.isEmpty ? window.appName : window.title
        let maxCharacters = max(1, Int((width - miniMapCanvasInset * 2) / 6))
        guard title.count > maxCharacters else { return title }
        let sideCount = max(1, (maxCharacters - 1) / 2)
        return "\(title.prefix(sideCount))…\(title.suffix(sideCount))"
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60,
                                paused: highlightedIDs.isEmpty && motionFrom.isEmpty)) { timeline in
            Canvas { context, size in
                context.fill(
                    Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 12),
                    with: .color(theme.background.opacity(opacity))
                )

                let captionHeight = captionWindow == nil ? 0 : miniMapCaptionHeight
                let mapAreaHeight = size.height - captionHeight
                let mapArea = CGSize(width: size.width, height: mapAreaHeight)
                let inset = miniMapCanvasInset
                let bounds = contentBounds
                let scale = min((mapArea.width - inset * 2) / max(bounds.width, 1),
                                (mapArea.height - inset * 2) / max(bounds.height, 1))
                let mapSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
                let origin = CGPoint(x: (mapArea.width - mapSize.width) / 2,
                                     y: (mapArea.height - mapSize.height) / 2)
                func mapRect(_ rect: CGRect) -> CGRect {
                    CGRect(x: origin.x + (rect.minX - bounds.minX) * scale,
                           y: origin.y + (rect.minY - bounds.minY) * scale,
                           width: rect.width * scale,
                           height: rect.height * scale)
                }

                // Draw every display with one shared scale so both its size and
                // its relative position match the physical arrangement.
                for screenFrame in screenFrames {
                    let screen = mapRect(screenFrame)
                    context.fill(Path(roundedRect: screen, cornerRadius: 3), with: .color(.white.opacity(0.10)))
                    context.stroke(Path(roundedRect: screen, cornerRadius: 3),
                                   with: .color(theme.subtext.opacity(0.9)), lineWidth: 2)
                }

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
                    let color = tintWindows
                        ? Color(nsColor: WorkspaceStore.shared.color(for: window.appName))
                        : theme.subtext

                    // A window left largely off screen (on a detached display,
                    // or dragged beyond the edge): draw a bar on the edge it
                    // overhangs instead of a tiny sliver (A6).
                    guard display(for: displayFrame) != nil else {
                        guard let nearest = nearestDisplay(to: displayFrame) else { continue }
                        let screenRect = mapRect(nearest)
                        let barWidth: CGFloat = isHighlighted ? 6 : 4
                        let barHeight = max(6, screenRect.height * 0.5)
                        let centerY = min(max(mapRect(displayFrame).midY, screenRect.minY + barHeight / 2),
                                          screenRect.maxY - barHeight / 2)
                        let horizontal = abs(displayFrame.midX - nearest.midX) > abs(displayFrame.midY - nearest.midY)
                        let beyondStart = horizontal
                            ? displayFrame.midX < nearest.midX
                            : displayFrame.midY < nearest.midY
                        let bar: CGRect
                        if horizontal {
                            let x = beyondStart ? screenRect.minX - barWidth : screenRect.maxX
                            bar = CGRect(x: x, y: centerY - barHeight / 2,
                                         width: barWidth, height: barHeight)
                        } else {
                            let y = beyondStart ? screenRect.minY - barWidth : screenRect.maxY
                            let centerX = min(max(mapRect(displayFrame).midX, screenRect.minX + barHeight / 2),
                                              screenRect.maxX - barHeight / 2)
                            bar = CGRect(x: centerX - barHeight / 2, y: y,
                                         width: barHeight, height: barWidth)
                        }
                        context.fill(Path(roundedRect: bar, cornerRadius: barWidth / 2),
                                     with: .color(color.opacity(isHighlighted ? 1 : 0.85)))
                        continue
                    }

                    let rect = mapRect(displayFrame)
                    let radius = min(4, rect.height / 5)
                    let path = Path(roundedRect: rect, cornerRadius: radius)
                    context.fill(path, with: .color(color.opacity(isHighlighted ? 0.86 : 0.24)))
                    context.stroke(path,
                                   with: .color(isHighlighted ? theme.accent : theme.subtext),
                                   lineWidth: isHighlighted ? 2.5 : 1.25)

                    let titleBarHeight = min(max(3, rect.height * 0.18), rect.height)
                    let titleBar = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: titleBarHeight)
                    context.fill(Path(roundedRect: titleBar, cornerRadius: radius),
                                 with: .color(.black.opacity(0.3)))
                }

                if let captionWindow {
                    let title = titleForCaption(captionWindow, width: size.width)
                    let captionCenter = CGPoint(x: size.width / 2, y: mapAreaHeight + captionHeight / 2)
                    context.draw(
                        Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(theme.text),
                        at: captionCenter,
                        anchor: .center
                    )
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}
