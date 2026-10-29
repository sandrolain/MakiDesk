import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var store: WorkspaceStore

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case general, windows, layouts, panels, notifications, groups, dropzones

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .windows: return "Windows"
            case .layouts: return "Layouts"
            case .panels: return "Panels"
            case .notifications: return "Notifications"
            case .groups: return "Groups"
            case .dropzones: return "Dropzones"
            }
        }
    }

    @AppStorage("settingsTab") private var settingsTab: SettingsTab = .general
    @AppStorage(ColorSamplerController.formatDefaultsKey)
    private var colorFormat: ColorClipboardFormat = .hex
    @AppStorage(HUDSettings.positionKey) private var hudPosition: HUDPosition = .bottomCenter
    @AppStorage(HUDSettings.screenKey) private var hudScreen: PaletteScreenLocation = .focusedWindow
    @AppStorage(HUDSettings.baseDurationKey) private var hudBaseDuration: Double = 1.4
    @AppStorage(HUDSettings.historyEnabledKey) private var hudHistoryEnabled = true
    @AppStorage(HUDSettings.voiceOverKey) private var hudVoiceOver = true
    @AppStorage(HUDSettings.compactKey) private var hudCompact = false
    @AppStorage(HUDSettings.textSizeKey) private var hudTextSize: Double = 14
    @AppStorage(HUDSettings.errorsStickyKey) private var hudKeepErrors = false
    @State private var showResetConfirmation = false
    @State private var excludedAppsText = ""
    /// Owned here, not by the tab, so switching tabs does not throw away a draft.
    @StateObject private var dropzoneEditor = DropzoneEditorModel()

    private static let gapOptions: [Double] = [0, 2, 4, 8, 12, 16, 24, 32, 48, 64]

    /// The same theme the palette, the panels and the overlay paint with, so
    /// Settings stops being the one window in system colours (T42).
    private var theme: PaletteTheme { store.theme }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 10)
            tabBar
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            Rectangle()
                .fill(theme.border.opacity(0.6))
                .frame(height: 1)
            if settingsTab == .dropzones {
                DropzoneSettingsView(model: dropzoneEditor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch settingsTab {
                        case .general: generalTab
                        case .windows: windowsTab
                        case .layouts: layoutsTab
                        case .panels: panelsTab
                        case .notifications: notificationsTab
                        case .groups: groupsTab
                        case .dropzones: EmptyView()
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(settingsTab)
            }
        }
        .frame(minWidth: 560, idealWidth: 700, minHeight: 520, idealHeight: 720)
        .background(theme.background)
        .preferredColorScheme(theme.followsSystemAppearance ? nil : (theme.isDark ? .dark : .light))
        .tint(theme.accent)
        .environment(\.paletteTheme, theme)
        .toggleStyle(.switch)
        .background(SettingsWindowConfigurator(theme: theme))
        .sheet(isPresented: $showResetConfirmation) {
            ResetConfirmationView(store: store) { scope in
                showResetConfirmation = false
                store.resetToDefaults(scope: scope)
            } onCancel: {
                showResetConfirmation = false
            }
        }
        .onAppear {
            store.completeSetup()
            store.refreshPermissionState()
            store.refreshMacOSTiling()
            excludedAppsText = store.shelfExcludedApps.joined(separator: ", ")
            store.bringSettingsToFront()
        }
        // Reopening the window from the menu must also activate this accessory
        // app, otherwise the menu bar still belongs to the other app.
        .onReceive(NotificationCenter.default.publisher(for: .makiDeskFocusSettings)) { _ in
            store.bringSettingsToFront()
        }
    }

    // MARK: - Tabs

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.accent)
            Text("Settings")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.text)
            Spacer()
            Text("MakiDesk \(store.bundleVersion)")
                .font(.caption)
                .foregroundStyle(theme.subtext)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    settingsTab = tab
                } label: {
                    Text(tab.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(settingsTab == tab ? theme.text : theme.subtext)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(settingsTab == tab ? theme.surfaceSelected : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(settingsTab == tab ? .isSelected : [])
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(theme.border.opacity(0.6), lineWidth: 1))
    }

    // MARK: - General

    @ViewBuilder
    private var generalTab: some View {
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

    // MARK: - Windows

    @ViewBuilder
    private var windowsTab: some View {
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
            caption("A dark veil covers what is behind the focused window; the window itself and everything above it stay clear. It follows the window as you move or resize it and needs no permission beyond Accessibility. Menu bar, Dock and MakiDesk's own panels stay above the veil; it is left out of screenshots and recordings.")

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
            caption("⌃⌥L shows or hides a small card with the items you tick off; it stays above the other apps, in the chosen corner at the same distance from the edges as a tiled window (half the Gap in Settings ▸ Windows). Opacity is the resting value: pointing at the card or typing in it brings it to 100% until the pointer leaves, so the setting only applies while it waits. Ticking a box does not take the keyboard away from the app you are in — clicking the add field does, and Esc gives it back. Items live in checklist.json next to your groups, survive a restart and are left alone by a factory reset; the card is left out of screenshots and recordings, its height follows the list, and Reduce Transparency makes it solid.")
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
            caption("⌃⌥⇧T or the Timers menu starts one: a length with a unit (25m, 1h 30m, 40s), a bare number of minutes (25) or a time of day with a colon (8:30, meaning the next half past eight). The card sits in the chosen corner and steps aside as the pointer comes near, coming back once it moves away; it stays above the other apps and is left out of screenshots. Several timers run at once, nearest first, each with an optional label. Timers live for the session only — nothing is written to disk and nothing survives a restart — and a finished one posts a notice until you dismiss it, with a system sound when the option above is on. The sound follows the Mac's volume and mute.")
        }

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
            caption("⌥Tab opens the switcher. Choose which display it uses; the panel stays there until closed. The groups column edits the numbered groups next to the window grid; with it off the panel narrows to the cards, while ⌘1…9 and Esc still work on the cards and ⌃⌥1…9 still recalls a group from anywhere. Announcements cover adding, removing, recalling and clearing; a group that is empty, or whose windows are gone, is still reported when you ask for it. The Groups menu always lists every group.")
        }

        SettingsSection("Search & launch") {
            caption("⌥Space opens the same palette in search mode with the search field focused. Search filters open windows and installed applications; the Applications shelf below the field launches an app with Return.")
        }

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
            caption("⌃⌥O selects an area of the screen and sends the text to the clipboard, to the in-memory clipboard history, or both; Esc cancels. The history disappears when MakiDesk quits, so “History only” keeps no copy after the app closes. Vision runs on this Mac and detects the language automatically; the models (about 100 MB) stay in memory after the first use. Nothing is uploaded or written to disk.")
        }

        SettingsSection("Colour picker") {
            Picker("Copy as", selection: $colorFormat) {
                ForEach(ColorClipboardFormat.allCases) { Text($0.title).tag($0) }
            }
            caption("⌃⌥E opens a loupe and copies the colour under the click; Esc cancels. Values are converted to sRGB. The clipboard history keeps a copy when it is on.")
        }

        SettingsSection("Measure") {
            Picker("Units", selection: Binding(
                get: { MeasurementSettings.unit() },
                set: { MeasurementSettings.setUnit($0) }
            )) {
                ForEach(MeasurementUnit.allCases) { Text($0.title).tag($0) }
            }
            caption("⌃⌥R drags a measurement over any app: ⇧ keeps a square, ⌥ measures from the centre, and values snap within 6 pt to windows and displays. Measurements stay until their ✕ or Clear Measurements. Millimetres and inches are estimated from the display's reported physical size.")
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

    // MARK: - Groups

    @ViewBuilder
    private var notificationsTab: some View {
        SettingsSection("Position") {
            Picker("Placement", selection: $hudPosition) {
                ForEach(HUDPosition.allCases) { position in
                    Text(position.label).tag(position)
                }
            }
            Picker("Show on", selection: $hudScreen) {
                ForEach(PaletteScreenLocation.allCases) { location in
                    Text(location.label).tag(location)
                }
            }
            caption("Notices follow the focus or the pointer and stay inside the display's visible frame, including displays with a negative origin. The fallback is the main display.")
        }

        SettingsSection("Duration") {
            SliderRow(title: "Base duration", value: $hudBaseDuration,
                      range: 1...5, step: 0.2, unit: " s", decimals: 1)
            caption("Confirmations, information and successes stay for the base duration, warnings about half as long again, errors twice as long with a 3 s floor. Up to two notices are visible; the rest wait in a queue. Progress notices stay until the work ends.")
        }

        SettingsSection("Sticky notices") {
            Toggle("Keep errors until I dismiss them", isOn: $hudKeepErrors)
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

        SettingsSection("Appearance") {
            SliderRow(title: "Text size", value: $hudTextSize,
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
            Toggle("Compact notices (title only)", isOn: $hudCompact)
            Toggle("Announce with VoiceOver", isOn: $hudVoiceOver)
            caption("The state tints the icon and border: grey for information, accent for a confirmation, green for success, orange for a warning, red for an error. Each Preview button shows its state in the current placement, size and theme; the error one follows the sticky option above. The icon, padding and corners grow with the text. Notices are excluded from screenshots and recordings, and with Reduce Motion on they appear without the short fade.")
        }

        SettingsSection("History") {
            Toggle("Keep a history (in memory)", isOn: $hudHistoryEnabled)
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
            .font(.caption)
            .foregroundStyle(theme.subtext)
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text)
            }
            VStack(alignment: .leading, spacing: 9) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(theme.surface.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(theme.border.opacity(0.55), lineWidth: 1))
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
            .font(.caption)
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

/// Reaches the `NSWindow` that hosts the Settings view so the window can be made
/// resizable and to set a minimum size,
/// without depending on timing or on which windows happen to be visible. It also
/// paints the titlebar and the window background with the palette theme, and
/// switches the window appearance so native controls stay readable on dark and
/// light themes alike (T42).
private struct SettingsWindowConfigurator: NSViewRepresentable {
    let theme: PaletteTheme

    func makeNSView(context: Context) -> NSView {
        let view = WindowConfiguringView()
        view.apply(theme)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowConfiguringView)?.apply(theme)
    }

    private final class WindowConfiguringView: NSView {
        private var theme = PaletteTheme.all[0]

        func apply(_ theme: PaletteTheme) {
            self.theme = theme
            guard let window else { return }
            configure(window)
            // Reapply after SwiftUI finishes configuring the hosting window.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.configure(window)
            }
        }

        private func configure(_ window: NSWindow) {
            // Keep the full-size content and hide the title instead of removing
            // `.fullSizeContentView`: removing it after SwiftUI has laid out
            // the hosted view leaves that view stretched under the titlebar, so
            // the header is clipped and the titlebar no longer receives the
            // drags that move the window. With the flag kept and the title
            // hidden, SwiftUI insets the content below the traffic lights and
            // the empty titlebar strip stays draggable.
            window.styleMask.insert([.resizable, .fullSizeContentView])
            let minimum = NSSize(width: 560, height: 520)
            window.minSize = minimum
            window.contentMinSize = minimum
            let unbounded = CGFloat.greatestFiniteMagnitude
            window.maxSize = NSSize(width: unbounded, height: unbounded)
            window.contentMaxSize = NSSize(width: unbounded, height: unbounded)
            window.identifier = NSUserInterfaceItemIdentifier("MakiDeskSettingsWindow")
            // MakiDesk is a menu-bar app and its own windows are excluded from
            // the window switcher. Keep Settings reachable above normal app
            // windows after it has been opened from the menu bar.
            window.level = .floating
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = ""
            window.titlebarSeparatorStyle = .none
            // Let AppKit reserve the window edges for resizing. The titlebar
            // remains draggable even without a visible title.
            window.isMovableByWindowBackground = false
            window.backgroundColor = NSColor(theme.background)
            window.appearance = theme.followsSystemAppearance
                ? nil
                : NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply(theme)
        }
    }
}
