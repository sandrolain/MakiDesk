import AppKit
import SwiftUI

/// One pinned measurement: a click-through panel that draws the rectangle and
/// its dimension labels. It never takes a click from the app underneath (T39).
@MainActor
final class MeasureOverlayWindow: NSPanel {
    private let measureView: MeasureOverlayView

    init(measurement: ScreenMeasurement, displayFrame: CGRect, unit: MeasurementUnit) {
        var frame = measurement.rect.insetBy(dx: -56, dy: -56)
        frame = frame.intersection(displayFrame)
        if frame.isNull || frame.isEmpty || frame.width < 2 || frame.height < 2 {
            frame = measurement.rect
        }
        measureView = MeasureOverlayView(frame: CGRect(origin: .zero, size: frame.size))
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                              .stationary, .ignoresCycle]
        contentView = measureView
        measureView.measurement = measurement
        measureView.localRect = CGRect(
            x: measurement.rect.minX - frame.minX,
            y: measurement.rect.minY - frame.minY,
            width: measurement.rect.width,
            height: measurement.rect.height
        )
        measureView.localDisplayBounds = CGRect(
            x: displayFrame.minX - frame.minX,
            y: displayFrame.minY - frame.minY,
            width: displayFrame.width,
            height: displayFrame.height
        )
        measureView.unit = unit
        measureView.setAccessibilityElement(true)
        measureView.setAccessibilityRole(.group)
        measureView.setAccessibilityLabel("Measurement")
        measureView.setAccessibilityValue(measurement.lines(unit).joined(separator: ", "))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(unit: MeasurementUnit) {
        measureView.unit = unit
        measureView.setAccessibilityValue(
            measureView.measurement.map { $0.lines(unit).joined(separator: ", ") } ?? ""
        )
    }
}

private final class MeasureOverlayView: NSView {
    var measurement: ScreenMeasurement?
    var localRect: CGRect = .zero
    var localDisplayBounds: CGRect = .zero
    var unit: MeasurementUnit = .points
    var accentColor: NSColor = .controlAccentColor

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let measurement else { return }
        let rect = localRect
        // A dark hairline under the accent keeps the outline readable on white
        // and on black.
        NSColor.black.withAlphaComponent(0.45).setStroke()
        let backing = NSBezierPath(rect: rect.insetBy(dx: -0.75, dy: -0.75))
        backing.lineWidth = 2.5
        backing.stroke()
        accentColor.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1.5
        border.stroke()

        drawCornerTicks(in: rect)
        drawDimensionLabels(measurement, rect: rect)
    }

    private func drawCornerTicks(in rect: CGRect) {
        accentColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 3
        let arm: CGFloat = 12
        for corner in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
            let dx: CGFloat = corner.x == rect.minX ? 1 : -1
            let dy: CGFloat = corner.y == rect.minY ? 1 : -1
            path.move(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
            path.line(to: corner)
            path.line(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
        }
        path.stroke()
    }

    private func drawDimensionLabels(_ measurement: ScreenMeasurement, rect: CGRect) {
        let displayBounds = localDisplayBounds.isEmpty ? self.bounds : localDisplayBounds
        let bounds = displayBounds.intersection(self.bounds)
        let widthText = measurement.widthText(unit)
        let heightText = measurement.heightText(unit)

        let widthSize = labelSize(widthText)
        var widthOrigin = CGPoint(x: rect.midX - widthSize.width / 2, y: rect.maxY + 6)
        if widthOrigin.y + widthSize.height > bounds.maxY - 4 {
            widthOrigin.y = rect.minY - widthSize.height - 6
        }
        widthOrigin.x = min(max(widthOrigin.x, bounds.minX + 4), bounds.maxX - widthSize.width - 4)
        drawPill(text: widthText, origin: widthOrigin, size: widthSize)

        let heightSize = labelSize(heightText)
        var heightOrigin = CGPoint(x: rect.maxX + 6, y: rect.midY - heightSize.height / 2)
        if heightOrigin.x + heightSize.width > bounds.maxX - 4 {
            heightOrigin.x = rect.minX - heightSize.width - 6
        }
        heightOrigin.y = min(max(heightOrigin.y, bounds.minY + 4), bounds.maxY - heightSize.height - 4)
        drawPill(text: heightText, origin: heightOrigin, size: heightSize)
    }

    private func labelSize(_ text: String) -> CGSize {
        let size = (text as NSString).size(withAttributes: labelAttributes)
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    private var labelAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
    }

    private func drawPill(text: String, origin: CGPoint, size: CGSize) {
        let padding = CGSize(width: 5, height: 2.5)
        let background = CGRect(x: origin.x - padding.width, y: origin.y - padding.height,
                                width: size.width + padding.width * 2,
                                height: size.height + padding.height * 2)
        let pill = NSBezierPath(roundedRect: background, xRadius: 4, yRadius: 4)
        NSColor.black.withAlphaComponent(0.66).setFill()
        pill.fill()
        accentColor.withAlphaComponent(0.55).setStroke()
        pill.lineWidth = 1
        pill.stroke()
        (text as NSString).draw(at: origin, withAttributes: labelAttributes)
    }
}

/// The pinned readout: three monospaced lines with Copy and Close. Small and
/// non-activating, so it never takes the focus from what is being measured.
@MainActor
final class MeasureBadgeWindow: NSPanel {
    private var measurement: ScreenMeasurement
    private var unit: MeasurementUnit
    private let onCopy: () -> Void
    private let onClose: () -> Void
    private var hosting: NSHostingView<MeasureBadgeView>?

    init(measurement: ScreenMeasurement, unit: MeasurementUnit, visibleFrame: CGRect,
         onCopy: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.measurement = measurement
        self.unit = unit
        self.onCopy = onCopy
        self.onClose = onClose
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                              .stationary, .ignoresCycle]
        render(visibleFrame)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(unit: MeasurementUnit, visibleFrame: CGRect) {
        self.unit = unit
        render(visibleFrame)
    }

    private func render(_ visibleFrame: CGRect) {
        let view = MeasureBadgeView(measurement: measurement, unit: unit,
                                    onCopy: onCopy, onClose: onClose)
        let hosting = NSHostingView(rootView: view)
        self.hosting = hosting
        contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width < 1 || size.height < 1 { size = NSSize(width: 280, height: 84) }
        setFrame(MeasureLayout.badgeFrame(measurement: measurement, size: size,
                                          visibleFrame: visibleFrame),
                 display: true)
    }
}

private struct MeasureBadgeView: View {
    let measurement: ScreenMeasurement
    let unit: MeasurementUnit
    let onCopy: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(measurement.lines(unit).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(action: onCopy) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .help("Copy the measurement")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .help("Dismiss this measurement")
            }
            .font(.system(size: 10.5, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
        .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.74)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(.white.opacity(0.22), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Measurement")
        .accessibilityValue(measurement.lines(unit).joined(separator: ", "))
    }
}
