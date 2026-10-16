import SwiftUI

struct SettingsView: View {
    @Bindable var store: WorkspaceStore

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
                    store.shortcutsBlocked == 0
                        ? "Shortcuts active (\(store.shortcutsRegistered))"
                        : "\(store.shortcutsBlocked) shortcuts taken by another app",
                    systemImage: store.shortcutsBlocked == 0 ? "keyboard" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(store.shortcutsBlocked == 0 ? .green : .orange)

                Button("Open Accessibility Settings") { store.openAccessibilitySettings() }
                Text("Enable OrbitDesk under System Settings ▸ Privacy & Security ▸ Accessibility. If it stays “required” after a rebuild: remove OrbitDesk with “−”, re-add it, or run `tccutil reset Accessibility com.orbitdesk.app`.")
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
                Slider(value: Binding(get: { store.overlayScale }, set: { store.updateOverlayScale($0) }),
                       in: 0.7...1.6) { Text("Size") } minimumValueLabel: { Text("S") } maximumValueLabel: { Text("L") }
                Slider(value: Binding(get: { store.overlayOpacity }, set: { store.updateOverlayOpacity($0) }),
                       in: 0.4...1.0) { Text("Opacity") } minimumValueLabel: { Text("−") } maximumValueLabel: { Text("+") }
                Text("The overlay previews the layout while commands run and when you switch windows. It appears at the chosen screen corner.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Window switcher & search") {
                Toggle("Show window previews", isOn: Binding(
                    get: { store.showPreview },
                    set: { store.updateShowPreview($0) }
                ))
                Picker("Theme", selection: Binding(
                    get: { store.themeID },
                    set: { store.updateTheme($0) }
                )) {
                    ForEach(PaletteTheme.all) { Text($0.name).tag($0.id) }
                }
                Slider(value: Binding(get: { store.paletteScale }, set: { store.updatePaletteScale($0) }),
                       in: 0.8...1.4) { Text("Size") } minimumValueLabel: { Text("S") } maximumValueLabel: { Text("L") }
                Slider(value: Binding(get: { store.paletteOpacity }, set: { store.updatePaletteOpacity($0) }),
                       in: 0.5...1.0) { Text("Opacity") } minimumValueLabel: { Text("−") } maximumValueLabel: { Text("+") }
                Text("Opt-Tab opens the switcher; Opt-Space opens the same palette in search mode with the text field focused. Previews need the Screen Recording permission. The theme also colours the overlay.")
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
        .frame(width: 520)
        .padding()
        .onAppear {
            store.accessibilityTrusted = AXIsProcessTrusted()
            store.bringSettingsToFront()
        }
    }
}
