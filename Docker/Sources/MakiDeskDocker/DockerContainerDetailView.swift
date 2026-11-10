import SwiftUI
import MakiDockerCore

struct DockerContainerDetailView: View {
    @Bindable var store: DockerStore
    let container: DockerContainer

    @State private var tab: Tab = .overview
    @State private var logs = DockerLogsModel()
    @State private var stats = DockerStatsModel()
    @State private var inspect = DockerInspectModel()

    enum Tab: String, CaseIterable, Identifiable {
        case overview, logs, stats, inspect
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: return "Overview"
            case .logs: return "Logs"
            case .stats: return "Stats"
            case .inspect: return "Inspect"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(store.theme.border)
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider().overlay(store.theme.border)
            switch tab {
            case .overview:
                overview
            case .logs:
                DockerLogsTabView(store: store, container: container, logs: logs)
            case .stats:
                DockerStatsTabView(store: store, container: container, stats: stats)
            case .inspect:
                DockerInspectTabView(store: store, container: container, model: inspect)
            }
        }
        .background(store.theme.background)
        .onChange(of: container.id) { _, _ in
            logs.stop()
            stats.stop()
            inspect.clear()
            tab = .overview
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 9, height: 9)
                Text(container.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(store.theme.text)
                    .lineLimit(1)
                if container.health == .unhealthy {
                    DockerBadge(text: "unhealthy", tone: .warning, theme: store.theme)
                } else if container.health == .healthy {
                    DockerBadge(text: "healthy", tone: .success, theme: store.theme)
                }
                Spacer()
                if store.isActionRunning {
                    ProgressView().controlSize(.small)
                }
            }
            HStack(spacing: 6) {
                Text(container.image)
                    .font(.caption)
                    .foregroundStyle(store.theme.subtext)
                    .lineLimit(1)
                if let project = container.compose?.project {
                    Text("·").foregroundStyle(store.theme.subtext)
                    Text(project)
                        .font(.caption)
                        .foregroundStyle(store.theme.subtext)
                }
            }
            HStack(spacing: 8) {
                if container.isPaused {
                    Button("Resume") { store.perform(.unpause, on: container) }
                    Button("Stop") { store.perform(.stop, on: container) }
                } else if container.isRunning {
                    Button("Stop") { store.perform(.stop, on: container) }
                    Button("Restart") { store.perform(.restart, on: container) }
                } else {
                    Button("Start") { store.perform(.start, on: container) }
                        .buttonStyle(.borderedProminent)
                }
                Button("Terminal") { store.openTerminal(for: container) }
                    .disabled(container.isRunning == false)
                Menu {
                    if container.isPaused {
                        Button("Resume") { store.perform(.unpause, on: container) }
                    } else if container.isRunning {
                        Button("Pause") { store.perform(.pause, on: container) }
                    }
                    Button("Copy container ID") { store.copyToPasteboard(container.id) }
                    Button("Copy name") { store.copyToPasteboard(container.name) }
                    Divider()
                    Button("Kill", role: .destructive) { store.perform(.kill, on: container) }
                    Button("Delete", role: .destructive) { store.perform(.remove, on: container) }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(14)
        .background(store.theme.surface.opacity(0.45))
    }

    private var stateColor: Color {
        switch container.state {
        case .running: return .green
        case .paused: return .orange
        case .restarting: return .blue
        case .exited, .dead: return .secondary
        case .created: return .teal
        case .removing: return .orange
        case .unknown: return .secondary
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DockerKeyValue(items: [
                    ("State", container.state.label),
                    ("Status", container.status),
                    ("Container ID", container.id),
                    ("Image", container.image),
                    ("Created", container.createdAt),
                    ("Uptime", container.runningFor),
                    ("Ports", container.displayPorts),
                    ("Networks", container.networks.isEmpty ? "—" : container.networks.joined(separator: ", ")),
                    ("Mounts", container.mounts.isEmpty ? "—" : container.mounts),
                    ("Compose project", container.compose?.project ?? "—"),
                    ("Compose service", container.compose?.service ?? "—"),
                    ("Compose file", container.compose?.configFiles.joined(separator: "\n") ?? "—"),
                ], store: store)

                HStack {
                    Button("Copy ID") { store.copyToPasteboard(container.id) }
                    if let url = container.ports.compactMap(\.openURL).first {
                        Link("Open \(url.absoluteString)", destination: url)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(16)
        }
    }
}

struct DockerLogsTabView: View {
    @Bindable var store: DockerStore
    let container: DockerContainer
    @Bindable var logs: DockerLogsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Toggle("Follow", isOn: Binding(
                    get: { logs.following },
                    set: { logs.setFollowing($0) }
                ))
                .toggleStyle(.checkbox)
                Toggle("Timestamps", isOn: Binding(
                    get: { logs.timestamps },
                    set: { logs.setTimestamps($0) }
                ))
                .toggleStyle(.checkbox)
                TextField("Filter lines", text: $logs.query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Spacer()
                if logs.isActive { ProgressView().controlSize(.small) }
                Text("\(logs.lineCount) lines")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(store.theme.subtext)
                if logs.dropped > 0 {
                    Text("· \(logs.dropped) trimmed")
                        .font(.caption)
                        .foregroundStyle(store.theme.subtext)
                }
                Button("Clear") { logs.clear() }
                Button("Restart") { logs.restart() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider().overlay(store.theme.border)

            DockerTextView(text: logs.filteredText,
                           theme: store.theme,
                           followsOutput: logs.following && logs.isFollowingOutput)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(store.theme.border)
            HStack {
                Text(logs.status)
                    .font(.caption)
                    .foregroundStyle(store.theme.subtext)
                Spacer()
                Button("Copy logs") { store.copyToPasteboard(logs.filteredText) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .task(id: "\(container.id)|\(store.executableURL?.path ?? "")") {
            guard let executable = store.executableURL else {
                logs.status = "Docker is not available."
                return
            }
            logs.start(containerID: container.id,
                       executable: executable,
                       context: store.contextName,
                       tail: store.settings.logTail,
                       maxLines: store.settings.logBufferLines,
                       following: logs.following,
                       timestamps: logs.timestamps)
        }
        .onChange(of: store.windowVisible) { _, visible in
            if visible {
                if logs.isActive == false { logs.restart() }
            } else {
                logs.stop()
            }
        }
        .onDisappear { logs.stop() }
    }
}

struct DockerStatsTabView: View {
    @Bindable var store: DockerStore
    let container: DockerContainer
    @Bindable var stats: DockerStatsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error = stats.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                          spacing: 12) {
                    DockerStatCard(title: "CPU", value: stats.stats.cpuPercent)
                    DockerStatCard(title: "Memory", value: stats.stats.memoryUsage)
                    DockerStatCard(title: "Memory %", value: stats.stats.memoryPercent)
                    DockerStatCard(title: "Network I/O", value: stats.stats.networkIO)
                    DockerStatCard(title: "Block I/O", value: stats.stats.blockIO)
                    DockerStatCard(title: "PIDs", value: stats.stats.pids)
                }
                if stats.isRunning {
                    Text("Updates every \(Int(store.settings.statsInterval)) seconds while this tab is visible.")
                        .font(.caption)
                        .foregroundStyle(store.theme.subtext)
                }
            }
            .padding(16)
        }
        .task(id: container.id) {
            stats.start(container: container, store: store,
                        interval: store.settings.statsInterval)
        }
        .onChange(of: store.windowVisible) { _, visible in
            if visible {
                stats.start(container: container, store: store,
                            interval: store.settings.statsInterval)
            } else {
                stats.stop()
            }
        }
        .onDisappear { stats.stop() }
    }
}

struct DockerStatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct DockerInspectTabView: View {
    @Bindable var store: DockerStore
    let container: DockerContainer
    @Bindable var model: DockerInspectModel
    @State private var revealEnvironment = false

    var body: some View {
        VStack(spacing: 0) {
            if model.isLoading {
                ProgressView("Reading inspect…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let summary = model.summary {
                VStack(alignment: .leading, spacing: 8) {
                    if let error = model.error {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                    if summary.environment.isEmpty == false {
                        DisclosureGroup(isExpanded: $revealEnvironment) {
                            Text(revealEnvironment
                                 ? summary.environment.joined(separator: "\n")
                                 : "Environment values are hidden because they can contain secrets.")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .foregroundStyle(revealEnvironment ? store.theme.text : store.theme.subtext)
                        } label: {
                            Text("Environment (\(summary.environment.count))")
                                .font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                    }
                    if summary.labels.isEmpty == false {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(summary.labels.sorted(by: { $0.key < $1.key }), id: \.key) { pair in
                                    Text("\(pair.key)=\(pair.value)")
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                }
                            }
                        } label: {
                            Text("Labels (\(summary.labels.count))")
                                .font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 14)
                    }
                    HStack {
                        Text("Raw JSON")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Button("Copy JSON") { store.copyToPasteboard(summary.rawJSON) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    Text("Environment values are redacted in this JSON. Reveal them above when needed.")
                        .font(.caption2)
                        .foregroundStyle(store.theme.subtext)
                        .padding(.horizontal, 14)
                    DockerTextView(text: summary.rawJSON, theme: store.theme)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No inspect data")
                        .font(.headline)
                    Text(model.error ?? "Select the container again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: container.id) { model.load(container: container, store: store) }
        .onDisappear { model.clear() }
    }
}
