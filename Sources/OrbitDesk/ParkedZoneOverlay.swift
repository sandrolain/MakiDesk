import AppKit
import SwiftUI

/// Flashes the parking zones on screen to show they are occupied and cannot be
/// used by another window.
final class ParkedZoneOverlay {
    static let shared = ParkedZoneOverlay()

    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    func flash(strips: [CGRect]) {
        guard !strips.isEmpty, let screen = NSScreen.main else { return }
        let axFrame = WindowController.axVisibleFrame(for: screen)
        let panel = self.panel ?? makePanel(screen: screen)
        self.panel = panel
        panel.contentView = NSHostingView(rootView: ParkedZonesView(axFrame: axFrame, strips: strips))
        panel.orderFrontRegardless()

        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: item)
    }

    private func makePanel(screen: NSScreen) -> NSPanel {
        let panel = NSPanel(contentRect: screen.visibleFrame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        return panel
    }
}

private struct ParkedZonesView: View {
    let axFrame: CGRect
    let strips: [CGRect]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            Canvas { context, _ in
                let pulse = 0.45 + 0.55 * abs(sin(timeline.date.timeIntervalSinceReferenceDate * 6))
                for strip in strips {
                    let rect = CGRect(x: strip.minX - axFrame.minX, y: strip.minY - axFrame.minY,
                                      width: strip.width, height: strip.height)
                    let path = Path(roundedRect: rect.insetBy(dx: 2, dy: 2), cornerRadius: 6)
                    context.fill(path, with: .color(.orange.opacity(0.22 * pulse)))
                    context.stroke(path, with: .color(.orange.opacity(pulse)), lineWidth: 4)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
