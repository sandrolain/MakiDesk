import AppKit
import Observation
import SwiftUI

/// The editor's state: the capture, the marks made so far and the tool in hand.
@Observable
@MainActor
final class ScreenshotAnnotationModel {
    let base: CGImage
    var marks: [Markup] = []
    var tool: MarkupTool = .arrow
    var colourIndex = 0
    /// The capture with the committed marks, rebuilt after each change so the
    /// preview and the exported file come from the same renderer.
    private(set) var preview: CGImage

    init(base: CGImage) {
        self.base = base
        self.preview = base
    }

    func add(_ mark: Markup) {
        marks.append(mark)
        refresh()
    }

    func undo() {
        guard marks.isEmpty == false else { return }
        marks.removeLast()
        refresh()
    }

    /// Re-renders on the main actor: a commit is a user action, and the render
    /// of even a full-screen capture is a few tens of milliseconds. The drag
    /// itself never re-renders — the unfinished stroke is drawn as a vector.
    private func refresh() {
        preview = MarkupRenderer.render(base, marks: marks) ?? base
    }
}

/// Captures an area, annotates it in place and puts the result on the shelf
/// (T40).
///
/// The area selector is the shared one (T49), so snapping, the loupe and the
/// `Esc` behaviour are the same as text recognition and the ruler. The editor
/// is one panel over the display, with the tools in a strip: no second app, no
/// file to open first.
@MainActor
final class ScreenshotAnnotationController {
    static let shared = ScreenshotAnnotationController()

    private var window: NSPanel?
    private var model: ScreenshotAnnotationModel?
    private var isSelecting = false
    private let focusReturn = PanelFocusReturn()

    private init() {}

    var isBusy: Bool { isSelecting || window != nil }

    /// Opens the selector. A second call while the selector or the editor is
    /// up is ignored: reopening would cancel the drag in progress.
    func capture() {
        guard isBusy == false else { return }
        isSelecting = true
        // A notice still on screen would be part of the capture.
        HUDController.shared.hide()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isSelecting = false }
            do {
                let selection = try await ScreenRegionSelector.shared.select()
                guard let image = selection.image else {
                    HUDController.shared.show("The area could not be captured",
                                              symbol: "exclamationmark.triangle.fill")
                    return
                }
                self.present(image: image, selection: selection)
            } catch {
                // Cancelled: nothing to say.
            }
        }
    }

    // MARK: - Editor

    private func present(image: CGImage, selection: ScreenRegionSelector.Selection) {
        let visible = screen(for: selection.display)?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let toolbarHeight: CGFloat = 44
        let scale = min(1,
                        visible.width * 0.9 / max(1, selection.rect.width),
                        (visible.height * 0.85 - toolbarHeight) / max(1, selection.rect.height))
        let displayed = CGSize(width: max(140, selection.rect.width * scale),
                               height: max(100, selection.rect.height * scale))

        let model = ScreenshotAnnotationModel(base: image)
        self.model = model
        let hosting = NSHostingView(rootView: AnnotationEditorView(
            model: model,
            imageSize: displayed,
            onDone: { [weak self] in self?.finish() },
            onCancel: { [weak self] in self?.close() }
        ))
        let panel = ScreenshotEditorPanel(
            contentRect: NSRect(origin: .zero,
                                size: CGSize(width: displayed.width,
                                             height: displayed.height + toolbarHeight)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above everything: the user is annotating what they just selected.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.sharingType = .none

        let size = panel.frame.size
        panel.setFrame(CGRect(x: (visible.midX - size.width / 2).rounded(),
                              y: (visible.midY - size.height / 2).rounded(),
                              width: size.width, height: size.height),
                       display: false)
        panel.onUndo = { [weak model] in model?.undo() }
        window = panel
        focusReturn.capture()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Renders the marks into the capture, puts the file on the shelf and, when
    /// the option is on, copies it. The shelf is the destination because it is
    /// where a capture is wanted next: drag it into a chat, a note or a folder.
    private func finish() {
        guard let model else { close(); return }
        guard let rendered = MarkupRenderer.render(model.base, marks: model.marks) else {
            close()
            return
        }
        let name = ScreenshotNaming.name(at: Date())
        let url = ShelfController.shared.add(image: rendered, name: name)
        if WorkspaceStore.shared.screenshotCopyToClipboard, let url,
           let data = try? Data(contentsOf: url) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
        }
        HUDController.shared.show(
            url == nil ? "Screenshot annotated" : "Screenshot on the shelf",
            symbol: url == nil ? "exclamationmark.triangle.fill" : "photo",
            kind: url == nil ? .warning : .success
        )
        close()
    }

    private func close() {
        guard let window else { return }
        let restore = focusReturn.takeRestoreAction(ownsKeyboard: window.isKeyWindow)
        window.orderOut(nil)
        self.window = nil
        model = nil
        restore?()
    }

    private func screen(for display: ScreenRegionDisplay) -> NSScreen? {
        NSScreen.screens.first { PaletteScreenLocation.displayID($0) == display.id }
            ?? NSScreen.main
    }
}

private final class ScreenshotEditorPanel: NSPanel {
    /// ⌘Z. Handled by the window rather than by a SwiftUI keyboard shortcut:
    /// the panel is borderless, and a key equivalent is surer here.
    var onUndo: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command,
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            onUndo?()
            return
        }
        super.keyDown(with: event)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// The editor: the capture, a vector preview of the stroke in progress, and the
/// tool strip. `Esc` cancels, `Return` saves.
private struct AnnotationEditorView: View {
    @Bindable var model: ScreenshotAnnotationModel
    let imageSize: CGSize
    let onDone: () -> Void
    let onCancel: () -> Void

    @State private var dragPoints: [CGPoint] = []

    private var theme: PaletteTheme { WorkspaceStore.shared.theme }

    var body: some View {
        VStack(spacing: 0) {
            canvas
            toolbar
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.border.opacity(0.6), lineWidth: 1)
        )
        .onExitCommand(perform: onCancel)
    }

    private var canvas: some View {
        ZStack {
            Image(decorative: model.preview, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: imageSize.width, height: imageSize.height)
            Canvas { context, size in
                guard dragPoints.count >= 2 else { return }
                draw(Markup(tool: model.tool, points: dragPoints,
                            colourIndex: model.colourIndex),
                     in: &context, size: size)
            }
            .frame(width: imageSize.width, height: imageSize.height)
            .allowsHitTesting(false)
        }
        .frame(width: imageSize.width, height: imageSize.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    let point = normalized(value.location)
                    if model.tool.isTwoPoint {
                        dragPoints = [normalized(value.startLocation), point]
                    } else {
                        if dragPoints.isEmpty { dragPoints = [point] } else { dragPoints.append(point) }
                    }
                }
                .onEnded { value in
                    let start = normalized(value.startLocation)
                    let end = normalized(value.location)
                    var points = model.tool.isTwoPoint ? [start, end] : dragPoints + [end]
                    dragPoints = []
                    guard points.count >= 2 else { return }
                    if model.tool.isTwoPoint {
                        let dx = end.x - start.x
                        let dy = end.y - start.y
                        guard (dx * dx + dy * dy).squareRoot() > 0.004 else { return }
                        points = [start, end]
                    }
                    model.add(Markup(tool: model.tool, points: points,
                                     colourIndex: model.colourIndex))
                }
        )
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            ForEach(MarkupTool.allCases) { tool in
                Button {
                    model.tool = tool
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(model.tool == tool ? theme.text : theme.subtext)
                        .frame(width: 26, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(model.tool == tool ? theme.surfaceSelected : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tool.title)
                .accessibilityLabel(tool.title)
                .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
            }

            Rectangle()
                .fill(theme.border.opacity(0.6))
                .frame(width: 1, height: 16)
                .padding(.horizontal, 4)

            ForEach(0..<MarkupPalette.colours.count, id: \.self) { index in
                Button {
                    model.colourIndex = index
                } label: {
                    Circle()
                        .fill(swatch(index))
                        .frame(width: 13, height: 13)
                        .padding(2)
                        .overlay(
                            Circle()
                                .strokeBorder(model.colourIndex == index ? theme.text : .clear,
                                              lineWidth: 2)
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(MarkupPalette.colours[index].name)
                .accessibilityLabel(MarkupPalette.colours[index].name)
            }

            Spacer(minLength: 8)

            Button {
                model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(model.marks.isEmpty ? theme.subtext.opacity(0.5) : theme.text)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.marks.isEmpty)
            .help("Undo the last mark")
            .accessibilityLabel("Undo")

            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(theme.subtext)
                .keyboardShortcut(.cancelAction)
                .help("Esc — nothing is saved")

            Button("Save", action: onDone)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(theme.accent)
                .keyboardShortcut(.defaultAction)
                .help("Return — puts it on the shelf")
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(theme.surface)
    }

    private func swatch(_ index: Int) -> Color {
        let entry = MarkupPalette.colours[index]
        return Color(.sRGB, red: entry.red, green: entry.green, blue: entry.blue)
    }

    private func normalized(_ point: CGPoint) -> CGPoint {
        Markup.clamped(CGPoint(x: point.x / max(1, imageSize.width),
                               y: point.y / max(1, imageSize.height)))
    }

    /// The unfinished stroke, drawn as a vector: the committed marks are pixels
    /// from the renderer, this one only has to look right while dragging.
    private func draw(_ mark: Markup, in context: inout GraphicsContext, size: CGSize) {
        let colour = swatch(mark.colourIndex)
        let points = mark.points.map {
            CGPoint(x: $0.x * size.width, y: $0.y * size.height)
        }
        guard points.count >= 2 else { return }
        switch mark.tool {
        case .rectangle:
            let rect = CGRect(x: min(points[0].x, points[1].x),
                              y: min(points[0].y, points[1].y),
                              width: abs(points[1].x - points[0].x),
                              height: abs(points[1].y - points[0].y))
            context.stroke(Path(rect), with: .color(colour),
                           style: StrokeStyle(lineWidth: previewWidth, lineCap: .round))
        case .arrow:
            var path = Path()
            path.move(to: points[0])
            path.addLine(to: points[1])
            let dx = points[1].x - points[0].x
            let dy = points[1].y - points[0].y
            let length = (dx * dx + dy * dy).squareRoot()
            if length > 1 {
                let angle = atan2(dy, dx)
                let head = min(max(previewWidth * 3.4, 9), 46)
                let spread = CGFloat.pi / 7
                path.move(to: points[1])
                path.addLine(to: CGPoint(x: points[1].x - head * cos(angle - spread),
                                         y: points[1].y - head * sin(angle - spread)))
                path.move(to: points[1])
                path.addLine(to: CGPoint(x: points[1].x - head * cos(angle + spread),
                                         y: points[1].y - head * sin(angle + spread)))
            }
            context.stroke(path, with: .color(colour),
                           style: StrokeStyle(lineWidth: previewWidth, lineCap: .round,
                                              lineJoin: .round))
        case .pixelate:
            let rect = CGRect(x: min(points[0].x, points[1].x),
                              y: min(points[0].y, points[1].y),
                              width: abs(points[1].x - points[0].x),
                              height: abs(points[1].y - points[0].y))
            context.stroke(Path(rect), with: .color(colour),
                           style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        case .pen, .highlighter:
            var path = Path()
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            context.stroke(path,
                           with: .color(colour.opacity(mark.tool == .highlighter ? 0.45 : 1)),
                           style: StrokeStyle(lineWidth: mark.tool == .highlighter
                                              ? previewWidth * 4.2 : previewWidth,
                                              lineCap: .round, lineJoin: .round))
        }
    }

    private var previewWidth: CGFloat {
        min(max(min(imageSize.width, imageSize.height) * 0.0038, 2.5), 12)
    }
}
