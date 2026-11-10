import AppKit
import MakiShared
import SwiftUI

struct SettingsView: View {
    @Bindable var store: WorkspaceStore

    enum SettingsTab: String, CaseIterable, Identifiable {
        /// The persisted selection. `MakiDeskApp` writes it before opening the
        /// window and `@AppStorage` reads it here, so the literal lives once.
        static let defaultsKey = SettingsKey.settingsTab.rawValue

        case general, windows, layouts, panels, terminal, notifications, groups, system, dropzones

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .windows: return "Windows"
            case .layouts: return "Layouts"
            case .panels: return "Panels"
            case .terminal: return "Terminal"
            case .notifications: return "Notifications"
            case .groups: return "Groups"
            case .system: return "System"
            case .dropzones: return "Dropzones"
            }
        }

        /// The sidebar's glyph, the same vocabulary as the menu bar.
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .windows: return "macwindow"
            case .layouts: return "rectangle.split.3x1"
            case .panels: return "rectangle.on.rectangle"
            case .terminal: return "terminal"
            case .notifications: return "bell"
            case .groups: return "square.grid.2x2"
            case .system: return "gauge"
            case .dropzones: return "bolt.square"
            }
        }
    }

    /// The sections inside a page, when it holds enough of them to split (T58).
    private enum GeneralPage: String, CaseIterable, Identifiable {
        case permissions, behaviour, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .permissions: return "Permissions"
            case .behaviour: return "Behaviour"
            case .about: return "About"
            }
        }
    }

    private enum WindowsPage: String, CaseIterable, Identifiable {
        case placement, focus, overlay, macOS
        var id: String { rawValue }
        var title: String {
            switch self {
            case .placement: return "Placement"
            case .focus: return "Focus"
            case .overlay: return "Overlay"
            case .macOS: return "macOS"
            }
        }
    }

    private enum PanelsPage: String, CaseIterable, Identifiable {
        case shelf, cards, switcher, look, tools, pointer, bar
        var id: String { rawValue }
        var title: String {
            switch self {
            case .shelf: return "Shelf"
            case .cards: return "Cards"
            case .switcher: return "Switcher"
            case .look: return "Look"
            case .tools: return "Tools"
            case .pointer: return "Pointer"
            case .bar: return "Utility bar"
            }
        }
    }

    private enum NotificationsPage: String, CaseIterable, Identifiable {
        case placement, behaviour, appearance, history
        var id: String { rawValue }
        var title: String {
            switch self {
            case .placement: return "Placement"
            case .behaviour: return "Behaviour"
            case .appearance: return "Appearance"
            case .history: return "History"
            }
        }
    }

    /// The sidebar column, on the window's own background.
    private static let sidebarWidth: CGFloat = 212
    /// Shared with the window configurator: the sidebar needs the width the tab
    /// bar did not, so the content keeps its old room at the smallest size.
    static let minimumSize = CGSize(width: 800, height: 580)

    @AppStorage(SettingsTab.defaultsKey) private var settingsTab: SettingsTab = .general
    @AppStorage(SettingsKey.keepTerminalWindowShortcuts.rawValue)
    private var keepTerminalWindowShortcuts = true
    @AppStorage(ColorSamplerController.formatDefaultsKey)
    private var colorFormat: ColorClipboardFormat = .hex
    // The notice settings go through the store like every other preference:
    // `@AppStorage` carried its own copy of each default, which is exactly the
    // duplication the settings table exists to end (R02).
    private var hudPosition: Binding<HUDPosition> {
        Binding(get: { store.hudPosition }, set: { store.updateHUDPosition($0) })
    }

    private var hudScreen: Binding<PaletteScreenLocation> {
        Binding(get: { store.hudScreen }, set: { store.updateHUDScreen($0) })
    }

    private var hudBaseDuration: Binding<Double> {
        Binding(get: { store.hudBaseDuration }, set: { store.updateHUDBaseDuration($0) })
    }

    private var hudTextSize: Binding<Double> {
        Binding(get: { store.hudTextSize }, set: { store.updateHUDTextSize($0) })
    }

    private var hudHistoryEnabled: Binding<Bool> {
        Binding(get: { store.hudHistoryEnabled }, set: { store.updateHUDHistoryEnabled($0) })
    }

    private var hudVoiceOver: Binding<Bool> {
        Binding(get: { store.hudVoiceOver }, set: { store.updateHUDVoiceOver($0) })
    }

    private var hudCompact: Binding<Bool> {
        Binding(get: { store.hudCompact }, set: { store.updateHUDCompact($0) })
    }

    private var hudKeepErrors: Binding<Bool> {
        Binding(get: { store.hudKeepErrors }, set: { store.updateHUDKeepErrors($0) })
    }

    @State private var system = SystemMonitor.shared

    private var systemDiskMode: Binding<DiskMenuBarMode> {
        Binding(get: { system.diskMenuBarMode }, set: { system.updateDiskMenuBarMode($0) })
    }

    private var systemDiskFormat: Binding<DiskSpaceFormat> {
        Binding(get: { system.diskFormat }, set: { system.updateDiskFormat($0) })
    }

    private var systemDiskThreshold: Binding<Double> {
        Binding(get: { system.diskWarningThresholdGB },
                set: { system.updateDiskWarningThresholdGB($0) })
    }

    private var systemCPUEnabled: Binding<Bool> {
        Binding(get: { system.cpuAlertsEnabled }, set: { system.updateCPUAlertsEnabled($0) })
    }

    private var systemCPUThreshold: Binding<Double> {
        Binding(get: { system.cpuThresholdPercent },
                set: { system.updateCPUThresholdPercent($0) })
    }

    private var systemCPUDuration: Binding<Double> {
        Binding(get: { system.cpuSustainedMinutes },
                set: { system.updateCPUSustainedMinutes($0) })
    }

    private var systemNotifications: Binding<Bool> {
        Binding(get: { system.systemNotificationsEnabled },
                set: { system.updateSystemNotifications($0) })
    }

    /// The label's own figure, independent of whether the warning policy
    /// currently shows it: the preview explains the format, and "Hidden" is
    /// only the explicit choice.
    private var systemDiskPreview: String {
        if system.diskMenuBarMode == .never { return "Hidden" }
        guard let space = system.diskSpace else { return "Reading…" }
        return DiskSpaceText.menuBar(space, format: system.diskFormat)
    }
    /// The highlight slides between sidebar rows (T58). Respects the app's
    /// animations switch and macOS Reduce Motion through the store.
    @Namespace private var sidebarSelection
    @State private var hoveredTab: SettingsTab?
    @State private var generalPage: GeneralPage = .permissions
    @State private var windowsPage: WindowsPage = .placement
    @State private var panelsPage: PanelsPage = .shelf
    @State private var notificationsPage: NotificationsPage = .placement
    @State private var showResetConfirmation = false
    @State private var excludedAppsText = ""
    /// Owned here, not by the section, so switching sections does not throw
    /// away a draft.
    @StateObject private var dropzoneEditor = DropzoneEditorModel()

    private static let gapOptions: [Double] = [0, 2, 4, 8, 12, 16, 24, 32, 48, 64]

    /// The same theme the palette, the panels and the overlay paint with, so
    /// Settings stops being the one window in system colours (T42).
    private var theme: PaletteTheme { store.theme }

    /// One short curve for the sidebar, the page tabs and the page change.
    private var selectionAnimation: Animation? {
        store.effectiveAnimationsEnabled ? .easeOut(duration: 0.16) : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Rectangle()
                    .fill(theme.border.opacity(0.6))
                    .frame(width: 1)
                content
                    .animation(selectionAnimation, value: settingsTab)
            }
        }
        .frame(minWidth: Self.minimumSize.width,
               idealWidth: 900,
               minHeight: Self.minimumSize.height,
               idealHeight: 740)
        .makiSurface(.window, theme: theme, fill: theme.background)
        .preferredColorScheme(theme.followsSystemAppearance ? nil : (theme.isDark ? .dark : .light))
        .tint(theme.accent)
        .environment(\.paletteTheme, theme)
        .toggleStyle(.switch)
        .sheet(isPresented: $showResetConfirmation) {
            ResetConfirmationView(store: store) { scope in
                showResetConfirmation = false
                store.resetToDefaults(scope: scope)
            } onCancel: {
                showResetConfirmation = false
            }
        }
        .onAppear {
            excludedAppsText = store.shelfExcludedApps.joined(separator: ", ")
        }
    }

    // MARK: - Window and sections

    /// One column of sections, like System Settings. The raw values are the
    /// ones the tab bar wrote, so an existing choice and the menu's deep links
    /// keep pointing at the same section (T58).
    private var sidebar: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    sidebarRow(tab)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .animation(selectionAnimation, value: settingsTab)
        }
        .frame(width: Self.sidebarWidth)
        // A slightly lifted column, like the native sidebars: the content
        // area keeps the window background, the navigation does not.
        .background(theme.raisedSurface.opacity(0.55))
    }

    private func sidebarRow(_ tab: SettingsTab) -> some View {
        let selected = settingsTab == tab
        return Button {
            guard settingsTab != tab else { return }
            settingsTab = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? theme.accent : theme.subtext)
                    .frame(width: 21)
                Text(tab.title)
                    .font(.system(size: 14.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? theme.text : theme.subtext)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: MakiRadius.field)
                        .fill(theme.surfaceSelected)
                        .matchedGeometryEffect(id: "settings-section", in: sidebarSelection)
                } else if hoveredTab == tab {
                    RoundedRectangle(cornerRadius: MakiRadius.field)
                        .fill(theme.surfaceSelected.opacity(0.45))
                }
            }
            .overlay(alignment: .leading) {
                // The accent is a second cue, not the only one: the row is
                // also filled and bold, so colour is never the sole signal.
                if selected {
                    Capsule()
                        .fill(theme.accent)
                        .frame(width: 3, height: 17)
                        .padding(.leading, 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredTab = tab }
            else if hoveredTab == tab { hoveredTab = nil }
        }
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(tab.title)
    }

    /// The sections of one page, as a strip of chips. The choice lives for the
    /// session: it is a place inside a page, not a stored preference.
    private func pageTabs<T: Hashable & Identifiable>(
        _ tabs: [T],
        selection: Binding<T>,
        title: @escaping (T) -> String
    ) -> some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                let selected = selection.wrappedValue == tab
                Button {
                    selection.wrappedValue = tab
                } label: {
                    Text(title(tab))
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? theme.text : theme.subtext)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: MakiRadius.control)
                                .fill(selected ? theme.surfaceSelected : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: MakiRadius.row).fill(theme.raisedSurface))
        .overlay(RoundedRectangle(cornerRadius: MakiRadius.row)
            .stroke(theme.border.opacity(0.6), lineWidth: 1))
        .animation(selectionAnimation, value: selection.wrappedValue)
    }

    /// The selected section, unchanged: Dropzones keeps the whole height for
    /// its master-detail editor, everything else scrolls.
    @ViewBuilder
    private var content: some View {
        if settingsTab == .dropzones {
            DropzoneSettingsView(model: dropzoneEditor)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .font(MakiType.reading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch settingsTab {
                    case .general: generalTab
                    case .windows: windowsTab
                    case .layouts: layoutsTab
                    case .panels: panelsTab
                    case .terminal: terminalTab
                    case .notifications: notificationsTab
                    case .groups: groupsTab
                    case .system: systemTab
                    case .dropzones: EmptyView()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                // A touch larger than the system default: the window holds a
                // lot of small print (T58).
                .font(MakiType.reading)
            }
            .id(settingsTab)
            .transition(.opacity)
        }
    }

    // MARK: - General

    @ViewBuilder
    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageTabs(GeneralPage.allCases, selection: $generalPage) { $0.title }
            if generalPage == .permissions {
                SettingsSection("Permissions") {
                    Label(
                        store.accessibilityTrusted ? "Accessibility enabled" : "Accessibility required",
                        systemImage: store.accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(store.accessibilityTrusted ? .green : .orange)

                    Label(
                        store.screenRecordingTrusted ? "Screen Recording enabled" : "Screen Recording not granted",
                        systemImage: store.screenRecordingTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(store.screenRecordingTrusted ? .green : .orange)

                    Label(
                        store.shortcutsBlocked == 0
                            ? "Shortcuts active (\(store.shortcutsRegistered))"
                            : "\(store.shortcutsBlocked) shortcuts taken by another app",
                        systemImage: store.shortcutsBlocked == 0 ? "keyboard" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(store.shortcutsBlocked == 0 ? .green : .orange)
                    if store.shortcutsBlocked > 0, store.blockedShortcutTitles.isEmpty == false {
                        Text(store.blockedShortcutTitles.prefix(4).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        caption("Another app owns those combinations, so the menu is the fallback. The shortcut window also marks the affected rows.")
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack { permissionButtons }
                        VStack(alignment: .leading) { permissionButtons }
                    }
                    caption("Enable MakiDesk under System Settings ▸ Privacy & Security. Window previews need Screen Recording; without it the switcher shows app icons instead. If a permission stays “required” after a rebuild: remove MakiDesk with “−”, re-add it, or run `tccutil reset Accessibility com.makidesk.app`.")
                }
                SettingsSection("Diagnostics") {
                    HStack(spacing: 12) {
                        Button("Copy diagnostics") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(store.diagnostics.text, forType: .string)
                        }
                        Text("Versions, permissions and counts only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    caption("Puts a short report on the clipboard for a bug report: the app and macOS versions, which permissions are on, how many shortcuts are active, taken or customised, the state of shortcuts.json and how many windows and groups are known. No window titles, note text, clipboard content, file paths or screenshots.")
                }
            }
            if generalPage == .behaviour {
                SettingsSection("Animations") {
                    Toggle("Animate lists, panels and window resizing", isOn: Binding(
                        get: { store.animationsEnabled },
                        set: { store.updateAnimationsEnabled($0) }
                    ))
                    SliderRow(title: "Duration",
                              value: Binding(get: { store.animationDuration },
                                             set: { store.updateAnimationDuration($0) }),
                              range: 0.08...0.6, step: 0.02, unit: " s", decimals: 2)
                        .disabled(!store.animationsEnabled)
                    caption("Controls shelf movement, window resizing, switcher transitions and clipboard scrolling. MakiDesk keeps enhanced Accessibility UI disabled for Chromium apps; VoiceOver and Switch Control are respected. macOS Reduce Motion always wins.")
                }
            }
            if generalPage == .about {
                SettingsSection("Build") {
                    LabeledContent("Version", value: store.bundleVersion)
                    LabeledContent("Bundle ID", value: store.bundleIdentifier)
                    Label(
                        store.isInApplications ? "Installed in /Applications" : "Run from build folder — permissions may reset",
                        systemImage: store.isInApplications ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(store.isInApplications ? .green : .orange)
                    caption("macOS ties permissions to the app's location. Install MakiDesk in /Applications to keep them across rebuilds.")
                }
                SettingsSection("Reference") {
                    Button {
                        ShortcutsWindowController.shared.show()
                    } label: {
                        Label("Keyboard Shortcuts…", systemImage: "keyboard")
                    }
                    caption("Every command, grouped by where it works: window tiling, layouts, groups, focus, the switcher, notes and the clipboard.")
                }
                SettingsSection("Licensing") {
                    Button("MakiDesk license (MIT)") {
                        openBundledDocument("LICENSE", extension: nil)
                    }
                    Button("Third-party notices") {
                        openBundledDocument("THIRD_PARTY_NOTICES", extension: "md")
                    }
                    caption("MakiDesk is MIT-licensed. The third-party components used by the notes editor and their licences are in the notices above. Both files are included in the app bundle and the DMG.")
                }
                SettingsSection {
                    Button(role: .destructive) {
                        showResetConfirmation = true
                    } label: {
                        Label("Reset to defaults…", systemImage: "arrow.counterclockwise")
                    }
                    caption("Puts every option in this window back to its default value. The confirmation asks whether your window groups go too. Onboarding completion and the macOS ⌥-tiling setting are always left untouched.")
                }
            }
        }
        .animation(selectionAnimation, value: generalPage)
    }


    // MARK: - Windows

    @ViewBuilder
    private var windowsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageTabs(WindowsPage.allCases, selection: $windowsPage) { $0.title }
            if windowsPage == .placement {
                SettingsSection("Placement") {
                    Picker("Gap", selection: Binding(get: { store.gap }, set: { store.updateGap($0) })) {
                        ForEach(Self.gapOptions, id: \.self) { Text("\(Int($0)) px").tag($0) }
                    }
                    caption("Space kept between tiled windows and at the screen edges.")

                    Picker("Drag to snap", selection: Binding(
                        get: { store.dragActivator },
                        set: { store.updateDragActivator($0) }
                    )) {
                        ForEach(DragActivator.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Enable drag to snap", isOn: Binding(
                        get: { store.dragEnabled },
                        set: { store.updateDragEnabled($0) }
                    ))
                    caption("Hold these keys while dragging a window to snap it to the nearest half / golden position. Control is not offered: ⌃-click opens context menus (it is macOS's secondary click).")
                }
            }
            if windowsPage == .focus {
                SettingsSection("Focus border") {
                    Toggle("Outline the focused window", isOn: Binding(
                        get: { store.focusBorderEnabled },
                        set: { store.updateFocusBorderEnabled($0) }
                    ))
                    SliderRow(title: "Width",
                              value: Binding(get: { store.focusBorderWidth },
                                             set: { store.updateFocusBorderWidth($0) }),
                              range: FocusBorder.widthRange, step: 1,
                              unit: " pt", decimals: 0)
                        .disabled(!store.focusBorderEnabled)
                    caption("A border in the theme accent follows the focused window, including MakiDesk's own windows. It is hidden for full-screen windows, the desktop and windows that cannot take keyboard focus. It needs no permission beyond Accessibility.")
                }
                SettingsSection("Focus dim") {
                    Toggle("Dim everything but the focused window", isOn: Binding(
                        get: { store.focusDimEnabled },
                        set: { store.updateFocusDimEnabled($0) }
                    ))
                    caption("A dark veil covers what is behind the focused window; the window itself and everything above it stay clear. It follows the window as you move or resize it and needs no permission beyond Accessibility. Menu bar, Dock and MakiDesk's own panels stay above the veil; it is left out of screenshots and recordings. With “Selected windows”, ⌥-click windows in the switcher (or press ⌥K on the highlighted one) to keep them sharp: when the switcher closes their apps are brought forward, in reverse pick order, and the veil goes under the lowest of them, dimming everything below.")

                    SliderRow(title: "Opacity",
                              value: Binding(get: { store.focusDimOpacity },
                                             set: { store.updateFocusDimOpacity($0) }),
                              range: FocusDim.opacityRange, step: 0.05,
                              unit: "%", percent: true)
                        .disabled(!store.focusDimEnabled)
                    SliderRow(title: "Fade",
                              value: Binding(get: { store.focusDimFade },
                                             set: { store.updateFocusDimFade($0) }),
                              range: FocusDim.fadeRange, step: 0.05,
                              unit: " s", decimals: 2)
                        .disabled(!store.focusDimEnabled)

                    Picker("Keep sharp", selection: Binding(
                        get: { store.focusDimSource },
                        set: { store.updateFocusDimSource($0) }
                    )) {
                        ForEach(FocusDim.Source.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(!store.focusDimEnabled)

                    Picker("Displays", selection: Binding(
                        get: { store.focusDimDisplayMode },
                        set: { store.updateFocusDimDisplayMode($0) }
                    )) {
                        ForEach(FocusDim.DisplayMode.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(!store.focusDimEnabled)

                    Picker("Colour", selection: Binding(
                        get: { store.focusDimColour },
                        set: { store.updateFocusDimColour($0) }
                    )) {
                        ForEach(FocusDim.Colour.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(!store.focusDimEnabled)

                    Toggle("Dim the desktop too", isOn: Binding(
                        get: { store.focusDimDesktopDims },
                        set: { store.updateFocusDimDesktopDims($0) }
                    ))
                    .disabled(!store.focusDimEnabled)

                    Toggle("Turn off when you switch apps", isOn: Binding(
                        get: { store.focusDimStopsOnAppChange },
                        set: { store.updateFocusDimStopsOnAppChange($0) }
                    ))
                    .disabled(!store.focusDimEnabled)
                    caption("Off, the veil follows whichever window you focus, in any app. On, the first switch to another app ends it. Reduce Transparency turns the veil into a solid surface and Reduce Motion removes the fade.")
                }
            }
            if windowsPage == .overlay {
                SettingsSection("Overlay") {
                    Toggle("Show overlay", isOn: Binding(
                        get: { store.showMiniMap },
                        set: { store.updateMiniMapVisibility($0) }
                    ))
                    Picker("Position", selection: Binding(
                        get: { store.miniMapPosition },
                        set: { store.updateMiniMapPosition($0) }
                    )) {
                        ForEach(PalettePosition.allCases) { Text($0.label).tag($0) }
                    }
                    SliderRow(title: "Size",
                              value: Binding(get: { store.overlayScale }, set: { store.updateOverlayScale($0) }),
                              range: 0.7...1.6, unit: "×", decimals: 2)
                    SliderRow(title: "Opacity",
                              value: Binding(get: { store.overlayOpacity }, set: { store.updateOverlayOpacity($0) }),
                              range: 0.4...1.0, unit: "%", percent: true)
                    caption("The overlay previews the layout while commands run and when you switch windows. It appears at the chosen screen corner.")
                }
            }
            if windowsPage == .macOS {
                SettingsSection("macOS integration") {
                    Label(
                        store.macOSTilingEnabled
                            ? "macOS also tiles when you drag with ⌥"
                            : "macOS ⌥-tiling is off — MakiDesk handles ⌥-drag",
                        systemImage: store.macOSTilingEnabled ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                    )
                    .foregroundStyle(store.macOSTilingEnabled ? .orange : .green)

                    Toggle("Let macOS tile windows when dragging with ⌥", isOn: Binding(
                        get: { store.macOSTilingEnabled },
                        set: { store.updateMacOSTiling($0) }
                    ))

                    caption("MakiDesk's ⌥-drag is a richer replacement for the system one (it snaps to the nearest half / golden position). When the macOS setting above is on, both react at once — leave it off so only MakiDesk moves the window. Same switch as System Settings ▸ Desktop & Dock ▸ Windows ▸ “Hold ⌥ key while dragging windows to tile”.")
                }
            }
        }
        .animation(selectionAnimation, value: windowsPage)
    }


    // MARK: - Layouts

    @ViewBuilder
    private var layoutsTab: some View {
        SettingsSection("Layouts") {
            Toggle("Ask before using the suggested layout", isOn: Binding(
                get: { store.layoutAsksFirst },
                set: { store.updateLayoutAsksFirst($0) }
            ))
            caption("Four keys lay out the windows in view (minimised ones and windows of hidden apps stay where they are): ⌃⌥G a grid, ⌃⌥S the golden spiral, ⌃⌥A the suggested layout, ⌃⌥W areas weighted by the content each window shows. The suggestion sees how many windows there are, how much is drawn in each one (needs Screen Recording), what kind of app they are and how big they are, and says why. With this on, the suggestion appears with its reason and waits to be run again; with it off, it applies at once. Without Screen Recording the weighted layout still uses the weights below, and the suggestion falls back to equal cells.")

            Text("Content weights")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.text)
                .padding(.top, 4)
            ForEach(WindowKind.allCases, id: \.self) { kind in
                HStack(spacing: 10) {
                    Text(kind.label)
                        .frame(width: 76, alignment: .leading)
                    Slider(value: Binding(
                        get: { store.layoutPrior(kind) },
                        set: { store.updateLayoutPrior($0, for: kind) }
                    ), in: 0.5...2.0, step: 0.05)
                    Text(String(format: "%.2f", store.layoutPrior(kind)))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(theme.subtext)
                        .frame(width: 32, alignment: .trailing)
                }
            }
            caption("How much room a window of that kind deserves before its content adjusts the weight (0.5–2.0). The same numbers are used by the suggested layout: it proposes Content only when the spread is clear.")
        }
    }

    // MARK: - Panels

    @ViewBuilder
    private var panelsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageTabs(PanelsPage.allCases, selection: $panelsPage) { $0.title }
            if panelsPage == .shelf {
                SettingsSection("Shelf") {
                    Toggle("Shake while dragging to open the shelf", isOn: Binding(
                        get: { store.shelfShakeEnabled },
                        set: { store.updateShelfShakeEnabled($0) }
                    ))
                    Picker("Shake sensitivity", selection: Binding(
                        get: { store.shelfShakeSensitivity },
                        set: { store.updateShelfShakeSensitivity($0) }
                    )) {
                        ForEach(ShelfShakeSensitivity.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(!store.shelfShakeEnabled)
                    TextField("Excluded apps (bundle IDs, comma-separated)", text: $excludedAppsText)
                        .disabled(!store.shelfShakeEnabled)
                        .onChange(of: excludedAppsText) { _, value in
                            store.updateShelfExcludedApps(value)
                        }
                    caption("⌃⌥D opens the shelf near the pointer; the shake opens it during a drag. It collects files, folders, links, text and images, lets you drag them out or copy/move them to a folder, and empties when closed. Space previews, Delete removes, Esc closes. The shelf is temporary: nothing is written to disk except files promised by apps such as Photos, in a temporary folder removed on close.")
                }
            }
            if panelsPage == .cards {
                SettingsSection("Checklist") {
                    Toggle("Show the checklist", isOn: Binding(
                        get: { store.checklistVisible },
                        set: { store.updateChecklistVisible($0) }
                    ))
                    SliderRow(title: "Opacity",
                              value: Binding(get: { store.checklistOpacity },
                                             set: { store.updateChecklistOpacity($0) }),
                              range: ChecklistSettings.opacityRange, step: 0.05,
                              unit: "%", percent: true)
                        .disabled(!store.checklistVisible)
                    SliderRow(title: "Width",
                              value: Binding(get: { store.checklistWidth },
                                             set: { store.updateChecklistWidth($0) }),
                              range: ChecklistSettings.widthRange, step: 10,
                              unit: " pt", decimals: 0)
                        .disabled(!store.checklistVisible)
                    Picker("Corner", selection: Binding(
                        get: { store.checklistPosition },
                        set: { store.updateChecklistPosition($0) }
                    )) {
                        ForEach(HUDPosition.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(!store.checklistVisible)
                    Picker("Show on", selection: Binding(
                        get: { store.checklistScreen },
                        set: { store.updateChecklistScreen($0) }
                    )) {
                        ForEach(PaletteScreenLocation.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(!store.checklistVisible)
                    caption("⌃⌥L shows or hides a small card with the items you tick off; it stays above the other apps, in the chosen corner at the same distance from the edges as a tiled window (half the Gap in Settings ▸ Windows). Opacity is the resting value: pointing at the card or typing in it brings it to 100% until the pointer leaves, so the setting only applies while it waits. Ticking a box does not take the keyboard away from the app you are in — clicking the list takes the keys and opens the add field, and Esc closes the card, giving the keys back. Items can be copied from their menu, and dragging a row reorders it. The card follows the display of the last window focus or pointer move, like the countdown card, the switcher and the search box. The trash sits in the add row, appears only when there is something ticked and clears just those items. Items live in checklist.json next to your groups, survive a restart and are left alone by a factory reset; the card is left out of screenshots and recordings, its height follows the list, and Reduce Transparency makes it solid.")
                }
                SettingsSection("Timers") {
                    Toggle("Show the countdown card", isOn: Binding(
                        get: { store.timerOverlayVisible },
                        set: { store.updateTimerOverlayVisible($0) }
                    ))
                    SliderRow(title: "Opacity",
                              value: Binding(get: { store.timerOverlayOpacity },
                                             set: { store.updateTimerOverlayOpacity($0) }),
                              range: TimerSettings.opacityRange, step: 0.05,
                              unit: "%", percent: true)
                        .disabled(!store.timerOverlayVisible)
                    Picker("Corner", selection: Binding(
                        get: { store.timerOverlayPosition },
                        set: { store.updateTimerOverlayPosition($0) }
                    )) {
                        ForEach(HUDPosition.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(!store.timerOverlayVisible)
                    Picker("Show on", selection: Binding(
                        get: { store.timerOverlayScreen },
                        set: { store.updateTimerOverlayScreen($0) }
                    )) {
                        ForEach(PaletteScreenLocation.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(!store.timerOverlayVisible)

                    Toggle("Play a sound when a timer ends", isOn: Binding(
                        get: { store.timerSoundEnabled },
                        set: { store.updateTimerSoundEnabled($0) }
                    ))
                    HStack {
                        Picker("Sound", selection: Binding(
                            get: { store.timerSoundName },
                            set: { store.updateTimerSoundName($0) }
                        )) {
                            ForEach(TimerSettings.soundNames, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .disabled(!store.timerSoundEnabled)
                        Button("Try") {
                            TimerChime.shared.play(store.timerSoundName)
                        }
                        .disabled(!store.timerSoundEnabled)
                    }
                    caption("⌃⌥T or the Timers menu starts one: a length with a unit (25m, 1h 30m, 40s), a bare number of minutes (25) or a time of day with a colon (8:30, meaning the next half past eight). The card sits in the chosen corner, follows the active display and steps aside as the pointer comes near, coming back once it moves away; it stays above the other apps and is left out of screenshots. Several timers run at once, nearest first, each with an optional label. Timers survive a quit and a crash: a running one keeps its absolute deadline, so the time the app was closed is already counted, a paused one comes back paused, and one that ran out while the app was closed is announced at the next launch instead of being lost. A finished one posts a notice until you dismiss it, with a system sound when the option above is on. The sound follows the Mac's volume and mute.")
                }
            }
            if panelsPage == .switcher {
                SettingsSection("Window switcher") {
                    Picker("Open on screen with", selection: Binding(
                        get: { store.paletteScreenLocation },
                        set: { store.updatePaletteScreenLocation($0) }
                    )) {
                        ForEach(PaletteScreenLocation.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Open the switcher full screen", isOn: Binding(
                        get: { store.paletteFullScreen },
                        set: { store.updatePaletteFullScreen($0) }
                    ))
                    Toggle("Show the groups column", isOn: Binding(
                        get: { store.showGroupsInPalette },
                        set: { store.updatePaletteGroupsVisibility($0) }
                    ))
                    Toggle("Only groups with windows", isOn: Binding(
                        get: { store.showEmptyGroupsInPalette },
                        set: { store.updatePaletteEmptyGroups($0) }
                    ))
                    .disabled(!store.showGroupsInPalette)
                    Toggle("Announce group changes", isOn: Binding(
                        get: { store.announceGroupChanges },
                        set: { store.updateGroupAnnouncements($0) }
                    ))
                    caption("⌥Tab opens the switcher on the active display (the monitor of the last window focus or pointer move); the panel stays there until closed. The groups column edits the numbered groups next to the window grid; with it off the panel narrows to the cards, while ⌘1…9 and Esc still work on the cards and ⌃⌥1…9 still recalls a group from anywhere. Announcements cover adding, removing, recalling and clearing; a group that is empty, or whose windows are gone, is still reported when you ask for it. The Groups menu always lists every group.")
                }
                SettingsSection("Search & launch") {
                    caption("⌥Space opens the same palette in search mode with the search field focused. Search filters open windows and installed applications; the Applications shelf below the field launches an app with Return.")
                }
                SettingsSection("Grid & card size") {
                    Picker("Columns", selection: Binding(
                        get: { store.paletteColumns },
                        set: { store.updatePaletteColumns($0) }
                    )) {
                        Text("Automatic").tag(0)
                        ForEach(2...8, id: \.self) { Text("\($0)").tag($0) }
                    }
                    SliderRow(title: "Max size",
                              value: Binding(get: { store.paletteMaxCardWidth },
                                             set: { store.updatePaletteMaxCardWidth($0) }),
                              range: 160...480, step: 10, unit: " pt")
                    Toggle("Size follows the number of windows", isOn: Binding(
                        get: { store.paletteCardSizeFollowsCount },
                        set: { store.updatePaletteCardSizeFollowsCount($0) }
                    ))
                    caption("Automatic uses 2–4 columns in the compact switcher and as many as fit in full-screen mode. A fixed number pins the grid. Cards shrink to fit the screen, and previews keep the display's proportions. With the last option on, one window takes the whole Max size, two a little less, and from nine windows on about 70% of it: the count is the windows open when the switcher opens, so typing a search does not resize the panel. The profile never goes above Max size or below 80 pt, and a fixed column count still decides the grid.")
                }
            }
            if panelsPage == .look {
                SettingsSection("Previews & colours") {
                    Toggle("Show window previews", isOn: Binding(
                        get: { store.showPreview },
                        set: { store.updateShowPreview($0) }
                    ))
                    Toggle("Colour windows in list and canvas", isOn: Binding(
                        get: { store.paletteTintedCards },
                        set: { store.updatePaletteTintedCards($0) }
                    ))
                    Picker("Theme", selection: Binding(
                        get: { store.themeID },
                        set: { store.updateTheme($0) }
                    )) {
                        ForEach(PaletteTheme.all) { Text($0.name).tag($0.id) }
                    }
                    SliderRow(title: "Opacity",
                              value: Binding(get: { store.paletteOpacity }, set: { store.updatePaletteOpacity($0) }),
                              range: 0.5...1.0, unit: "%", percent: true)
                    caption("Previews need Screen Recording permission. The theme also colours the overlay. Window colours affect the list, thumbnails and mini-map; the focused-window outline keeps its theme colour.")
                }
            }
            if panelsPage == .tools {
                SettingsSection("Screenshot") {
                    Toggle("Copy the annotated screenshot too", isOn: Binding(
                        get: { store.screenshotCopyToClipboard },
                        set: { store.updateScreenshotCopyToClipboard($0) }
                    ))
                    Toggle("Announce screenshots macOS saves", isOn: Binding(
                        get: { store.screenshotSavedNotice },
                        set: { store.updateScreenshotSavedNotice($0) }
                    ))
                    Toggle("Record the system's sound too", isOn: Binding(
                        get: { store.recordingIncludesAudio },
                        set: { store.updateRecordingIncludesAudio($0) }
                    ))
                    caption("A notice with the capture's name and two actions — put it on the shelf, or read its text — appears when macOS saves a screenshot with ⌘⇧3/4/5. Off by default, and silent while a password field has the keyboard. It follows the folder chosen in the screenshot library.")
                    caption("⌃⌥⇧S (or menu ▸ Capture Area…) opens the area selector, then a small editor: arrow, rectangle, pen, highlighter, text and crop, plus «hide details» for anything private. Ret saves, Esc throws it away, ⌘Z undoes. ⌃⌥⇧W and ⌃⌥⇧C capture the window in front or the whole display in the same editor. The result lands on the shelf as a PNG — drag it out, or paste it when the option above is on. The file lives in the shelf's temporary folder and goes away with it.")
                    caption("⌃⌥⇧R (or menu ▸ Record Area…) records the area you drag to a movie on the shelf; the same key stops it. The menu-bar menu pauses, resumes and stops a recording, and its icon changes while one runs. The system's own sound is included unless you turn it off above; the microphone is not used. Files go to Application Support ▸ MakiDesk ▸ Recordings.")
                }
                SettingsSection("Notes rewriting") {
                    caption("Apple Intelligence on this Mac: \(NotesIntelligence.availability().summary) The notes editor's Format menu offers Improve wording, Format as Markdown and Summarize. The on-device model only writes a proposal — nothing leaves the Mac and nothing is logged — and it appears in a preview with Apply, Copy and Cancel before it touches the note. Apply is a single edit, one ⌘Z away.")
                }
                SettingsSection("Clipboard history") {
                    Toggle("Keep copied images", isOn: Binding(
                        get: { store.clipboardKeepsImages },
                        set: { store.updateClipboardKeepsImages($0) }
                    ))
                    Picker("Image budget", selection: Binding(
                        get: { store.clipboardImageBudgetMB },
                        set: { store.updateClipboardImageBudgetMB($0) }
                    )) {
                        Text("16 MB").tag(16)
                        Text("32 MB").tag(32)
                        Text("64 MB").tag(64)
                    }
                    .disabled(!store.clipboardKeepsImages)
                    caption("The history keeps text and images in memory only. An image is stored as its original bytes plus a 96 px thumbnail, and the oldest unpinned images are evicted to stay within the budget. Pinned entries survive Clear; pins are in memory too and disappear when MakiDesk quits. Nothing is written to disk.")
                }
                SettingsSection("Text recognition") {
                    Toggle("Fast recognition (less accurate)", isOn: Binding(
                        get: { store.ocrFastRecognition },
                        set: { store.updateOCRFastRecognition($0) }
                    ))
                    Toggle("Language correction", isOn: Binding(
                        get: { store.ocrLanguageCorrection },
                        set: { store.updateOCRLanguageCorrection($0) }
                    ))
                    Picker("Send the text to", selection: Binding(
                        get: { store.ocrOutput },
                        set: { store.updateOCROutput($0) }
                    )) {
                        ForEach(TextRecognitionOutput.allCases) { output in
                            Text(output.title).tag(output)
                        }
                    }
                    Picker("Open clipboard history", selection: Binding(
                        get: { store.ocrRevealHistory },
                        set: { store.updateOCRRevealHistory($0) }
                    )) {
                        ForEach(OCRRevealHistory.allCases) { reveal in
                            Text(reveal.title).tag(reveal)
                        }
                    }
                    caption("⌃⌥⇧O selects an area of the screen and sends the text to the clipboard, to the in-memory clipboard history, or both; Esc cancels. The history disappears when MakiDesk quits, so “History only” keeps no copy after the app closes. Vision runs on this Mac and detects the language automatically; the models (about 100 MB) stay in memory after the first use. Nothing is uploaded or written to disk.")
                }
                SettingsSection("Colour picker") {
                    Picker("Copy as", selection: $colorFormat) {
                        ForEach(ColorClipboardFormat.allCases) { Text($0.title).tag($0) }
                    }
                    caption("⌃⌥⇧E opens a loupe and copies the colour under the click; Esc cancels. Values are converted to sRGB. The clipboard history keeps a copy when it is on.")
                }
                SettingsSection("Measure") {
                    Picker("Units", selection: Binding(
                        get: { MeasurementSettings.unit() },
                        set: { MeasurementSettings.setUnit($0) }
                    )) {
                        ForEach(MeasurementUnit.allCases) { Text($0.title).tag($0) }
                    }
                    caption("⌃⌥⇧M drags a measurement over any app: ⇧ keeps a square, ⌥ measures from the centre, and values snap within 6 pt to windows and displays. Measurements stay until their ✕ or Clear Measurements. Millimetres and inches are estimated from the display's reported physical size.")
                }
            }
            if panelsPage == .pointer {
                SettingsSection("Pointer effects") {
                    Picker("Presentation style", selection: Binding(
                        get: { store.pointerEffectStyle },
                        set: { store.updatePointerEffectStyle($0) }
                    )) {
                        ForEach(PointerEffectStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    Text(store.pointerEffectStyle.summary)
                        .font(.caption)
                        .foregroundStyle(theme.subtext)
                    if store.pointerEffectStyle == .particles {
                        SliderRow(title: "Particle count",
                                  value: Binding(
                                      get: { Double(store.pointerParticleCount) },
                                      set: { store.updatePointerParticleCount(Int($0.rounded())) }
                                  ),
                                  range: Double(PointerParticles.countRange.lowerBound)
                                      ... Double(PointerParticles.countRange.upperBound),
                                  step: 2)
                        SliderRow(title: "Particle size",
                                  value: Binding(
                                      get: { Double(store.pointerParticleSize) },
                                      set: { store.updatePointerParticleSize($0) }
                                  ),
                                  range: Double(PointerParticles.sizeRange.lowerBound)
                                      ... Double(PointerParticles.sizeRange.upperBound),
                                  step: 0.5, unit: " pt", decimals: 1)
                    }
                    if store.pointerEffectStyle == .orbit {
                        Stepper("Orbit dots: \(store.pointerOrbitCount)",
                                value: Binding(
                                    get: { store.pointerOrbitCount },
                                    set: { store.updatePointerOrbitCount($0) }
                                ),
                                in: PointerOrbit.countRange)
                        SliderRow(title: "Dot size",
                                  value: Binding(
                                      get: { Double(store.pointerOrbitDotSize) },
                                      set: { store.updatePointerOrbitDotSize($0) }
                                  ),
                                  range: Double(PointerOrbit.sizeRange.lowerBound)
                                      ... Double(PointerOrbit.sizeRange.upperBound),
                                  step: 0.5, unit: " pt", decimals: 1)
                    }
                    Toggle("Ripple on click", isOn: Binding(
                        get: { store.pointerClickRipple },
                        set: { store.updatePointerClickRipple($0) }
                    ))
                    SliderRow(title: "Ring size",
                              value: Binding(get: { Double(store.pointerEffectSize) },
                                             set: { store.updatePointerEffectSize($0) }),
                              range: Double(PointerEffectSettings.sizeRange.lowerBound)
                                  ... Double(PointerEffectSettings.sizeRange.upperBound),
                              step: 2, unit: " pt", decimals: 0)
                    SliderRow(title: "Intensity",
                              value: Binding(get: { store.pointerEffectIntensity },
                                             set: { store.updatePointerEffectIntensity($0) }),
                              range: PointerEffectSettings.intensityRange,
                              step: 0.05, unit: "%", percent: true)
                    SliderRow(title: "Pulse duration",
                              value: Binding(get: { store.pointerPulseDuration },
                                             set: { store.updatePointerPulseDuration($0) }),
                              range: PointerEffectSettings.pulseDurationRange,
                              step: 0.1, unit: " s", decimals: 1)
                    Toggle("No time limit", isOn: Binding(
                        get: {
                            store.pointerPresentationMinutes
                                == PointerEffectSettings.unlimitedPresentationMinutes
                        },
                        set: { unlimited in
                            store.updatePointerPresentationMinutes(
                                unlimited
                                    ? PointerEffectSettings.unlimitedPresentationMinutes
                                    : store.pointerFinitePresentationMinutes
                            )
                        }
                    ))
                    if store.pointerPresentationMinutes
                        > PointerEffectSettings.unlimitedPresentationMinutes {
                        Stepper("Presentation ends after \(store.pointerPresentationMinutes) min",
                                value: Binding(get: { store.pointerPresentationMinutes },
                                               set: { store.updatePointerPresentationMinutes($0) }),
                                in: 1...PointerEffectSettings.presentationMinutesRange.upperBound)
                    } else {
                        Text("The presentation stays on until the shortcut is pressed again.")
                            .font(.caption)
                            .foregroundStyle(theme.subtext)
                    }
                    Toggle("Visible to other capture apps", isOn: Binding(
                        get: { store.pointerEffectsInCaptures },
                        set: { store.updatePointerEffectsInCaptures($0) }
                    ))
                    HStack(spacing: 12) {
                        Button("Test pulse") {
                            PointerEffectController.shared.pulse()
                        }
                        Text("⌃⌥⇧P · ⌃⌥⇧X")
                            .font(.caption)
                            .foregroundStyle(theme.subtext)
                    }
                    caption("⌃⌥⇧P shows a pulse around the pointer, on the display it is on. ⌃⌥⇧X follows the pointer with the style selected above: five minutes by default, or until you stop it when No time limit is on. The ribbon fades when movement stops; particles settle to a faint sparkle and can be made more numerous or larger; orbit dots animate in Core Animation and their number and size are adjustable; spotlight dims the screen around a clear area. The pointer is read in memory, never recorded. A click leaves a ripple while the presentation is on. MakiDesk's own still captures leave the effect out, because they are taken without the system pointer; recordings keep both. The option above asks capture pipelines that honour the window's sharing type to leave the effect out too, and some recorders ignore it. Reduce Motion simplifies the animations; spotlight remains a static dim with a clear circle.")
                }
            }
            if panelsPage == .bar {
                SettingsSection("Utility bar") {
                    Toggle("Open it when the pointer reaches the menu bar", isOn: Binding(
                        get: { store.utilityBarEnabled },
                        set: { store.updateUtilityBarEnabled($0) }
                    ))
                    SliderRow(title: "Height",
                              value: Binding(get: { Double(store.utilityBarHeight) },
                                             set: { store.updateUtilityBarHeight(Int($0.rounded())) }),
                              range: Double(UtilityBarModel.heightRange.lowerBound)...Double(UtilityBarModel.heightRange.upperBound),
                              step: 2,
                              unit: " pt", decimals: 0)
                        .disabled(!store.utilityBarEnabled)
                    Picker("Labels", selection: Binding(
                        get: { store.utilityBarLabels },
                        set: { store.updateUtilityBarLabels($0) }
                    )) {
                        ForEach(BarLabelMode.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(!store.utilityBarEnabled)
                    caption("Rest the pointer on the menu bar for a quarter of a second and the bar appears below it; it retreats when the pointer leaves, and stays while the pin on its right is on. On a display without a menu bar the top edge works the same way. ⌃⌥B opens it from the keyboard — arrows choose, ⏎ runs, Esc closes — and the menu bar's Utility Bar item does the same. The bar takes no room from windows and stays out of screenshots and recordings. Labels follow the display's width; Automatic shows them on wide screens only. A pinned bar ignores clicks elsewhere and display changes; the pin, ⌃⌥B or the menu close it. The pin lasts until MakiDesk quits.")
                }
                SettingsSection("Buttons") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8,
                                                  alignment: .leading)],
                              alignment: .leading, spacing: 4) {
                        ForEach(store.barConfiguration.resolvedItems(includingHidden: true)) { item in
                            Toggle(item.title, isOn: Binding(
                                get: { store.barConfiguration.isVisible(item.id) },
                                set: { store.updateBarItemVisibility(item.id, shown: $0) }
                            ))
                            .toggleStyle(.checkbox)
                        }
                    }
                    .disabled(!store.utilityBarEnabled || store.barConfigurationState.isWritable == false)
                    HStack(spacing: 12) {
                        Button("Reveal buttons file…") {
                            store.revealBarConfigurationFile()
                        }
                        Button("Show all") {
                            store.showAllBarButtons()
                        }
                        .disabled(store.barConfigurationState.isWritable == false)
                    }
                    .disabled(!store.utilityBarEnabled)
                    if case let .futureVersion(version) = store.barConfigurationState {
                        Text("utility-bar.json comes from a newer MakiDesk (version \(version)): it is used as it is and never rewritten.")
                            .font(.caption)
                            .foregroundStyle(theme.subtext)
                    } else if store.barConfigurationState == .corrupt {
                        Text("The buttons file could not be read: it was set aside as utility-bar.json.bak and the default buttons are in use.")
                            .font(.caption)
                            .foregroundStyle(theme.subtext)
                    }
                    caption("Untick the buttons you never use: with fewer of them everything fits and the chevron disappears. The pin and the Settings button are always there, and the chevron appears when something does not fit. The Timer button carries the nearest running countdown as a badge, so there is one Timer, not two. The left group holds the panels and the capture tools, the middle the focus border, the focus dim and the mini map, the right the figures and the number of windows in the switcher. Visibility and order also live in ~/Library/Application Support/MakiDesk/utility-bar.json, which you can edit by hand: each entry names an id, shown or not, and may override its title and symbol. Order applies inside each zone; unknown ids are ignored and a new button appears on its own. Changes are read when the bar next appears, and a file from a newer version is left untouched.")
                }
            }
        }
        .animation(selectionAnimation, value: panelsPage)
    }


    // MARK: - Terminal

    /// The standard sizes plus a hand-edited value, so the picker still shows
    /// what the file contains.
    private var scrollbackChoices: [Int] {
        let current = TerminalController.shared.settings.scrollbackLimitMB ?? 0
        let standard = [0, 5, 20, 100]
        return standard.contains(current) ? standard : (standard + [current]).sorted()
    }

    private var terminalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection("Terminal") {
                TextField("Font family", text: Binding(
                    get: { TerminalController.shared.settings.fontFamily ?? "" },
                    set: { value in
                        TerminalController.shared.updateSettings {
                            $0.fontFamily = value.isEmpty ? nil : value
                        }
                    }
                ))
                SliderRow(title: "Font size",
                          value: Binding(
                            get: { TerminalController.shared.settings.fontSize },
                            set: { value in
                                TerminalController.shared.updateSettings { $0.fontSize = value }
                            }),
                          range: 10...20, step: 1, unit: " pt", decimals: 0)
                Picker("Cursor", selection: Binding(
                    get: { TerminalController.shared.settings.cursorStyle },
                    set: { value in
                        TerminalController.shared.updateSettings { $0.cursorStyle = value }
                    }
                )) {
                    ForEach(TerminalCursorStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                Toggle("Blink the cursor", isOn: Binding(
                    get: { TerminalController.shared.settings.cursorBlink },
                    set: { value in
                        TerminalController.shared.updateSettings { $0.cursorBlink = value }
                    }
                ))
                Picker("Scrollback", selection: Binding(
                    get: { TerminalController.shared.settings.scrollbackLimitMB ?? 0 },
                    set: { value in
                        TerminalController.shared.updateSettings {
                            $0.scrollbackLimitMB = value == 0 ? nil : value
                        }
                    }
                )) {
                    ForEach(scrollbackChoices, id: \.self) { megabytes in
                        Text(megabytes == 0 ? "Default" : "\(megabytes) MB").tag(megabytes)
                    }
                }
                Toggle("Copy text when selected", isOn: Binding(
                    get: { TerminalController.shared.settings.copyOnSelect },
                    set: { value in
                        TerminalController.shared.updateSettings { $0.copyOnSelect = value }
                    }
                ))
                Toggle("Hide the pointer while typing", isOn: Binding(
                    get: { TerminalController.shared.settings.hideMouseWhileTyping },
                    set: { value in
                        TerminalController.shared.updateSettings {
                            $0.hideMouseWhileTyping = value
                        }
                    }
                ))
                TextField("Shell command (empty: login shell)", text: Binding(
                    get: { TerminalController.shared.settings.shell ?? "" },
                    set: { value in
                        TerminalController.shared.updateSettings {
                            $0.shell = value.isEmpty ? nil : value
                        }
                    }
                ))
                SliderRow(title: "Quake height",
                          value: Binding(
                            get: { TerminalController.shared.settings.quakeHeightFraction },
                            set: { value in
                                TerminalController.shared.updateSettings {
                                    $0.quakeHeightFraction = value
                                }
                            }),
                          range: 0.3...0.6, step: 0.05, unit: "%", percent: true)
                HStack(spacing: 12) {
                    Button("Open Terminal") { TerminalController.shared.open() }
                    Button("Open Quake") { TerminalController.shared.toggleQuake() }
                    Text("⌃⌥O · ⌃⌥Q")
                        .font(.caption)
                        .foregroundStyle(theme.subtext)
                }
                Toggle("Keep window shortcuts while the terminal is in front",
                       isOn: Binding(
                        get: { keepTerminalWindowShortcuts },
                        set: { value in
                            keepTerminalWindowShortcuts = value
                            TerminalController.shared.reapplyShortcutSuspension()
                        }
                       ))
                caption("The helper reads these settings and the theme file when it receives a change, so a font or quake adjustment applies without restarting it. An empty font family keeps the built-in monospaced family; an empty shell command starts your login shell. The cursor shape and blink apply live, as do selection copy and pointer hiding; the scrollback limit is memory per pane and applies to new panes. With the window shortcuts kept, ⌃⌥ arrows and the other Window rows still move the helper window; the panel, screen and desktop rows stay suspended so the shell receives them. The terminal, its sidebar and its title bar follow the MakiDesk theme: changing it in Panels ▸ Look updates them too. The quake panel uses the same setting for its height.")
            }
            agentHooksSection
            sshProfilesSection
        }
    }

    /// Opt-in automation of the sidebar's agent dot (F3 L2). Each switch writes
    /// to that agent's own settings file, so the row says which one, and
    /// nothing happens until it is turned on here.
    private var agentHooksSection: some View {
        SettingsSection("Agents") {
            ForEach(AgentHooks.Agent.allCases, id: \.self) { agent in
                AgentHookRow(agent: agent)
            }
            caption("On: a few small hooks report working, waiting and done for an agent session started in a MakiDesk pane. The file is merged, not replaced, a one-time backup is kept next to it as its name plus .makidesk-backup, and removing the hooks takes out only the ones MakiDesk added. Codex asks you to review and trust new hooks once with /hooks before they run. Nothing is written until you switch this on.")
        }
    }

    @ViewBuilder
    private var sshProfilesSection: some View {
        let profiles = TerminalController.shared.settings.sshProfiles
        SettingsSection("SSH profiles") {
            if profiles.isEmpty {
                Text("No profiles yet. Add one and it appears in the terminal's + menu.")
                    .font(.caption)
                    .foregroundStyle(theme.subtext)
            }
            ForEach(profiles) { profile in
                DisclosureGroup {
                    sshProfileFields(profile)
                        .padding(.top, 6)
                } label: {
                    HStack(spacing: 8) {
                        Text(profile.displayName.isEmpty ? "New SSH profile" : profile.displayName)
                        Spacer()
                        Button {
                            TerminalController.shared.removeSSHProfile(id: profile.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this profile")
                    }
                }
            }
            Button("Add SSH profile") {
                TerminalController.shared.addSSHProfile()
            }
            caption("A profile becomes an `ssh` command in a new workspace: host, user, port, optional key, remote command and agent forwarding. Passwords are never stored; keys and known_hosts remain ssh's own. The command is saved with the layout, so a restored pane reconnects.")
        }
    }

    @ViewBuilder
    private func sshProfileFields(_ profile: TerminalSSHProfile) -> some View {
        TextField("Name", text: sshStringBinding(profile, \.name))
        TextField("Host", text: sshStringBinding(profile, \.host))
        TextField("User", text: sshStringBinding(profile, \.user))
        TextField("Port", text: Binding(
            get: {
                profile.port.map(String.init) ?? ""
            },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                TerminalController.shared.updateSSHProfile(id: profile.id) {
                    $0.port = trimmed.isEmpty ? nil : Int(trimmed)
                }
            }
        ))
        TextField("Identity file (optional)", text: sshOptionalBinding(profile, \.identityFile))
        TextField("Remote command (optional)", text: sshOptionalBinding(profile, \.remoteCommand))
        Toggle("Forward agent", isOn: Binding(
            get: { profile.forwardAgent },
            set: { value in
                TerminalController.shared.updateSSHProfile(id: profile.id) {
                    $0.forwardAgent = value
                }
            }
        ))
    }

    private func sshStringBinding(_ profile: TerminalSSHProfile,
                                  _ keyPath: WritableKeyPath<TerminalSSHProfile, String>) -> Binding<String> {
        Binding(
            get: {
                TerminalController.shared.settings.sshProfiles
                    .first(where: { $0.id == profile.id })?[keyPath: keyPath] ?? ""
            },
            set: { value in
                TerminalController.shared.updateSSHProfile(id: profile.id) {
                    $0[keyPath: keyPath] = value
                }
            }
        )
    }

    private func sshOptionalBinding(_ profile: TerminalSSHProfile,
                                    _ keyPath: WritableKeyPath<TerminalSSHProfile, String?>) -> Binding<String> {
        Binding(
            get: {
                TerminalController.shared.settings.sshProfiles
                    .first(where: { $0.id == profile.id })?[keyPath: keyPath] ?? ""
            },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                TerminalController.shared.updateSSHProfile(id: profile.id) {
                    $0[keyPath: keyPath] = trimmed.isEmpty ? nil : value
                }
            }
        )
    }

    // MARK: - Groups

    @ViewBuilder
    private var notificationsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageTabs(NotificationsPage.allCases, selection: $notificationsPage) { $0.title }
            if notificationsPage == .placement {
                SettingsSection("Position") {
                    Picker("Placement", selection: hudPosition) {
                        ForEach(HUDPosition.allCases) { position in
                            Text(position.label).tag(position)
                        }
                    }
                    Picker("Show on", selection: hudScreen) {
                        ForEach(PaletteScreenLocation.allCases) { location in
                            Text(location.label).tag(location)
                        }
                    }
                    caption("Notices follow the focus or the pointer and stay inside the display's visible frame, including displays with a negative origin. The fallback is the main display.")
                }
                SettingsSection("Duration") {
                    SliderRow(title: "Base duration", value: hudBaseDuration,
                              range: 1...5, step: 0.2, unit: " s", decimals: 1)
                    caption("Confirmations, information and successes stay for the base duration, warnings about half as long again, errors twice as long with a 3 s floor. Up to two notices are visible; the rest wait in a queue. Progress notices stay until the work ends.")
                }
            }
            if notificationsPage == .behaviour {
                SettingsSection("Sticky notices") {
                    Toggle("Keep errors until I dismiss them", isOn: hudKeepErrors)
                    HStack {
                        Text(HUDController.shared.hasNotices
                             ? "Click a notice on screen to take it away."
                             : "Nothing is showing.")
                            .font(.caption)
                            .foregroundStyle(theme.subtext)
                        Spacer()
                        Button("Dismiss All Notices") {
                            HUDController.shared.hide()
                        }
                        .disabled(!HUDController.shared.hasNotices)
                    }
                    caption("Off, every notice closes by itself after its duration, exactly as before. On, errors have no timer and stay in the corner until you click them away. Notices you must dismiss never hold back the others: they sit in their own lane, and the newest three are kept on screen. Everything stays in the history.")
                }
            }
            if notificationsPage == .appearance {
                SettingsSection("Appearance") {
                    SliderRow(title: "Text size", value: hudTextSize,
                              range: 12...20, step: 1, unit: " pt", decimals: 0)
                    Text("Preview")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.text)
                    // One button per state: the tint, the symbol and the duration are
                    // what the state is for, so each is shown as itself (T60).
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6,
                                                  alignment: .leading)],
                              alignment: .leading, spacing: 6) {
                        ForEach(HUDKind.allCases, id: \.self) { kind in
                            Button(kind.label) {
                                HUDController.shared.preview(kind)
                            }
                            .controlSize(.small)
                        }
                    }
                    Toggle("Compact notices (title only)", isOn: hudCompact)
                    Toggle("Announce with VoiceOver", isOn: hudVoiceOver)
                    caption("The state tints the icon and border: grey for information, accent for a confirmation, green for success, orange for a warning, red for an error. Each Preview button shows its state in the current placement, size and theme; the error one follows the sticky option above. The icon, padding and corners grow with the text. Notices are excluded from screenshots and recordings, and with Reduce Motion on they appear without the short fade.")
                }
            }
            if notificationsPage == .history {
                SettingsSection("History") {
                    Toggle("Keep a history (in memory)", isOn: hudHistoryEnabled)
                    HStack {
                        Text("The last 50 notices, newest first.")
                            .font(.caption)
                            .foregroundStyle(theme.subtext)
                        Spacer()
                        Button("Show Notification History…") {
                            NotificationHistoryController.shared.show()
                        }
                    }
                    caption("Messages can name windows, zones and paths, so the history is never written to disk and disappears when MakiDesk quits. Search it, copy a message with Return, clear it with the Clear button.")
                }
            }
        }
        .animation(selectionAnimation, value: notificationsPage)
    }


    // MARK: - System

    @ViewBuilder
    private var systemTab: some View {
        SettingsSection("Menu bar") {
            Picker("Show free space", selection: systemDiskMode) {
                ForEach(DiskMenuBarMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            Picker("Format", selection: systemDiskFormat) {
                ForEach(DiskSpaceFormat.allCases) { format in
                    Text(format.label).tag(format)
                }
            }
            SliderRow(title: "Warn below", value: systemDiskThreshold,
                      range: 0...100, step: 5, unit: " GB", decimals: 0)
            HStack(spacing: 10) {
                Text("Preview")
                    .foregroundStyle(theme.subtext)
                Spacer()
                Text(systemDiskPreview)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.surfaceSelected))
            }
            caption("The figure includes the space macOS can purge, so it matches Finder and Storage settings; the System menu also shows the strict count. It is read once a minute, and the label holds still while the menu is open, so the menu cannot close under the pointer. At 0 GB the warning is off. When free space falls below the threshold the label turns orange and one warning a day offers Storage settings.")
        }
        SettingsSection("CPU alerts") {
            Toggle("Warn about a process stuck at high CPU", isOn: systemCPUEnabled)
            SliderRow(title: "Threshold", value: systemCPUThreshold,
                      range: 50...800, step: 10, unit: "% of a core", decimals: 0)
            SliderRow(title: "Sustained for", value: systemCPUDuration,
                      range: 1...60, step: 1, unit: " min", decimals: 0)
            Toggle("Also send a system notification", isOn: systemNotifications)
                .disabled(!SystemNotifier.isAvailable)
            HStack(spacing: 10) {
                Text(system.cpuMenuLine)
                    .foregroundStyle(theme.subtext)
                Spacer()
                Button("Activity Monitor") { system.openActivityMonitor() }
            }
            caption("A process is reported once it stays over the threshold for the whole window, with three samples in a row to arm the rule and two quiet samples to reset it. One process is named at a time, at most once every 30 minutes per episode; a second hot process waits five minutes, and a notice offers Snooze 1 hour. Root-owned daemons cannot be sampled from a user app: when the machine total is high and no readable process explains it, the notice says “System processes” and points to Activity Monitor. No process name, path or command line is written to a log or sent anywhere. System notifications are optional and respect Focus; the in-app notice needs no permission.")
        }
    }


    private var groupsTab: some View {
        SettingsSection("Groups") {
            ForEach(1...9, id: \.self) { slot in
                GroupSettingsRow(store: store, slot: slot)
            }
            caption("A group is a saved selection of windows: ⌃⌥⌘1…9 adds or removes the front window, ⌃⌥1…9 brings the group back. Recalling a group shows its windows where you left them — a group has no layout of its own. To give one a disposition, recall it and then run a layout (⌃⌥G grid, ⌃⌥S golden spiral, ⌃⌥A suggested): the arrangement is remembered for next time. The group column in the Opt-Tab / Opt-Space palette edits the same groups; hide it and its announcements in Panels ▸ Window switcher.")
        }
    }

    // MARK: - Helpers

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(MakiType.caption)
            .foregroundStyle(theme.subtext)
            // Settings carries long explanations; a little leading keeps
            // them readable without making the window taller by a screen.
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func openBundledDocument(_ name: String, extension ext: String?) {
        let url = Bundle.main.url(forResource: name, withExtension: ext)
            ?? URL(fileURLWithPath: ext.map { "\(name).\($0)" } ?? name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// The permission buttons, shared by the horizontal and stacked variants.
    @ViewBuilder
    private var permissionButtons: some View {
        Button("Open Accessibility Settings") { store.openAccessibilitySettings() }
        Button("Request Screen Recording") { store.requestScreenRecording() }
        Button("Open Screen Recording Settings") { store.openScreenRecordingSettings() }
    }
}

/// A themed replacement for the grouped `Form` boxes: a title, a card in the
/// theme surface colour and the rows inside it. It keeps the native controls
/// (switches, popups, sliders) and only paints around them.
/// One agent in Settings ▸ Terminal ▸ Agents: its state, its switch and the
/// file it writes. Each row owns its asynchronous read and merge so the two
/// agents cannot block each other or the main thread.
private struct AgentHookRow: View {
    let agent: AgentHooks.Agent

    @Environment(\.paletteTheme) private var theme
    @State private var status: AgentHooks.Status
    @State private var error: String?
    @State private var busy = false

    init(agent: AgentHooks.Agent) {
        self.agent = agent
        _status = State(initialValue: AgentHooks.Status(
            state: .absent, present: 0, expected: agent.events.count,
            command: nil, problem: nil))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Report \(agent.displayName) activity to the sidebar", isOn: Binding(
                get: { status.state == .installed },
                set: { setHooks($0) }
            ))
            .disabled(busy || status.state == .unreadable)

            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(theme.subtext)
                Spacer(minLength: 0)
                Button("Reveal settings") { reveal() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .task { await refresh() }
    }

    private var file: String {
        (agent.settingsURL.path as NSString).abbreviatingWithTildeInPath
    }

    private var detail: String {
        switch status.state {
        case .absent:
            return "Not installed: \(file)"
        case .partial:
            return "\(status.present) of \(status.expected) events installed in \(file)"
        case .installed:
            return "Installed (\(status.present) events) at \(status.command ?? "an unknown path")"
        case .unreadable:
            return status.problem ?? "The settings file cannot be read."
        }
    }

    private func reveal() {
        let url = agent.settingsURL
        let folder = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if FileManager.default.fileExists(atPath: folder.path) {
            NSWorkspace.shared.open(folder)
        }
    }

    @MainActor
    private func refresh() async {
        let agent = agent
        status = await Task.detached(priority: .utility) {
            AgentHooks.status(for: agent)
        }.value
    }

    @MainActor
    private func setHooks(_ installed: Bool) {
        guard busy == false else { return }
        let agent = agent
        let command = TerminalController.shared.agentHookCommandPath
        if installed, command == nil {
            error = "Open the terminal once, then try again: the hooks call the makidesk command the helper installs at launch."
            return
        }
        busy = true
        error = nil
        Task { @MainActor in
            let failure: String? = await Task.detached(priority: .userInitiated) {
                do {
                    if installed {
                        _ = try AgentHooks.install(for: agent, command: command ?? "")
                    } else {
                        _ = try AgentHooks.uninstall(from: agent)
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            busy = false
            error = failure
            await refresh()
        }
    }
}

struct SettingsSection<Content: View>: View {
    @Environment(\.paletteTheme) private var theme

    private let title: String?
    private let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title {
                Text(title)
                    .font(MakiType.section)
                    .foregroundStyle(theme.text)
            }
            VStack(alignment: .leading, spacing: 9) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .makiSurface(.passiveCard, theme: theme,
                         fill: theme.raisedSurface)
        }
    }
}

/// One group in Settings: its number, its name (editable in place), how many
/// windows it holds, how a recall lays it out, and the two actions worth having
/// here — recall and empty.
private struct GroupSettingsRow: View {
    @Environment(\.paletteTheme) private var theme

    @Bindable var store: WorkspaceStore
    let slot: Int

    @State private var name: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Text("\(slot)")
                .monospacedDigit()
                .foregroundStyle(theme.subtext)
                .frame(width: 14, alignment: .leading)
            TextField("Group \(slot)", text: $name)
                .onSubmit { commit() }
                .onChange(of: name) { _, _ in commit() }
            Text("\(store.groups[slot]?.members.count ?? 0)")
                .monospacedDigit()
                .foregroundStyle(theme.subtext)
                .frame(width: 22, alignment: .trailing)
                .help("Windows in this group")
            Button("Recall") { store.recallGroup(slot: slot) }
                .disabled(store.groupIsEmpty(slot))
            Button("Empty") { store.clearGroup(slot: slot) }
                .disabled(store.groupIsEmpty(slot))
        }
        .onAppear { name = store.groups[slot]?.name ?? "" }
        // Keep the field in step when the name is changed elsewhere (the menu).
        .onChange(of: store.groups[slot]?.name) { _, updated in
            let value = updated ?? ""
            if name != value { name = value }
        }
    }

    /// Saves as the user types; an unchanged name is a no-op in the store, so a
    /// keystroke that does not change the trimmed name writes nothing.
    private func commit() {
        store.renameGroup(slot: slot, name: name)
    }
}

/// A slider that always says what it does: the current value, the two limits and
/// the step, with the unit when there is one — so no value is a mystery.
private struct SliderRow: View {
    @Environment(\.paletteTheme) private var theme

    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// The step the slider snaps to; `nil` means it moves continuously.
    var step: Double?
    /// Suffix shown after the number ("×", "%", " pt", …).
    var unit: String = ""
    /// Decimals for the plain (non-percent) display.
    var decimals: Int = 0
    /// Shows the value as a percentage (0.9 → 90%).
    var percent: Bool = false

    private func text(_ value: Double) -> String {
        if percent { return "\(Int((value * 100).rounded()))" + unit }
        return String(format: "%.\(decimals)f", value) + unit
    }

    private var stepText: String {
        guard let step else { return "continuous" }
        return "step " + text(step)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(text(value))
                    .monospacedDigit()
                    .foregroundStyle(theme.subtext)
            }
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
            HStack {
                Text(text(range.lowerBound))
                Spacer()
                Text(stepText)
                Spacer()
                Text(text(range.upperBound))
            }
            .font(.system(size: 12))
            .foregroundStyle(theme.subtext)
            .monospacedDigit()
        }
    }
}

/// The confirmation for a factory reset (T23): the settings always go, the
/// window groups only when the user ticks them — and the same sheet will offer
/// notes (T20) and the clipboard history (T21) once those panels exist.
///
/// Ticks rather than switches: they say what *this one* operation includes, not
/// a stored setting, which is why the form-wide `.switch` style is overridden here.
private struct ResetConfirmationView: View {
    @Environment(\.paletteTheme) private var theme

    let store: WorkspaceStore
    let onReset: (WorkspaceStore.ResetScope) -> Void
    let onCancel: () -> Void

    @State private var includeGroups = false
    @State private var includeNotes = false
    @State private var includeClipboard = false
    @State private var includeDropzones = false
    @State private var dropzoneCount = 0

    private var groupCount: Int { store.groups.count }
    private var noteCount: Int { NotesStore.shared.noteCount }
    private var clipboardCount: Int { ClipboardHistory.shared.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reset to defaults?")
                .font(.headline)
                .foregroundStyle(theme.text)
            Text("Every option in the Settings window goes back to its default value. This cannot be undone.")
                .font(.callout)
                .foregroundStyle(theme.subtext)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                // The reset *is* the settings: this tick cannot be taken off, and
                // is here to show what the operation always includes.
                Toggle("Settings", isOn: .constant(true))
                    .disabled(true)
                Toggle(groupCount == 1 ? "Window groups (1)" : "Window groups (\(groupCount))",
                       isOn: $includeGroups)
                    .disabled(groupCount == 0)
                    .help("Deletes every group with its members and the arrangement remembered for it. The windows themselves are not closed.")
                Toggle(noteCount == 1 ? "Notes (1)" : "Notes (\(noteCount))",
                       isOn: $includeNotes)
                    .disabled(noteCount == 0)
                    .help("Deletes every note and draft, including the ones never saved to a file. Files opened from other folders are left where they are.")
                Toggle(clipboardCount == 1 ? "Clipboard history (1)" : "Clipboard history (\(clipboardCount))",
                       isOn: $includeClipboard)
                    .disabled(clipboardCount == 0)
                    .help("Empties the in-memory clipboard history. Nothing is written to disk, and the history is lost when the app quits anyway.")
                Toggle(dropzoneCount == 1 ? "Dropzones (1)" : "Dropzones (\(dropzoneCount))",
                       isOn: $includeDropzones)
                    .disabled(dropzoneCount == 0)
                    .help("Deletes every dropzone command. A command that is already running is not stopped. A file written by a newer MakiDesk is left alone.")
            }
            .toggleStyle(.checkbox)

            Text("Onboarding completion and the macOS ⌥-tiling setting are always left alone.")
                .font(.caption)
                .foregroundStyle(theme.subtext)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Reset", role: .destructive) {
                    var scope: WorkspaceStore.ResetScope = [.settings]
                    if includeGroups { scope.insert(.groups) }
                    if includeNotes { scope.insert(.notes) }
                    if includeClipboard { scope.insert(.clipboard) }
                    if includeDropzones { scope.insert(.dropzones) }
                    onReset(scope)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(theme.background)
        .onAppear {
            let snapshot = DropzoneStore().load()
            dropzoneCount = snapshot.canSave ? snapshot.zones.count : 0
            // The note count must include notes that were never opened in this
            // run; the restore reads metadata only and publishes asynchronously.
            NotesStore.shared.loadIfNeededAsync {}
        }
    }
}
