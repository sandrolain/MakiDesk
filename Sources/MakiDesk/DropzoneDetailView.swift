import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The icon flavour chosen in the segmented picker. The persisted value stays
/// `DropzoneIcon`; this only drives which field is shown.
enum DropzoneIconKind: Hashable {
    case symbol
    case emoji
    case file
}

struct DropzoneUTIPreset: Identifiable {
    let label: String
    let uti: String
    var id: String { uti }
}

/// The right-hand side of the Dropzones tab: everything about one zone.
///
/// The section views live in `DropzoneDetailSections.swift` to keep each file
/// reviewable; they share this struct's draft and local editor state.
struct DropzoneDetailView: View {
    @Environment(\.paletteTheme) var theme

    @Binding var zone: DropzoneConfig
    let canEdit: Bool
    let shortcuts: [DropzoneShortcut]
    let shortcutsLoaded: Bool
    let testing: Bool
    let isCancelling: Bool
    let lastRun: DropzoneRunSummary?
    let onChoosePreset: () -> Void
    let onChooseShortcut: () -> Void
    let onTest: () -> Void
    let onCancelTest: () -> Void

    @State var utiText = ""
    @State var previewText: String?
    @State var previewError: String?
    @State var iconError: String?
    @State var environmentWarning: String?
    @State var environmentText = ""
    @State var showingSymbolPicker = false
    @State var showingEmojiPicker = false

    static let utiPresets: [DropzoneUTIPreset] = [
        DropzoneUTIPreset(label: "Images", uti: "public.image"),
        DropzoneUTIPreset(label: "PDF", uti: "com.adobe.pdf"),
        DropzoneUTIPreset(label: "Video", uti: "public.movie"),
        DropzoneUTIPreset(label: "Audio", uti: "public.audio"),
        DropzoneUTIPreset(label: "Text", uti: "public.text"),
        DropzoneUTIPreset(label: "Folders", uti: "public.folder")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let issue = zone.issues().first {
                Label(issue.errorDescription ?? "This dropzone is invalid.",
                      systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.1)))
            }
            identitySection
            acceptsSection
            commandSection
            runtimeSection
            feedbackSection
            lastRunSection
            testSection
            checksSection
        }
        .onAppear {
            utiText = zone.accepts.utis.joined(separator: ", ")
            environmentText = DropzoneEnvironmentText.format(zone.command.environment)
        }
        .onChange(of: zone.command) { _, _ in
            previewText = nil
            previewError = nil
        }
        .onChange(of: utiText) { _, _ in commitUTIs() }
        .onChange(of: zone.accepts.utis) { _, newValue in syncUTIs(newValue) }
        .onChange(of: environmentText) { _, _ in commitEnvironment() }
        .onChange(of: zone.command.environment) { _, newValue in syncEnvironment(newValue) }
        .disabled(!canEdit)
    }

    // MARK: - Identity

    private var identitySection: some View {
        SettingsSection("Dropzone") {
            HStack(alignment: .center, spacing: 12) {
                DropzoneGlyph(icon: zone.icon, size: 36)
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.surfaceSelected))
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name", text: $zone.name)
                        .font(.system(size: 14, weight: .semibold))
                    Toggle("Enabled", isOn: $zone.enabled)
                        .toggleStyle(.checkbox)
                        .help("Disabled zones stay in the list but do not appear in the strip.")
                }
            }

            Picker("Icon", selection: iconKind) {
                Text("Symbol").tag(DropzoneIconKind.symbol)
                Text("Emoji").tag(DropzoneIconKind.emoji)
                Text("Image").tag(DropzoneIconKind.file)
            }
            .pickerStyle(.segmented)

            iconControls

            caption("The name and icon are what the shelf strip shows. The command is only visible here.")
        }
    }

    private var iconKind: Binding<DropzoneIconKind> {
        Binding(get: {
            switch zone.icon {
            case .symbol: return .symbol
            case .emoji: return .emoji
            case .file: return .file
            }
        }, set: { kind in
            switch kind {
            case .symbol:
                if case .symbol = zone.icon { return }
                zone.icon = .symbol("bolt.fill")
            case .emoji:
                if case .emoji = zone.icon { return }
                zone.icon = .emoji("⚡️")
            case .file:
                if case .file = zone.icon { return }
                zone.icon = .file("")
            }
        })
    }

    @ViewBuilder
    private var iconControls: some View {
        switch zone.icon {
        case let .symbol(name):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("SF Symbol name", text: Binding(
                        get: { name },
                        set: { zone.icon = .symbol($0) }))
                    Button("Choose…") { showingSymbolPicker = true }
                        .popover(isPresented: $showingSymbolPicker, arrowEdge: .bottom) {
                            DropzoneSymbolPickerView(selected: name.isEmpty ? nil : name) { picked in
                                zone.icon = .symbol(picked)
                                showingSymbolPicker = false
                            }
                            .environment(\.paletteTheme, theme)
                        }
                }
                if name.isEmpty == false,
                   NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil {
                    Label("Unknown symbol", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        case let .emoji(value):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Emoji", text: Binding(
                        get: { value },
                        set: { zone.icon = .emoji($0) }))
                        .frame(maxWidth: 90)
                    Button("Choose…") { showingEmojiPicker = true }
                        .popover(isPresented: $showingEmojiPicker, arrowEdge: .bottom) {
                            DropzoneEmojiPickerView(selected: value.isEmpty ? nil : value) { picked in
                                zone.icon = .emoji(picked)
                                showingEmojiPicker = false
                            }
                            .environment(\.paletteTheme, theme)
                        }
                }
                caption("One emoji works best; the tile draws it at 22–64 points.")
            }
        case let .file(name):
            HStack(spacing: 8) {
                Text(name.isEmpty ? "No image chosen" : name)
                    .font(.caption)
                    .foregroundStyle(theme.subtext)
                    .lineLimit(1)
                Spacer()
                Button("Choose Image…") { chooseIcon() }
                if name.isEmpty == false {
                    Button("Remove") { zone.icon = .symbol("bolt.fill") }
                }
            }
            if let iconError {
                Text(iconError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chooseIcon() {
        iconError = nil
        let panel = NSOpenPanel()
        panel.title = "Choose an Icon Image"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileManager.default.createDirectory(at: DropzoneIconFolder.url,
                                                    withIntermediateDirectories: true)
            let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
            let name = "\(UUID().uuidString).\(ext)"
            try FileManager.default.copyItem(at: url,
                                             to: DropzoneIconFolder.url.appendingPathComponent(name))
            zone.icon = .file(name)
        } catch {
            iconError = "Could not copy the image: \(error.localizedDescription)"
        }
    }

    // MARK: - Accepts

    private var acceptsSection: some View {
        SettingsSection("Accepts") {
            Text("Kinds")
                .font(.caption)
                .foregroundStyle(theme.subtext)
            ForEach(DropzoneAccept.Kind.allCases, id: \.self) { kind in
                Toggle(kindLabel(kind), isOn: kindBinding(kind))
                    .toggleStyle(.checkbox)
            }
            caption("Images are pixels dragged from apps such as Photos or a browser. Files are icons dragged from Finder; folders count as files.")

            Text("File types")
                .font(.caption)
                .foregroundStyle(theme.subtext)
                .padding(.top, 2)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(Self.utiPresets) { preset in
                    Button {
                        toggleUTI(preset.uti)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isUTISelected(preset.uti)
                                  ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 10))
                            Text(preset.label)
                                .font(.system(size: 11))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(isUTISelected(preset.uti) ? theme.accent : theme.text)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(preset.uti)
                }
            }
            TextField("public.image, com.adobe.pdf", text: $utiText)
                .font(.system(.caption, design: .monospaced))
            caption("Files only; empty means any type. Separate UTIs with commas.")

            Picker("When only some items fit", selection: $zone.accepts.match) {
                Text("Refuse the whole drop").tag(DropzoneAccept.Match.all)
                Text("Pass the matching items").tag(DropzoneAccept.Match.any)
            }
            caption("“Any” filters the payload before the command: with a mixed drop it runs on the matching items only.")

            Stepper(value: minimumBinding, in: 1...DropzoneConfig.maximumItems) {
                Text("At least \(zone.accepts.minItems ?? 1) item(s)")
            }
            Toggle("Limit the maximum", isOn: maximumEnabled)
            if let maximum = zone.accepts.maxItems {
                Stepper(value: Binding(get: { maximum },
                                       set: { zone.accepts.maxItems = $0 }),
                        in: (zone.accepts.minItems ?? 1)...DropzoneConfig.maximumItems) {
                    Text("At most \(maximum) item(s)")
                }
            }
        }
    }

    private func kindLabel(_ kind: DropzoneAccept.Kind) -> String {
        switch kind {
        case .files: return "Files and folders"
        case .text: return "Text"
        case .urls: return "Links"
        case .images: return "Images (pixel data)"
        }
    }

    private func kindBinding(_ kind: DropzoneAccept.Kind) -> Binding<Bool> {
        Binding(get: { zone.accepts.kinds.contains(kind) }, set: { on in
            var kinds = zone.accepts.kinds
            if on {
                kinds.append(kind)
            } else {
                kinds.removeAll { $0 == kind }
            }
            zone.accepts.kinds = DropzoneAccept.Kind.allCases.filter { kinds.contains($0) }
        })
    }

    private var minimumBinding: Binding<Int> {
        Binding(get: { zone.accepts.minItems ?? 1 }, set: { value in
            zone.accepts.minItems = value
            if let maximum = zone.accepts.maxItems, maximum < value {
                zone.accepts.maxItems = value
            }
        })
    }

    private var maximumEnabled: Binding<Bool> {
        Binding(get: { zone.accepts.maxItems != nil }, set: { on in
            if on {
                zone.accepts.maxItems = max(zone.accepts.minItems ?? 1, 10)
            } else {
                zone.accepts.maxItems = nil
            }
        })
    }

    private func isUTISelected(_ uti: String) -> Bool {
        zone.accepts.utis.contains(uti)
    }

    private func toggleUTI(_ uti: String) {
        var utis = zone.accepts.utis
        if let index = utis.firstIndex(of: uti) {
            utis.remove(at: index)
        } else {
            utis.append(uti)
        }
        zone.accepts.utis = parsedUTIs(utis.joined(separator: ","))
        utiText = zone.accepts.utis.joined(separator: ", ")
    }

    // MARK: - Local text state

    func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(theme.subtext)
            .fixedSize(horizontal: false, vertical: true)
    }

    func parsedUTIs(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false && seen.insert($0).inserted }
    }

    private func commitUTIs() {
        let parsed = parsedUTIs(utiText)
        if parsed != zone.accepts.utis { zone.accepts.utis = parsed }
    }

    private func syncUTIs(_ newValue: [String]) {
        if parsedUTIs(utiText) != newValue {
            utiText = newValue.joined(separator: ", ")
        }
    }

    private func commitEnvironment() {
        let parsed = DropzoneEnvironmentText.parse(environmentText)
        if parsed.values != zone.command.environment {
            zone.command.environment = parsed.values
        }
        environmentWarning = parsed.invalid.isEmpty
            ? nil
            : "Ignored: " + parsed.invalid.joined(separator: ", ")
    }

    private func syncEnvironment(_ newValue: [String: String]) {
        if DropzoneEnvironmentText.parse(environmentText).values != newValue {
            environmentText = DropzoneEnvironmentText.format(newValue)
        }
    }
}
