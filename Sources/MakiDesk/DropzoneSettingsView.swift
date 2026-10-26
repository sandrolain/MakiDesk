import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The Dropzones tab (T44): one command per zone, run on what is dropped on the
/// shelf strip.
///
/// A master-detail editor rather than a form: a command is long, the list can
/// hold many zones, and both need to stay visible. This is the only Settings tab
/// that is not inside the window's scroll view.
struct DropzoneSettingsView: View {
    @ObservedObject var model: DropzoneEditorModel
    @Environment(\.paletteTheme) private var theme

    @State private var showingShortcuts = false
    @State private var shortcutZoneID: UUID?
    @State private var showingPresets = false
    @State private var presetZoneID: UUID?
    @State private var deleteCandidate: DropzoneConfig?
    @State private var testResult: DropzoneTestResult?
    @State private var testingZoneID: UUID?
    @State private var isCancelling = false
    @State private var preferredSidebarWidth: CGFloat = 225
    @State private var sidebarDragOrigin: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            header
                .fixedSize(horizontal: false, vertical: true)
            if hasBanner { banners }
            Rectangle()
                .fill(theme.border.opacity(0.5))
                .frame(height: 1)
            GeometryReader { geometry in
                let sidebarWidth = min(preferredSidebarWidth,
                                       max(0, geometry.size.width - 307))
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: sidebarWidth)
                    sidebarDivider(width: sidebarWidth, availableWidth: geometry.size.width)
                    detail
                }
                .frame(width: geometry.size.width, height: geometry.size.height,
                       alignment: .topLeading)
                .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .sheet(isPresented: $showingShortcuts) {
            DropzoneShortcutPicker(model: model) { shortcut in
                apply(shortcut)
            }
        }
        .sheet(isPresented: $showingPresets) {
            if let id = presetZoneID,
               let index = model.zones.firstIndex(where: { $0.id == id }) {
                DropzonePresetPicker(zone: $model.zones[index])
            } else {
                VStack(spacing: 12) {
                    Text("This dropzone no longer exists.")
                        .font(.callout)
                    Button("Close") { showingPresets = false }
                }
                .padding(24)
                .frame(width: 320, height: 140)
            }
        }
        .sheet(item: $testResult) { result in
            DropzoneTestResultView(result: result)
        }
        .alert("Delete dropzone?", isPresented: deleteAlert, presenting: deleteCandidate) { zone in
            Button("Delete", role: .destructive) {
                model.delete(zone.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { zone in
            Text("“\(zone.name)” will be removed. A command that is already running is not stopped.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .makiDeskDropzonesChanged)) { _ in
            if model.isDirty == false { model.reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .makiDeskDropzonesReset)) { _ in
            model.reload()
        }
        .onAppear {
            // Pick up a hand edit or a reset without throwing away a draft.
            if model.isDirty == false { model.reload() }
        }
    }

    // MARK: - Header and banners

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dropzones")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text("Commands run on what you drop on the shelf strip.")
                    .font(.caption)
                    .foregroundStyle(theme.subtext)
            }
            Spacer()
            if model.isDirty {
                Text("Unsaved changes")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if model.statusMessage != nil {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Button("Revert") { model.revert() }
                .disabled(!model.isDirty)
            Button("Save") { model.save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.canSave)
                .help("Write dropzones.json")
            Menu {
                Button("Reload from Disk") { model.reload() }
                    .disabled(model.isDirty)
                Button("Show Configuration in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.fileURL])
                }
                .disabled(!FileManager.default.fileExists(atPath: model.fileURL.path))
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Reload or show the configuration file")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var hasBanner: Bool {
        if model.errorMessage != nil { return true }
        switch model.snapshot.state {
        case .corrupt, .futureVersion, .untrustedPermissions: return true
        case .missing, .loaded: return false
        }
    }

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 6) {
            if let error = model.errorMessage {
                banner(error, icon: "xmark.octagon.fill", tint: .red, onClose: { model.clearMessages() })
            }
            switch model.snapshot.state {
            case .corrupt:
                banner("The file could not be read; it was set aside next to it as dropzones.json.bak. The list starts empty.",
                       icon: "exclamationmark.triangle.fill", tint: .orange)
            case let .futureVersion(version):
                banner("This file was written by MakiDesk \(version) and is read-only here. Update the app to edit it.",
                       icon: "lock.fill", tint: .orange)
            case .untrustedPermissions:
                banner("This configuration is a symlink or can be modified by other users, so nothing in it runs. Press Save to replace it with a private file.",
                       icon: "lock.open.fill", tint: .orange)
            case .missing, .loaded:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func banner(_ text: String, icon: String, tint: Color, onClose: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.subtext)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(tint.opacity(0.35), lineWidth: 1))
    }

    // MARK: - Sidebar

    private func sidebarDivider(width: CGFloat, availableWidth: CGFloat) -> some View {
        Rectangle()
            .fill(theme.border.opacity(0.5))
            .frame(width: 1)
            .frame(width: 7)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let origin = sidebarDragOrigin ?? width
                    sidebarDragOrigin = origin
                    let maximum = max(190, min(270, availableWidth - 307))
                    preferredSidebarWidth = min(max(190, origin + value.translation.width), maximum)
                }
                .onEnded { _ in sidebarDragOrigin = nil })
            .accessibilityLabel("Dropzone list divider")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Zones")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text("\(model.zones.count)/\(DropzoneStore.maximumZones)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.subtext)
                Spacer()
                Button { model.add() } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Add a dropzone")
                .disabled(!model.canEdit || model.zones.count >= DropzoneStore.maximumZones)
            }
            .padding(.horizontal, 4)

            if model.zones.isEmpty {
                emptySidebar
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(model.zones) { zone in
                            if let index = model.zones.firstIndex(where: { $0.id == zone.id }) {
                                DropzoneListRow(
                                    zone: $model.zones[index],
                                    selected: model.selection == zone.id,
                                    canEdit: model.canEdit,
                                    canMoveUp: model.canMove(zone.id, by: -1),
                                    canMoveDown: model.canMove(zone.id, by: 1),
                                    onSelect: { model.selection = zone.id },
                                    onMoveUp: { model.move(zone.id, by: -1) },
                                    onMoveDown: { model.move(zone.id, by: 1) },
                                    onDuplicate: { model.duplicate(zone.id) },
                                    onDelete: { deleteCandidate = zone })
                            }
                        }
                    }
                    .padding(.horizontal, 1)
                    .padding(.vertical, 2)
                }
            }

            Divider()
                .opacity(0.4)
            Text("The strip appears under the shelf while you drag. Zones that do not match the items are dimmed.")
                .font(.caption2)
                .foregroundStyle(theme.subtext)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.background)
    }

    private var emptySidebar: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.square")
                .font(.system(size: 20))
                .foregroundStyle(theme.subtext)
            Text("No dropzones")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.text)
            Text("Add one to run a command on a drop.")
                .font(.caption2)
                .foregroundStyle(theme.subtext)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Add") { model.add() }
                .controlSize(.small)
                .disabled(!model.canEdit)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.surface.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(theme.border.opacity(0.45), lineWidth: 1))
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let index = model.zones.firstIndex(where: { $0.id == model.selection }) {
            ScrollView {
                DropzoneDetailView(
                    zone: $model.zones[index],
                    canEdit: model.canEdit,
                    shortcuts: model.shortcuts,
                    shortcutsLoaded: model.shortcutsLoaded,
                    testing: testingZoneID == model.zones[index].id,
                    isCancelling: isCancelling,
                    onChoosePreset: {
                        presetZoneID = model.zones[index].id
                        showingPresets = true
                    },
                    onChooseShortcut: {
                        shortcutZoneID = model.zones[index].id
                        showingShortcuts = true
                    },
                    onTest: { beginTest(model.zones[index]) },
                    onCancelTest: { cancelTest() })
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(model.zones[index].id)
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        } else {
            emptyDetail
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.square.on.square")
                .font(.system(size: 30))
                .foregroundStyle(theme.accent)
            Text(model.zones.isEmpty ? "Commands on drop" : "Select a dropzone")
                .font(.headline)
                .foregroundStyle(theme.text)
            Text("A dropzone is a command you write. Pick what it accepts, then drop it on the shelf strip. Placeholders such as {paths} and {textfile} carry the dropped items; the first run asks for confirmation.")
                .font(.caption)
                .foregroundStyle(theme.subtext)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
            if model.zones.isEmpty {
                Button("Add Dropzone") { model.add() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canEdit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Actions

    private var deleteAlert: Binding<Bool> {
        Binding(get: { deleteCandidate != nil },
                set: { presented in if presented == false { deleteCandidate = nil } })
    }

    private func apply(_ shortcut: DropzoneShortcut) {
        guard let id = shortcutZoneID,
              let index = model.zones.firstIndex(where: { $0.id == id }) else { return }
        var zone = model.zones[index]
        var line = "shortcuts run \(shortcut.id)"
        if let flag = DropzoneShortcutCatalog.inputFlag(for: zone.accepts) {
            line += " " + flag
        }
        zone.command.line = line
        zone.command.mode = .argv
        model.zones[index] = zone
        model.selection = id
        model.clearMessages()
    }

    private func beginTest(_ zone: DropzoneConfig) {
        guard testingZoneID == nil else { return }
        guard model.save() else { return }
        guard let current = model.zones.first(where: { $0.id == zone.id }) else { return }
        let acceptsFiles = current.accepts.kinds.contains(.files)
        let acceptsImages = current.accepts.kinds.contains(.images)
        guard acceptsFiles || acceptsImages else { return }

        let panel = NSOpenPanel()
        panel.title = "Test “\(current.name)”"
        panel.message = "Choose the file(s) to pass to this dropzone."
        panel.prompt = "Test"
        panel.canChooseFiles = true
        panel.canChooseDirectories = acceptsFiles
        panel.allowsMultipleSelection = true
        var types = current.accepts.utis.compactMap { UTType($0) }
        if acceptsImages { types.append(.image) }
        if types.isEmpty == false { panel.allowedContentTypes = Array(Set(types)) }
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard urls.isEmpty == false else { return }

        let drop: DropzoneDrop
        if acceptsFiles {
            drop = DropzoneDrop(files: urls)
        } else {
            var images: [DropzoneDrop.Image] = []
            for url in urls {
                guard let image = NSImage(contentsOf: url),
                      let data = image.shelfPNGData else { continue }
                let name = url.deletingPathExtension().lastPathComponent + ".png"
                images.append(.init(data: data, name: name, uti: "public.png"))
            }
            guard images.isEmpty == false else {
                testResult = DropzoneTestResult(zoneName: current.name,
                                                title: "Could not read the image",
                                                succeeded: false,
                                                message: "The selected file could not be read as image data.",
                                                outputURL: nil)
                return
            }
            drop = DropzoneDrop(images: images)
        }
        runTest(current, drop: drop)
    }

    private func runTest(_ zone: DropzoneConfig, drop: DropzoneDrop) {
        testingZoneID = zone.id
        isCancelling = false
        Task { @MainActor in
            var outcome = await DropzoneCoordinator.shared.run(zoneID: zone.id, drop: drop)
            if case let .needsConfirmation(pending) = outcome {
                if confirmRun(pending) {
                    let hash = DropzoneConfig.confirmationHash(for: pending.command)
                    switch DropzoneCoordinator.shared.confirm(zoneID: zone.id,
                                                              approvedCommandHash: hash) {
                    case .confirmed:
                        model.reload()
                        outcome = await DropzoneCoordinator.shared.run(zoneID: zone.id,
                                                                      drop: drop)
                    case .commandChanged:
                        outcome = .failed("The command changed while confirmation was open. Review it and try again.")
                    case .unavailable:
                        outcome = .failed("The dropzone is no longer available.")
                    case let .saveFailed(message):
                        outcome = .failed("The confirmation could not be saved: \(message)")
                    }
                } else {
                    outcome = .cancelled
                }
            }
            if case let .needsOverwriteConfirmation(pending, path) = outcome {
                if confirmOverwrite(pending, path: path) {
                    outcome = await DropzoneCoordinator.shared.run(zoneID: pending.id,
                                                                  drop: drop,
                                                                  confirmedOverwritePath: path)
                } else {
                    outcome = .cancelled
                }
            }
            if case .needsConfirmation = outcome {
                outcome = .failed("The command changed during confirmation. Run the test again to review it.")
            } else if case .needsOverwriteConfirmation = outcome {
                outcome = .failed("The output changed during confirmation. Run the test again to review it.")
            }
            testingZoneID = nil
            isCancelling = false
            testResult = makeResult(zone: zone, outcome: outcome)
        }
    }

    private func cancelTest() {
        guard let id = testingZoneID, isCancelling == false else { return }
        isCancelling = true
        Task { @MainActor in
            await DropzoneCoordinator.shared.cancel(zoneID: id)
        }
    }

    private func confirmOverwrite(_ zone: DropzoneConfig, path: String) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Replace an existing file?"
        alert.informativeText = """
        “\(zone.name)” may replace:

        \(path)

        Continue?
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Run Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmRun(_ zone: DropzoneConfig) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Run “\(zone.name)”?"
        alert.informativeText = "This command is new or changed. It will run:\n\n\(zone.command.line)\n\nOnly continue if you wrote it or trust where it came from."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func makeResult(zone: DropzoneConfig, outcome: DropzoneCoordinator.Outcome) -> DropzoneTestResult {
        switch outcome {
        case let .finished(result):
            var lines: [String] = []
            if let exit = result.exitCode {
                if let signal = result.termSignal {
                    lines.append("Exit code: \(exit) (signal \(signal))")
                } else {
                    lines.append("Exit code: \(exit)")
                }
            } else {
                lines.append("Exit code: unavailable")
            }
            lines.append(String(format: "Duration: %.2f s", result.duration))
            if result.timedOut { lines.append("The timeout stopped the command.") }
            if result.cancelled { lines.append("The test was cancelled.") }
            let stderr = result.stderrExcerpt.trimmingCharacters(in: .whitespacesAndNewlines)
            if stderr.isEmpty == false {
                lines.append("")
                lines.append("stderr:")
                lines.append(stderr)
            }
            if let stdout = result.stdoutExcerpt?.trimmingCharacters(in: .whitespacesAndNewlines),
               stdout.isEmpty == false {
                lines.append("")
                lines.append("stdout:")
                lines.append(stdout)
            } else if result.stdoutExcerpt == nil, result.succeeded {
                lines.append("")
                lines.append("stdout was not captured (turn on “Show its output in the notice”).")
            }
            if FileManager.default.fileExists(atPath: result.workDirectory.path) {
                lines.append("")
                lines.append("Run folder: \(result.workDirectory.path)")
            }
            let title = result.cancelled ? "Test cancelled" : (result.succeeded ? "Test finished" : "Test failed")
            return DropzoneTestResult(zoneName: zone.name,
                                      title: title,
                                      succeeded: result.succeeded,
                                      message: lines.joined(separator: "\n"),
                                      outputURL: outputURL(for: result))
        case let .rejected(reason):
            return DropzoneTestResult(zoneName: zone.name,
                                      title: "The drop was refused",
                                      succeeded: false,
                                      message: reason.errorDescription ?? "The drop was refused.",
                                      outputURL: nil)
        case .cancelled:
            return DropzoneTestResult(zoneName: zone.name,
                                      title: "Test cancelled",
                                      succeeded: false,
                                      message: "The run was cancelled before the command started.",
                                      outputURL: nil)
        case let .failed(message):
            return DropzoneTestResult(zoneName: zone.name,
                                      title: "Test could not run",
                                      succeeded: false,
                                      message: message,
                                      outputURL: nil)
        case let .needsConfirmation(pending):
            return DropzoneTestResult(zoneName: zone.name,
                                      title: "Confirmation missing",
                                      succeeded: false,
                                      message: "“\(pending.name)” still needs confirmation. Try again.",
                                      outputURL: nil)
        case let .needsOverwriteConfirmation(pending, path):
            return DropzoneTestResult(zoneName: zone.name,
                                      title: "Overwrite confirmation missing",
                                      succeeded: false,
                                      message: "“\(pending.name)” still needs confirmation for \(path). Try again.",
                                      outputURL: nil)
        }
    }

    private func outputURL(for result: CommandResult) -> URL? {
        let output = result.workDirectory.appendingPathComponent("output", isDirectory: true)
        if FileManager.default.fileExists(atPath: output.path) { return output }
        if FileManager.default.fileExists(atPath: result.workDirectory.path) { return result.workDirectory }
        return nil
    }
}
