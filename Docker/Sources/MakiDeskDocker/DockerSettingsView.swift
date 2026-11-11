import AppKit
import SwiftUI
import MakiDockerCore
import MakiShared

struct DockerSettingsView: View {
    @Bindable var store: DockerStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = DockerSettingsDocument.defaults

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Docker Settings")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(16)
            Divider()
            Form {
                Section("Refresh") {
                    Stepper(value: $draft.refreshInterval, in: 2...60, step: 1) {
                        Text("Refresh every \(Int(draft.refreshInterval)) seconds")
                    }
                    Stepper(value: $draft.statsInterval, in: 1...10, step: 1) {
                        Text("Stats every \(Int(draft.statsInterval)) seconds")
                    }
                }
                Section("Containers") {
                    Picker("Terminal shell", selection: $draft.defaultShell) {
                        ForEach(DockerExecValidation.shells, id: \.self) { shell in
                            Text(shell).tag(shell)
                        }
                    }
                    Toggle("Confirm destructive actions", isOn: $draft.confirmDestructiveActions)
                    Toggle("Show stopped containers", isOn: $draft.showStoppedContainers)
                }
                Section("Logs") {
                    Stepper(value: $draft.logTail, in: 50...5_000, step: 50) {
                        Text("Initial tail: \(draft.logTail) lines")
                    }
                    Stepper(value: $draft.logBufferLines, in: 1_000...100_000, step: 1_000) {
                        Text("Buffer: \(draft.logBufferLines) lines")
                    }
                }
                Section("Docker") {
                    HStack {
                        TextField("Docker executable", text: Binding(
                            get: { draft.dockerPath ?? "" },
                            set: { draft.dockerPath = $0.isEmpty ? nil : $0 }
                        ))
                        Button("Choose…") { chooseDocker() }
                    }
                    Picker("Context", selection: Binding(
                        get: { draft.contextName },
                        set: { draft.contextName = $0 }
                    )) {
                        Text("Current context").tag(String?.none)
                        ForEach(store.contexts) { context in
                            Text(context.name).tag(Optional(context.name))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Apply") {
                    store.settings = draft
                    store.saveSettings()
                    store.reconnect()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 540, height: 520)
        .onAppear { draft = store.settings }
    }

    private func chooseDocker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the docker executable"
        if panel.runModal() == .OK, let url = panel.url {
            draft.dockerPath = url.path
        }
    }
}
