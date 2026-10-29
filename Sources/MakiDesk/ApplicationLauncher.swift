import AppKit
import Observation
import SwiftUI

/// The state of the application launcher (T37): what has been typed, which row
/// is chosen, and the inventory it is drawn from.
@Observable
@MainActor
final class ApplicationLauncherModel {
    var text = ""
    var selection = 0
    var applications: [InstalledApplication] = []
    var usage: [String: ApplicationUsage] = [:]
    var isLoading = false
    var icons: [String: NSImage] = [:]

    /// Recent use only orders an empty field and breaks ties; it never lifts an
    /// application over a better name match.
    var results: [InstalledApplication] {
        ApplicationSearch.launcherResults(applications, query: text, usage: usage)
    }

    /// Keeps the highlight inside the list, which changes as the user types.
    func clampSelection() {
        let count = results.count
        selection = count == 0 ? 0 : min(max(selection, 0), count - 1)
    }

    func move(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    /// One icon at a time, when its row is about to draw. The cache is bounded
    /// and emptied when the panel closes.
    func loadIcon(_ application: InstalledApplication) {
        guard icons[application.id] == nil else { return }
        icons[application.id] = NSWorkspace.shared.icon(forFile: application.path)
        if icons.count > 32 {
            let keep = Set(results.map(\.id))
            icons = icons.filter { keep.contains($0.key) }
        }
    }
}

/// The fast application launcher (T37): a field, the matching installed
/// applications and nothing else.
///
/// It is separate from the window palette on purpose. The palette answers
/// "where is that window"; this answers "open that app", with the whole panel
/// and every key spent on the one answer. Recent use comes from
/// `ApplicationUsageStore`, the scan from `ApplicationCatalog`, so neither is
/// duplicated.
@MainActor
final class ApplicationLauncherController {
    static let shared = ApplicationLauncherController()

    let model = ApplicationLauncherModel()
    private var window: ApplicationLauncherPanel?
    private let focusReturn = PanelFocusReturn()
    private let usageStore: ApplicationUsageStore

    init(usageStore: ApplicationUsageStore? = nil) {
        self.usageStore = usageStore ?? .shared
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil { build() }
        guard let window else { return }
        model.text = ""
        model.selection = 0
        model.usage = usageStore.usage
        loadApplications()
        place(window)
        focusReturn.capture()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard let window, window.isVisible else { return }
        let restore = focusReturn.takeRestoreAction(ownsKeyboard: window.isKeyWindow)
        window.orderOut(nil)
        restore?()
    }

    /// Opens the highlighted application. A command-held Return asks Launch
    /// Services for a new instance; the app is remembered only once it opened.
    func openSelected(newInstance: Bool) {
        let results = model.results
        guard results.indices.contains(model.selection) else { return }
        open(results[model.selection], newInstance: newInstance)
    }

    func open(_ application: InstalledApplication, newInstance: Bool) {
        hide()
        ApplicationCatalog.shared.launch(application, newInstance: newInstance) { [weak self] error in
            guard let self else { return }
            if let error {
                HUDController.shared.show("Could not open \(application.name)",
                                          symbol: "exclamationmark.triangle.fill")
                makiLog.error("application launch failed: \(error.localizedDescription, privacy: .private)")
            } else {
                self.usageStore.record(application)
                self.model.usage = self.usageStore.usage
                WorkspaceStore.shared.status = "\(application.name) · launched"
            }
        }
    }

    private func loadApplications() {
        if model.applications.isEmpty { model.isLoading = true }
        ApplicationCatalog.shared.loadIfNeeded { [weak self] applications in
            guard let self else { return }
            self.model.applications = applications
            self.model.isLoading = false
            self.model.clampSelection()
        }
        // A fresh catalog answers synchronously; a stale one keeps the spinner
        // until the worker publishes.
        model.isLoading = ApplicationCatalog.shared.isLoading
    }

    private func build() {
        let hosting = NSHostingView(rootView: ApplicationLauncherView(
            model: model,
            onSubmit: { [weak self] newInstance in self?.openSelected(newInstance: newInstance) },
            onCancel: { [weak self] in self?.hide() },
            onPick: { [weak self] application in self?.open(application, newInstance: false) }
        ))
        let panel = ApplicationLauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        window = panel
    }

    private func place(_ window: NSWindow) {
        guard let screen = PaletteScreenLocation.focusedWindow.targetScreen() else { return }
        let size = window.frame.size
        let visible = screen.visibleFrame
        window.setFrame(CGRect(x: (visible.midX - size.width / 2).rounded(),
                               y: (visible.midY - size.height / 2).rounded(),
                               width: size.width, height: size.height),
                        display: false)
    }
}

private final class ApplicationLauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// The card: the field, the applications, and what the keys do.
private struct ApplicationLauncherView: View {
    @Bindable var model: ApplicationLauncherModel
    let onSubmit: (Bool) -> Void
    let onCancel: () -> Void
    let onPick: (InstalledApplication) -> Void

    private var theme: PaletteTheme { WorkspaceStore.shared.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.accent)
                PaletteTextField(text: $model.text,
                                 placeholder: "Open an application",
                                 onSubmit: onSubmit,
                                 onCancel: onCancel,
                                 onMove: { model.move($0) })
                    .frame(height: 26)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, application in
                            row(application, selected: index == model.selection)
                                .id(application.id)
                                .onAppear { model.loadIcon(application) }
                                .onTapGesture { onPick(application) }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .onChange(of: model.selection) { _, selection in
                    let results = model.results
                    guard results.indices.contains(selection) else { return }
                    proxy.scrollTo(results[selection].id, anchor: .center)
                }
            }

            HStack(spacing: 6) {
                if model.results.isEmpty {
                    Text(emptyMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.subtext)
                        .lineLimit(1)
                } else {
                    Text("↑↓ choose · ⏎ open · ⌘⏎ new instance · esc closes")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.subtext)
                }
                Spacer(minLength: 0)
                if model.isLoading {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(theme.border.opacity(0.6), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onChange(of: model.text) { _, _ in
            model.selection = 0
            model.clampSelection()
        }
    }

    private var emptyMessage: String {
        if model.isLoading { return "Looking for installed applications…" }
        if model.applications.isEmpty { return "No applications found in /Applications or ~/Applications" }
        if model.text.isEmpty { return "No application has been opened yet" }
        return "No installed application matches"
    }

    private func row(_ application: InstalledApplication, selected: Bool) -> some View {
        HStack(spacing: 10) {
            if let icon = model.icons[application.id] {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 26, height: 26)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 20))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(theme.subtext)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(application.name)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Text(application.executable)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.subtext)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? theme.surfaceSelected : Color.clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(application.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
