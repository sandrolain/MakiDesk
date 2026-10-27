import AppKit
import Observation

/// Owns the Measure command (T39): one selector session, then the pinned
/// readouts. Measurements live in memory only; the unit is persisted.
@Observable
@MainActor
final class MeasureController {
    static let shared = MeasureController()
    static let maximumMeasurements = 8

    private struct Pinned {
        let id: UUID
        let visibleFrame: CGRect
        let overlay: MeasureOverlayWindow
        let badge: MeasureBadgeWindow
    }

    private var windows: [Pinned] = []
    private var isMeasuring = false
    private var task: Task<Void, Never>?
    private var unitObserver: NSObjectProtocol?

    var measurementCount: Int { windows.count }
    var currentUnit: MeasurementUnit { MeasurementSettings.unit() }

    init() {
        unitObserver = NotificationCenter.default.addObserver(
            forName: .makiDeskMeasureUnitChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshUnit() }
        }
    }

    /// Starts a measurement. A second call while the selector is open is a
    /// no-op with a notice; pinned measurements are not cleared.
    func start() {
        guard isMeasuring == false else {
            HUDController.shared.show("A selection is already open",
                                      symbol: "hand.raised.fill")
            return
        }
        HUDController.shared.hide()
        isMeasuring = true
        let unit = currentUnit
        var options = ScreenRegionSelector.Options()
        // Geometry needs no permission: the loupe is skipped when Screen
        // Recording is not granted, and the final image is never requested.
        options.capturesPixels = false
        options.dimAlpha = 0.12
        options.snapToCenters = true
        options.respectsModifiers = true
        options.hint = "Drag to measure · ⇧ square · ⌥ centre · Esc to cancel"
        options.accessibilityLabel = "Measure an area of the screen"
        options.label = { rect, display, snap in
            ScreenMeasurement(rect: rect, display: MeasureDisplay(display: display), snapped: snap)
                .lines(unit).joined(separator: "\n")
        }
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isMeasuring = false }
            do {
                let selection = try await ScreenRegionSelector.shared.select(
                    mode: .rectangle, options: options
                )
                let measurement = ScreenMeasurement(
                    rect: selection.rect,
                    display: MeasureDisplay(display: selection.display),
                    snapped: selection.snapped
                )
                self.pin(measurement, display: selection.display)
            } catch ScreenRegionError.cancelled {
                // Esc: nothing to add.
            } catch ScreenRegionError.alreadySelecting {
                HUDController.shared.show("A selection is already open",
                                          symbol: "hand.raised.fill")
            } catch ScreenRegionError.displayUnavailable {
                HUDController.shared.show("No display is available for measuring",
                                          symbol: "display.trianglebadge.exclamationmark")
            } catch {
                HUDController.shared.show("Could not measure: \(error.localizedDescription)",
                                          symbol: "exclamationmark.triangle.fill", duration: 3)
            }
        }
    }

    /// Closes every pinned measurement.
    func clear() {
        for item in windows {
            item.overlay.orderOut(nil)
            item.badge.orderOut(nil)
        }
        windows.removeAll()
    }

    private func pin(_ measurement: ScreenMeasurement, display: ScreenRegionDisplay) {
        guard measurement.rect.width >= 1, measurement.rect.height >= 1 else { return }
        while windows.count >= Self.maximumMeasurements {
            if let oldest = windows.first { remove(oldest.id) }
        }
        let id = UUID()
        let visibleFrame = Self.visibleFrame(for: display)
        let unit = currentUnit
        let overlay = MeasureOverlayWindow(measurement: measurement,
                                           displayFrame: display.frame, unit: unit)
        let badge = MeasureBadgeWindow(
            measurement: measurement, unit: unit, visibleFrame: visibleFrame,
            onCopy: { [weak self] in self?.copy(measurement) },
            onClose: { [weak self] in self?.remove(id) }
        )
        overlay.orderFrontRegardless()
        badge.orderFrontRegardless()
        windows.append(Pinned(id: id, visibleFrame: visibleFrame,
                              overlay: overlay, badge: badge))
    }

    private func remove(_ id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        let item = windows.remove(at: index)
        item.overlay.orderOut(nil)
        item.badge.orderOut(nil)
    }

    private func copy(_ measurement: ScreenMeasurement) {
        let unit = currentUnit
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(measurement.copyText(unit), forType: .string) else {
            HUDController.shared.show("The measurement could not be copied",
                                      symbol: "exclamationmark.triangle.fill")
            return
        }
        HUDController.shared.show("Measurement copied", symbol: "ruler",
                                  detail: measurement.dimensions(unit), duration: 2.2)
        WorkspaceStore.shared.status = "Measurement copied"
    }

    private func refreshUnit() {
        let unit = currentUnit
        for item in windows {
            item.overlay.update(unit: unit)
            item.badge.update(unit: unit, visibleFrame: item.visibleFrame)
        }
    }

    private static func visibleFrame(for display: ScreenRegionDisplay) -> CGRect {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == display.id
        } ?? NSScreen.main
        return screen?.visibleFrame ?? display.frame
    }
}
