import AppKit
import SwiftUI

/// One line in the Checks card.
struct DropzoneCheck {
    enum Level { case error, warning, info }
    let level: Level
    let text: String
}

// MARK: - Command, runtime, feedback, test and checks

extension DropzoneDetailView {
    // MARK: Command

    var commandSection: some View {
        SettingsSection("Command") {
            TextEditor(text: $zone.command.line)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 86)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.background.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(theme.border.opacity(0.6), lineWidth: 1))

            Picker("Mode", selection: $zone.command.mode) {
                Text("Arguments (no shell)").tag(CommandSpec.Mode.argv)
                Text("Shell (zsh)").tag(CommandSpec.Mode.shell)
            }
            .pickerStyle(.segmented)

            if zone.command.mode == .shell {
                Label("Shell mode runs this as zsh code. The app quotes placeholders for you; do not put quotes around a placeholder.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                caption("Arguments mode does not use a shell: pipes, redirects and shell variables are passed as plain text. Choose Shell for those.")
            }

            placeholderHelp

            HStack(spacing: 8) {
                Button {
                    onChoosePreset()
                } label: {
                    Label("Presets…", systemImage: "square.stack.3d.up")
                }
                Button {
                    onChooseShortcut()
                } label: {
                    Label("Shortcuts…", systemImage: "sparkles")
                }
                if let argument = DropzoneEditorChecks.shortcutArgument(in: zone.command) {
                    Text(argument)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(theme.subtext)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            caption("Presets replace the line and output settings with a starting point; nothing runs now. Shortcuts fills it with “shortcuts run <UUID>” plus an input path for what this zone accepts.")

            HStack(spacing: 8) {
                Button("Preview Resolution") { makePreview() }
                Spacer()
                if previewText != nil || previewError != nil {
                    Button("Clear") {
                        previewText = nil
                        previewError = nil
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(theme.subtext)
                }
            }
            if let previewText {
                Text(previewText)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.background.opacity(0.55)))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.border.opacity(0.5), lineWidth: 1))
            }
            if let previewError {
                Text(previewError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var placeholderHelp: some View {
        DisclosureGroup {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), alignment: .leading)],
                      alignment: .leading, spacing: 5) {
                ForEach(CommandPlaceholder.allCases, id: \.self) { placeholder in
                    Button {
                        appendPlaceholder(placeholder)
                    } label: {
                        Text("{\(placeholder.rawValue)}")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(theme.surfaceSelected))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(helpText(for: placeholder))
                }
            }
            .padding(.vertical, 4)
            caption("{paths} and {urls} expand to one argument per item and must be a whole argument of their own. Unknown names such as jq’s {title} stay literal.")
        } label: {
            Text("Placeholders")
                .font(.caption)
                .foregroundStyle(theme.subtext)
        }
    }

    private func helpText(for placeholder: CommandPlaceholder) -> String {
        switch placeholder {
        case .paths: return "Paths of the dropped files, one argument each"
        case .path: return "Path of the first file"
        case .parent: return "Folder containing the first dropped item"
        case .text: return "The dropped text"
        case .textfile: return "Path of a file containing the dropped text"
        case .urls: return "Dropped links, one argument each"
        case .urlsfile: return "Path of a file with one link per line"
        case .manifest: return "Path of a JSON manifest of the whole drop"
        case .workdir: return "The run’s folder"
        case .outdir: return "The run’s output folder"
        case .name: return "Name of the first item"
        case .count: return "Number of accepted items"
        }
    }

    private func appendPlaceholder(_ placeholder: CommandPlaceholder) {
        let token = "{\(placeholder.rawValue)}"
        if zone.command.line.isEmpty {
            zone.command.line = token
        } else if zone.command.line.hasSuffix(" ") || zone.command.line.hasSuffix("\n") {
            zone.command.line += token
        } else {
            zone.command.line += " " + token
        }
    }

    func makePreview() {
        previewText = nil
        previewError = nil
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("MakiDeskDropzonePreview-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let sample = directory.appendingPathComponent("sample.txt")
            try "MakiDesk preview\n".write(to: sample, atomically: true, encoding: .utf8)
            let textFile = directory.appendingPathComponent("text.txt")
            try "Preview text\n".write(to: textFile, atomically: true, encoding: .utf8)
            let urlsFile = directory.appendingPathComponent("urls.txt")
            try "https://example.com\n".write(to: urlsFile, atomically: true, encoding: .utf8)
            let manifest = directory.appendingPathComponent("manifest.json")
            try "{\"preview\":true}\n".write(to: manifest, atomically: true, encoding: .utf8)
            try fileManager.createDirectory(at: directory.appendingPathComponent("output"),
                                            withIntermediateDirectories: true)

            let payload = CommandPayload(
                workDirectory: directory.path,
                paths: [sample.path],
                text: "Preview text",
                urls: ["https://example.com"],
                name: sample.lastPathComponent,
                count: 1,
                kinds: ["files"],
                textFile: textFile.path,
                urlsFile: urlsFile.path,
                manifestFile: manifest.path,
                context: [
                    "MAKIDESK_ZONE": zone.id.uuidString,
                    "MAKIDESK_ZONE_NAME": zone.name
                ])
            let resolver = CommandResolver()
            let resolved = try resolver.resolve(zone.command, payload: payload)
            var lines: [String] = []
            let words = [resolved.executable.path] + resolved.arguments
            lines.append(words.map(CommandLineTokenizer.shellQuote).joined(separator: " "))
            lines.append("Working directory: \(resolved.workingDirectory.path)")
            lines.append("Standard input: \(resolved.stdinFile?.path ?? "none")")
            if zone.command.environment.isEmpty == false {
                lines.append("")
                lines.append("Environment overrides:")
                for key in zone.command.environment.keys.sorted() {
                    lines.append("  \(key)=\(zone.command.environment[key] ?? "")")
                }
            }
            if let template = zone.expectedOutput?.trimmingCharacters(in: .whitespacesAndNewlines),
               template.isEmpty == false {
                lines.append("")
                if let expanded = try? resolver.resolvePathTemplate(template, payload: payload) {
                    let path = (expanded as NSString).expandingTildeInPath
                    let full = path.hasPrefix("/")
                        ? path
                        : resolved.workingDirectory.appendingPathComponent(path).path
                    let exists = FileManager.default.fileExists(atPath: full)
                    lines.append("Output check: \(full)\(exists ? " (already exists)" : "")")
                } else {
                    lines.append("Output check: cannot resolve \(template)")
                }
            }
            lines.append("")
            lines.append("Sample paths point to a temporary folder, removed after this preview.")
            previewText = lines.joined(separator: "\n")
        } catch {
            previewError = error.localizedDescription
        }
    }

    // MARK: Runtime

    var runtimeSection: some View {
        SettingsSection("Runtime") {
            Picker("Standard input", selection: $zone.command.stdin) {
                Text("Nothing").tag(CommandSpec.Stdin.none)
                Text("The dropped text, as a file").tag(CommandSpec.Stdin.text)
                Text("The manifest (JSON)").tag(CommandSpec.Stdin.manifest)
            }
            caption("Use {textfile} or {manifest} in the command to pass the path as an argument instead.")

            HStack(spacing: 8) {
                Text("Timeout")
                TextField("60", value: $zone.command.timeoutSeconds, format: .number)
                    .frame(width: 64)
                Text("seconds (0 = none)")
                    .foregroundStyle(theme.subtext)
                Spacer()
            }

            HStack(spacing: 8) {
                TextField("Run in the run’s folder", text: workingDirectoryBinding)
                Button("Choose…") { chooseWorkingDirectory() }
                if zone.command.workingDirectory?.isEmpty == false {
                    Button("Clear") { zone.command.workingDirectory = nil }
                }
            }
            caption("A relative working directory is not expanded; use Choose… for an absolute path.")

            TextField("Check an output path before running (optional)", text: expectedOutputBinding)
            caption("If this path already exists, the run asks before continuing. Placeholders such as {parent}/archive.zip are expanded; leave empty for no check.")

            Toggle("Keep the run folder after the command", isOn: $zone.command.keepWorkdir)
            caption("The folder holds stdout, stderr and what the command wrote under output/. It is removed when the command ends unless kept, the output is revealed, or the command fails.")

            DisclosureGroup {
                TextEditor(text: $environmentText)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .frame(height: 64)
                    .background(RoundedRectangle(cornerRadius: 5).fill(theme.background.opacity(0.55)))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(theme.border.opacity(0.55), lineWidth: 1))
                if let environmentWarning {
                    Text(environmentWarning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                caption("One KEY=VALUE per line; # starts a comment. MakiDesk adds MAKIDESK_WORKDIR, MAKIDESK_OUTDIR, MAKIDESK_COUNT, MAKIDESK_KINDS, MAKIDESK_ZONE, MAKIDESK_ZONE_NAME and MAKIDESK_MANIFEST.")
            } label: {
                Text("Environment variables")
                    .font(.caption)
                    .foregroundStyle(theme.subtext)
            }
        }
    }

    private var expectedOutputBinding: Binding<String> {
        Binding(get: { zone.expectedOutput ?? "" }, set: { value in
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            zone.expectedOutput = trimmed.isEmpty ? nil : trimmed
        })
    }

    private var workingDirectoryBinding: Binding<String> {
        Binding(get: { zone.command.workingDirectory ?? "" }, set: { value in
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            zone.command.workingDirectory = trimmed.isEmpty ? nil : trimmed
        })
    }

    private func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Working Directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        zone.command.workingDirectory = url.path
    }

    // MARK: Feedback

    var feedbackSection: some View {
        SettingsSection("Feedback") {
            Toggle("Notify when the command finishes", isOn: $zone.feedback.notifyOnSuccess)
            Toggle("Show its output in the notice", isOn: showOutputBinding)
            Toggle("Open the output folder when it has files", isOn: $zone.feedback.revealOutput)
            caption("Output is always written under {outdir}; the notice shows only a short excerpt. A failed command reports its exit code and stderr.")
        }
    }

    private var showOutputBinding: Binding<Bool> {
        Binding(get: { zone.feedback.showOutput != .none }, set: { on in
            zone.feedback.showOutput = on ? .stdout : .none
        })
    }

    // MARK: Test

    var testSection: some View {
        SettingsSection("Try it") {
            HStack(spacing: 10) {
                Button {
                    onTest()
                } label: {
                    Label("Test with a File…", systemImage: "play.fill")
                }
                .disabled(testing || canEdit == false || canTest == false)
                if testing {
                    ProgressView()
                        .controlSize(.small)
                    Button(isCancelling ? "Stopping…" : "Stop") {
                        onCancelTest()
                    }
                    .disabled(isCancelling)
                }
                Spacer()
            }
            if canTest == false {
                caption("Testing needs a file or an image. Drop text or a link on the shelf to try this zone.")
            } else {
                caption("Saves valid changes, then runs the command on the chosen files. The first run asks for confirmation, exactly like a drop. Cancelling stops waiting; a Shortcut may keep running inside the Shortcuts app.")
            }
            if zone.requiresConfirmation {
                Label("The next run asks for confirmation because the command is new or changed.",
                      systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var canTest: Bool {
        zone.accepts.kinds.contains(.files) || zone.accepts.kinds.contains(.images)
    }

    // MARK: Checks

    var checksSection: some View {
        SettingsSection("Checks") {
            if checks.isEmpty {
                Label("Ready to run", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                ForEach(checks.indices, id: \.self) { index in
                    let check = checks[index]
                    Label(check.text, systemImage: icon(for: check.level))
                        .font(.caption)
                        .foregroundStyle(tint(for: check.level))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if checks.contains(where: { $0.level == .warning }) {
                    caption("Warnings do not block saving; the command can still fail when it runs.")
                }
            }
        }
    }

    private func icon(for level: DropzoneCheck.Level) -> String {
        switch level {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }

    private func tint(for level: DropzoneCheck.Level) -> Color {
        switch level {
        case .error: return .red
        case .warning: return .orange
        case .info: return theme.subtext
        }
    }

    var checks: [DropzoneCheck] {
        var checks = zone.issues().map {
            DropzoneCheck(level: .error, text: $0.errorDescription ?? "Invalid dropzone.")
        }
        if let warning = DropzoneEditorChecks.executableWarning(for: zone.command) {
            checks.append(DropzoneCheck(level: .warning, text: warning))
        }
        for name in DropzoneEditorChecks.placeholderTypos(in: zone.command.line) {
            let suggestion = DropzoneEditorChecks.suggestion(for: name)
                .map { " Did you mean {\($0)}?" } ?? ""
            checks.append(DropzoneCheck(level: .warning,
                                        text: "“{\(name)}” is not a placeholder.\(suggestion)"))
        }
        if let warning = shortcutWarning {
            checks.append(DropzoneCheck(level: .warning, text: warning))
        }
        if let warning = workingDirectoryWarning {
            checks.append(DropzoneCheck(level: .warning, text: warning))
        }
        if let warning = expectedOutputWarning {
            checks.append(DropzoneCheck(level: .warning, text: warning))
        }
        if let warning = iconWarning {
            checks.append(DropzoneCheck(level: .warning, text: warning))
        }
        if zone.requiresConfirmation {
            checks.append(DropzoneCheck(level: .info,
                                        text: "The next run asks for confirmation."))
        }
        return checks
    }

    private var shortcutWarning: String? {
        guard shortcutsLoaded,
              let argument = DropzoneEditorChecks.shortcutArgument(in: zone.command) else { return nil }
        let found = shortcuts.contains {
            $0.id.caseInsensitiveCompare(argument) == .orderedSame || $0.name == argument
        }
        guard found == false else { return nil }
        if UUID(uuidString: argument) != nil {
            return "No shortcut with this UUID. It may have been deleted; run Refresh in the Shortcuts picker."
        }
        return "No shortcut named “\(argument)”."
    }

    private var workingDirectoryWarning: String? {
        guard let raw = zone.command.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.isEmpty == false else { return nil }
        let path = (raw as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return "The working directory does not exist: \(path)"
        }
        return nil
    }

    private var expectedOutputWarning: String? {
        guard let raw = zone.expectedOutput?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.isEmpty == false else { return nil }
        if raw.contains("{paths}") || raw.contains("{urls}") {
            return "The checked output must be one path; {paths} and {urls} expand to several items."
        }
        if let typo = DropzoneEditorChecks.placeholderTypos(in: raw).first,
           let suggestion = DropzoneEditorChecks.suggestion(for: typo) {
            return "“{\(typo)}” in the checked output is not a placeholder. Did you mean {\(suggestion)}?"
        }
        return nil
    }

    private var iconWarning: String? {
        switch zone.icon {
        case let .symbol(name):
            if name.isEmpty { return "The icon has no SF Symbol name." }
            if NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil {
                return "Unknown SF Symbol: \(name). The strip shows a placeholder."
            }
        case let .emoji(value):
            if value.isEmpty { return "The icon has no emoji." }
        case let .file(name):
            if name.isEmpty { return "Choose an icon image." }
            let url = DropzoneIconFolder.url.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) == false {
                return "The icon image is missing; choose it again."
            }
        }
        return nil
    }
}
