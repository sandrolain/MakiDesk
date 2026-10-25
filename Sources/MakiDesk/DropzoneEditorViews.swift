import AppKit
import SwiftUI

/// Shared views for the Dropzones tab: the icon, one row of the list, the
/// Shortcuts picker and the result of a test run.

enum DropzoneIconFolder {
    /// `~/Library/Application Support/MakiDesk/DropzoneIcons`.
    static var url: URL {
        DropzoneStore.defaultFileURL.deletingLastPathComponent()
            .appendingPathComponent("DropzoneIcons", isDirectory: true)
    }
}

/// Draws a symbol, an emoji or a copied image at the same size, so the list and
/// the shelf strip can share the persisted icon representation.
struct DropzoneGlyph: View {
    @Environment(\.paletteTheme) private var theme

    let icon: DropzoneIcon
    var size: CGFloat = 22

    var body: some View {
        Group {
            switch icon {
            case let .symbol(name):
                if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
                    Image(systemName: name)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(theme.text)
                } else {
                    Image(systemName: "questionmark.square.dashed")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(theme.subtext)
                }
            case let .emoji(value):
                Text(value)
                    .font(.system(size: size * 0.78))
                    .lineLimit(1)
            case let .file(name):
                if name.isEmpty == false,
                   let image = NSImage(contentsOf: DropzoneIconFolder.url.appendingPathComponent(name)) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "photo")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(theme.subtext)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// One row in the zones list. Selection is the row's background; the menu holds
/// the less frequent actions so the narrow sidebar stays readable.
struct DropzoneListRow: View {
    @Environment(\.paletteTheme) private var theme

    @Binding var zone: DropzoneConfig
    let selected: Bool
    let canEdit: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onSelect: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            DropzoneGlyph(icon: zone.icon, size: 22)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(zone.name.isEmpty ? "Untitled" : zone.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(zone.enabled ? theme.text : theme.subtext)
                        .lineLimit(1)
                    if zone.issues().isEmpty == false {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                    if zone.requiresConfirmation {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.subtext)
                    }
                }
                Text(commandSummary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.subtext)
                    .lineLimit(2)
            }
            Spacer(minLength: 2)
            VStack(spacing: 2) {
                Toggle("", isOn: $zone.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help(zone.enabled ? "Disable this zone" : "Enable this zone")
                    .disabled(!canEdit)
                Menu {
                    Button("Move Up", action: onMoveUp).disabled(!canMoveUp)
                    Button("Move Down", action: onMoveDown).disabled(!canMoveDown)
                    Divider()
                    Button("Duplicate", action: onDuplicate).disabled(!canEdit)
                    Button("Delete…", role: .destructive, action: onDelete).disabled(!canEdit)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.subtext)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!canEdit)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(selected ? theme.surfaceSelected : theme.surface.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(selected ? theme.accent.opacity(0.6) : theme.border.opacity(0.45), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .help(commandSummary)
    }

    private var commandSummary: String {
        let line = zone.command.line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.isEmpty == false else { return "No command yet" }
        let first = line.components(separatedBy: .newlines).first ?? line
        return (zone.command.mode == .shell ? "zsh: " : "") + first
    }
}

/// What one test run produced, in a shape a sheet can show.
struct DropzoneTestResult: Identifiable {
    let id = UUID()
    let zoneName: String
    let title: String
    let succeeded: Bool
    let message: String
    let outputURL: URL?
}

struct DropzoneTestResultView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.paletteTheme) private var theme

    let result: DropzoneTestResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(result.succeeded ? .green : .red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.headline)
                        .foregroundStyle(theme.text)
                    Text(result.zoneName)
                        .font(.caption)
                        .foregroundStyle(theme.subtext)
                }
                Spacer()
            }
            ScrollView {
                Text(result.message)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 7).fill(theme.background.opacity(0.55)))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .stroke(theme.border.opacity(0.5), lineWidth: 1))
            }
            .frame(minHeight: 180, maxHeight: 300)
            HStack {
                if let url = result.outputURL {
                    Button("Open Run Folder") { NSWorkspace.shared.open(url) }
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 560, height: 400)
        .background(theme.background)
        .environment(\.paletteTheme, theme)
    }
}

/// Picks a Shortcut only to prefill a command. Shortcuts is never a separate
/// concept in the model: the line written here is `shortcuts run <UUID>`.
struct DropzoneShortcutPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.paletteTheme) private var theme

    @ObservedObject var model: DropzoneEditorModel
    let onPick: (DropzoneShortcut) -> Void

    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add from Shortcuts")
                        .font(.headline)
                        .foregroundStyle(theme.text)
                    Text("Choosing one replaces the command line with shortcuts run <UUID> and an input path. It does not run the shortcut now.")
                        .font(.caption)
                        .foregroundStyle(theme.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    Task { await model.refreshShortcuts() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload the list")
                .disabled(model.isLoadingShortcuts)
            }

            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)

            if model.isLoadingShortcuts {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else if let error = model.shortcutsError, model.shortcuts.isEmpty {
                VStack(spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                    Text("You can still type the command by hand.")
                        .font(.caption)
                        .foregroundStyle(theme.subtext)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                if let error = model.shortcutsError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if filtered.isEmpty {
                    Text(model.shortcutsLoaded ? "No shortcuts found." : "Open the list to load your shortcuts.")
                        .font(.caption)
                        .foregroundStyle(theme.subtext)
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filtered) { shortcut in
                                Button {
                                    onPick(shortcut)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "bolt.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(theme.accent)
                                        Text(shortcut.name)
                                            .foregroundStyle(theme.text)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(shortcut.id.prefix(8))
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(theme.subtext)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(minHeight: 220)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 440, height: 500)
        .background(theme.background)
        .environment(\.paletteTheme, theme)
        .task {
            if model.shortcutsLoaded == false {
                await model.refreshShortcuts()
            }
        }
    }

    private var filtered: [DropzoneShortcut] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return model.shortcuts }
        return model.shortcuts.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.id.localizedCaseInsensitiveContains(trimmed)
        }
    }
}

/// Chooses a starting command for the selected zone. Applying a preset edits the
/// draft only: nothing runs, and Save/Revert still decide whether it persists.
struct DropzonePresetPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.paletteTheme) private var theme

    @Binding var zone: DropzoneConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Command Presets")
                        .font(.headline)
                        .foregroundStyle(theme.text)
                    Text("Replaces the command line and output settings. The zone’s accepted kinds stay as they are; nothing runs now.")
                        .font(.caption)
                        .foregroundStyle(theme.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(DropzoneCommandPreset.Category.allCases) { category in
                        let presets = presets(in: category)
                        if presets.isEmpty == false {
                            Text(category.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.subtext)
                                .padding(.top, 2)
                            ForEach(presets) { preset in
                                Button {
                                    preset.apply(to: &zone)
                                    dismiss()
                                } label: {
                                    presetRow(preset)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            HStack {
                Text("Placeholders are expanded by MakiDesk; unknown braces stay literal.")
                    .font(.caption2)
                    .foregroundStyle(theme.subtext)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 640, height: 560)
        .background(theme.background)
        .environment(\.paletteTheme, theme)
    }

    private func presets(in category: DropzoneCommandPreset.Category) -> [DropzoneCommandPreset] {
        DropzoneCommandPreset.all.filter { $0.category == category }
    }

    private func presetRow(_ preset: DropzoneCommandPreset) -> some View {
        let symbol = NSImage(systemSymbolName: preset.symbol, accessibilityDescription: nil) != nil
            ? preset.symbol : "bolt.fill"
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(theme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(preset.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Spacer()
                    Text("Apply")
                        .font(.caption)
                        .foregroundStyle(theme.accent)
                }
                Text(preset.summary)
                    .font(.caption)
                    .foregroundStyle(theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                Text((preset.mode == .shell ? "zsh: " : "") + preset.line)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.subtext)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(preset.line)
                if let expected = preset.expectedOutput {
                    Text("Checks \(expected)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(theme.accent.opacity(0.9))
                        .lineLimit(1)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.surface.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(theme.border.opacity(0.45), lineWidth: 1))
        .contentShape(Rectangle())
    }
}
