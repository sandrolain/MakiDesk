import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var store: WorkspaceStore

    @State private var showResetConfirmation = false

    private static let gapOptions: [Double] = [0, 2, 4, 8, 12, 16, 24, 32, 48, 64]

    var body: some View {
        Form {
            Section("Permissions") {
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

                ViewThatFits(in: .horizontal) {
                    HStack { permissionButtons }
                    VStack(alignment: .leading) { permissionButtons }
                }
                Text("Enable MakiDesk under System Settings ▸ Privacy & Security. Window previews need Screen Recording; without it the switcher shows app icons instead. If a permission stays “required” after a rebuild: remove MakiDesk with “−”, re-add it, or run `tccutil reset Accessibility com.makidesk.app`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Build") {
                LabeledContent("Version", value: store.bundleVersion)
                LabeledContent("Bundle ID", value: store.bundleIdentifier)
                Label(
                    store.isInApplications ? "Installed in /Applications" : "Run from build folder — permissions may reset",
                    systemImage: store.isInApplications ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(store.isInApplications ? .green : .orange)
                Text("macOS ties permissions to the app's location. Install MakiDesk in /Applications to keep them across rebuilds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Placement") {
                Picker("Gap", selection: Binding(get: { store.gap }, set: { store.updateGap($0) })) {
                    ForEach(Self.gapOptions, id: \.self) { Text("\(Int($0)) px").tag($0) }
                }
                Text("Space kept between tiled windows and at the screen edges.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
                Text("Hold these keys while dragging a window to snap it to the nearest half / golden position. Control is not offered: ⌃-click opens context menus (it is macOS's secondary click).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Layouts") {
                Toggle("Ask before using the suggested layout", isOn: Binding(
                    get: { store.layoutAsksFirst },
                    set: { store.updateLayoutAsksFirst($0) }
                ))
                Text("Three keys lay out the windows in view (minimised ones and windows of hidden apps stay where they are): ⌃⌥G a grid, ⌃⌥S the golden spiral, ⌃⌥A the suggested layout. The suggestion sees how many windows there are, how much is drawn in each one (needs Screen Recording), what kind of app they are and how big they are, and says why. With this on, the suggestion appears with its reason and waits to be run again; with it off, it applies at once. Without Screen Recording it falls back to equal cells.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("macOS integration") {
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

                Text("MakiDesk's ⌥-drag is a richer replacement for the system one (it snaps to the nearest half / golden position). When the macOS setting above is on, both react at once — leave it off so only MakiDesk moves the window. Same switch as System Settings ▸ Desktop & Dock ▸ Windows ▸ “Hold ⌥ key while dragging windows to tile”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Overlay") {
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
                Text("The overlay previews the layout while commands run and when you switch windows. It appears at the chosen screen corner.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Window switcher & search") {
                Toggle("Show window previews", isOn: Binding(
                    get: { store.showPreview },
                    set: { store.updateShowPreview($0) }
                ))
                Toggle("Colour previews with the app colour", isOn: Binding(
                    get: { store.paletteTintedCards },
                    set: { store.updatePaletteTintedCards($0) }
                ))
                Toggle("Open the switcher full screen", isOn: Binding(
                    get: { store.paletteFullScreen },
                    set: { store.updatePaletteFullScreen($0) }
                ))
                Picker("Theme", selection: Binding(
                    get: { store.themeID },
                    set: { store.updateTheme($0) }
                )) {
                    ForEach(PaletteTheme.all) { Text($0.name).tag($0.id) }
                }
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
                SliderRow(title: "Opacity",
                          value: Binding(get: { store.paletteOpacity }, set: { store.updatePaletteOpacity($0) }),
                          range: 0.5...1.0, unit: "%", percent: true)
                Text("Opt-Tab opens the switcher; Opt-Space opens the same palette in search mode with the text field focused. Previews need the Screen Recording permission. The theme also colours the overlay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Columns: Automatic picks 2–4 by window count; a fixed number pins the grid (never more columns than windows). Max size is the largest a card may get; if the columns would overflow the screen width, cards shrink below it to fit. Preview boxes keep the screen's proportions in both modes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Colour previews: off keeps the cards neutral (the app colour stays in the overlay). Full screen uses the same Opt-Tab / Opt-Space shortcuts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Groups") {
                ForEach(1...9, id: \.self) { slot in
                    GroupSettingsRow(store: store, slot: slot)
                }
                Text("A group is a saved selection of windows: ⌃⌥⌘N adds or removes the front window, ⌃⌥N brings the group back. Recalling a group shows its windows where you left them — a group has no layout of its own. To give one a disposition, recall it and then run a layout (⌃⌥G grid, ⌃⌥S golden spiral, ⌃⌥A suggested): the arrangement is remembered for next time. The group column in the Opt-Tab / Opt-Space palette edits the same groups.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label("Reset to defaults…", systemImage: "arrow.counterclockwise")
                }
                Text("Puts every option in this window back to its default value. The confirmation asks whether your window groups go too. Onboarding completion and the macOS ⌥-tiling setting are always left untouched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Finish Setup") {
                    store.completeSetup()
                    NSApplication.shared.keyWindow?.close()
                }
            }
        }
        .formStyle(.grouped)
        // Every flag is a switch, never a checkbox.
        .toggleStyle(.switch)
        .sheet(isPresented: $showResetConfirmation) {
            ResetConfirmationView(store: store) { scope in
                showResetConfirmation = false
                store.resetToDefaults(scope: scope)
            } onCancel: {
                showResetConfirmation = false
            }
        }
        .frame(minWidth: 460, idealWidth: 620, minHeight: 400, idealHeight: 660)
        .padding()
        .background(SettingsWindowConfigurator())
        .onAppear {
            store.refreshPermissionState()
            store.refreshMacOSTiling()
            store.bringSettingsToFront()
        }
    }

    /// The permission buttons, shared by the horizontal and stacked variants.
    @ViewBuilder
    private var permissionButtons: some View {
        Button("Open Accessibility Settings") { store.openAccessibilitySettings() }
        Button("Request Screen Recording") { store.requestScreenRecording() }
        Button("Open Screen Recording Settings") { store.openScreenRecordingSettings() }
    }
}

/// One group in Settings: its number, its name (editable in place), how many
/// windows it holds, how a recall lays it out, and the two actions worth having
/// here — recall and empty.
private struct GroupSettingsRow: View {
    @Bindable var store: WorkspaceStore
    let slot: Int

    @State private var name: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Text("\(slot)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .leading)
            TextField("Group \(slot)", text: $name)
                .onSubmit { commit() }
                .onChange(of: name) { _, _ in commit() }
            Text("\(store.groups[slot]?.members.count ?? 0)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
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
            .foregroundStyle(.secondary)
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
    let store: WorkspaceStore
    let onReset: (WorkspaceStore.ResetScope) -> Void
    let onCancel: () -> Void

    @State private var includeGroups = false

    private var groupCount: Int { store.groups.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reset to defaults?")
                .font(.headline)
            Text("Every option in the Settings window goes back to its default value. This cannot be undone.")
                .font(.callout)
                .foregroundStyle(.secondary)
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
            }
            .toggleStyle(.checkbox)

            Text("Onboarding completion and the macOS ⌥-tiling setting are always left alone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Reset", role: .destructive) {
                    onReset(includeGroups ? [.settings, .groups] : .settings)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

/// Reaches the `NSWindow` that hosts the Settings view so the window can be made
/// resizable (the SwiftUI `Settings` scene does not always expose a resize handle),
/// without depending on timing or on which windows happen to be visible.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowConfiguringView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowConfiguringView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.insert(.resizable)
            window.level = .floating
        }
    }
}
