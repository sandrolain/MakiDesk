import AppKit
import SwiftUI
import MakiDockerCore

struct DockerRootView: View {
    @Bindable var store: DockerStore

    var body: some View {
        NavigationSplitView {
            DockerSidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 245, max: 330)
        } content: {
            Group {
                switch store.section {
                case .containers:
                    DockerContainersView(store: store)
                case .images:
                    DockerImagesView(store: store)
                case .volumes:
                    DockerVolumesView(store: store)
                case .networks:
                    DockerNetworksView(store: store)
                case .cleanup:
                    DockerCleanupView(store: store)
                }
            }
            .navigationSplitViewColumnWidth(min: 380, ideal: 540, max: 760)
        } detail: {
            DockerDetailPane(store: store)
                .navigationSplitViewColumnWidth(min: 320, ideal: 430)
        }
        .navigationTitle("")
        .background(store.theme.background)
        .tint(store.theme.accent)
        .preferredColorScheme(store.theme.isDark ? .dark : .light)
        .font(.system(size: 13.5))
        .toolbar { toolbar }
        .sheet(isPresented: $store.isSettingsPresented) {
            DockerSettingsView(store: store)
        }
        .alert("Docker", isPresented: Binding(
            get: { store.actionError != nil },
            set: { if $0 == false { store.actionError = nil } }
        )) {
            Button("OK", role: .cancel) { store.actionError = nil }
        } message: {
            Text(store.actionError ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                store.refreshNow()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh now (⌘R)")

            Toggle(isOn: $store.autoRefresh) {
                Label("Auto refresh", systemImage: "arrow.triangle.2.circlepath")
            }
            .toggleStyle(.button)
            .help("Refresh while the window is visible")

            Menu {
                ForEach(store.contexts) { context in
                    Button {
                        store.selectContext(context.name)
                    } label: {
                        if context.name == store.currentContext {
                            Label(context.name, systemImage: "checkmark")
                        } else {
                            Text(context.name)
                        }
                    }
                }
                if store.contexts.isEmpty == false {
                    Divider()
                    Button("Use the current context") { store.selectContext(nil) }
                }
            } label: {
                Label(store.currentContext ?? "Context", systemImage: "server.rack")
            }
            .help("Docker context")

            Button {
                store.isSettingsPresented = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Docker settings")
        }
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 9) {
                if store.section != .cleanup {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(store.theme.subtext)
                            .accessibilityHidden(true)
                        TextField("Search \(store.section.title.lowercased())", text: $store.search)
                            .textFieldStyle(.plain)
                            .accessibilityLabel("Search \(store.section.title.lowercased())")
                            .help("Filter \(store.section.title.lowercased())")
                        if store.search.isEmpty == false {
                            Button { store.search = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(store.theme.subtext)
                            }
                            .buttonStyle(.plain)
                            .help("Clear search")
                            .accessibilityLabel("Clear search")
                        }
                    }
                    .padding(.horizontal, 9)
                    .frame(width: 220, height: 26)
                    .background(store.theme.surface,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(store.theme.border.opacity(0.7), lineWidth: 1)
                    }
                }

                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                        .accessibilityLabel("Refreshing Docker")
                }
            }
        }
    }
}

struct DockerSidebarView: View {
    @Bindable var store: DockerStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sidebarTitle("Docker")
                    ForEach(DockerSection.allCases) { section in
                        sectionRow(section)
                    }

                    sidebarTitle("Context")
                        .padding(.top, 12)
                    if store.contexts.isEmpty {
                        Text(store.currentContext ?? "No context")
                            .font(.callout)
                            .foregroundStyle(store.theme.subtext)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    } else {
                        ForEach(store.contexts) { context in
                            contextRow(context)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 14)
                .padding(.bottom, 10)
            }
            .scrollContentBackground(.hidden)

            Divider().overlay(store.theme.border.opacity(0.6))

            DockerConnectionFooter(store: store)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(store.theme.surface.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(store.theme.background)
        .tint(store.theme.accent)
    }

    private func sidebarTitle(_ title: String) -> some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(store.theme.subtext)
            .textCase(.uppercase)
            .padding(.horizontal, 10)
            .padding(.bottom, 3)
    }

    private func sectionRow(_ section: DockerSection) -> some View {
        DockerSidebarSectionRow(store: store, section: section,
                                count: count(for: section))
    }

    private func contextRow(_ context: DockerContext) -> some View {
        let selected = context.name == store.currentContext
        return Button {
            store.selectContext(context.name)
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(selected ? store.theme.accent : store.theme.border)
                    .frame(width: 6, height: 6)
                Text(context.name)
                    .font(.callout)
                    .foregroundStyle(selected ? store.theme.text : store.theme.text.opacity(0.85))
                    .lineLimit(1)
                Spacer()
                if context.isRemote {
                    Image(systemName: "network")
                        .font(.callout)
                        .foregroundStyle(store.theme.subtext)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                selected ? store.theme.surfaceSelected.opacity(0.4) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .help(context.endpoint)
    }

    private func count(for section: DockerSection) -> String {
        switch section {
        case .containers: return "\(store.containers.count)"
        case .images: return "\(store.images.count)"
        case .volumes: return "\(store.volumes.count)"
        case .networks: return "\(store.networks.count)"
        case .cleanup: return store.diskUsage.reclaimableBytes > 0
            ? DockerFormatting.size(store.diskUsage.reclaimableBytes) : "—"
        }
    }
}

private struct DockerSidebarSectionRow: View {
    @Bindable var store: DockerStore
    let section: DockerSection
    let count: String
    @State private var hovering = false

    var body: some View {
        let selected = store.section == section
        Button {
            store.section = section
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .frame(width: 18)
                    .foregroundStyle(selected ? store.theme.accent : store.theme.subtext)
                Text(section.title)
                    .foregroundStyle(selected ? store.theme.text : store.theme.text.opacity(0.9))
                Spacer(minLength: 6)
                Text(count)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(store.theme.subtext)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                selected ? store.theme.accent.opacity(0.16)
                    : hovering ? store.theme.surfaceSelected.opacity(0.45)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
        }
        .buttonStyle(.plain)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                hovering = true
            case .ended:
                hovering = false
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct DockerConnectionFooter: View {
    @Bindable var store: DockerStore

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(store.currentContext ?? "docker")
                    .font(.callout)
                    .foregroundStyle(store.theme.subtext)
                    .lineLimit(1)
            }
            Spacer()
        }
        .foregroundStyle(store.theme.text)
    }

    private var statusTitle: String {
        switch store.connection {
        case .locating: return "Looking for Docker…"
        case let .ready(version): return version.isEmpty ? "Connected" : "Engine \(version)"
        case .failed: return "Docker unavailable"
        }
    }

    private var statusColor: Color {
        switch store.connection {
        case .locating: return .orange
        case .ready: return .green
        case .failed: return .red
        }
    }
}

struct DockerContainersView: View {
    @Bindable var store: DockerStore
    @State private var sortOrder: DockerContainerSortOrder = .name
    @State private var selectedIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            DockerSectionHeader(
                title: "Containers",
                subtitle: "\(store.containers.filter(\.isRunning).count) running · \(store.containers.count) total",
                store: store
            )
            HStack {
                if selectedIDs.isEmpty == false {
                    Text("\(selectedIDs.count) selected")
                        .font(.callout)
                        .foregroundStyle(store.theme.subtext)
                    Button("Start") { store.performBulk(.start, ids: selectedIDs) }
                        .disabled(selectedContainers.contains(where: \.isStopped) == false)
                    Button("Stop") { store.performBulk(.stop, ids: selectedIDs) }
                        .disabled(selectedContainers.contains(where: { $0.isRunning || $0.isPaused }) == false)
                    Button("Delete", role: .destructive) {
                        store.performBulk(.remove, ids: selectedIDs)
                    }
                }
                Spacer()
                Menu {
                    Picker("Sort by", selection: $sortOrder) {
                        ForEach(DockerContainerSortOrder.allCases, id: \.self) { order in
                            Text(order.title).tag(order)
                        }
                    }
                } label: {
                    Label(sortOrder.title, systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .help("Sort containers within each group")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            Divider().overlay(store.theme.border)
            if store.connection.failure != nil, store.containers.isEmpty {
                DockerConnectionProblem(store: store)
            } else if composeGroups.isEmpty && standaloneContainers.isEmpty {
                DockerEmptyView(
                    icon: "shippingbox",
                    title: store.containers.isEmpty ? "No containers" : "No containers match",
                    detail: store.containers.isEmpty
                        ? "Start a container or a Compose project to see it here."
                        : "Change the search or show stopped containers."
                )
            } else {
                List(selection: $selectedIDs) {
                    if standaloneContainers.isEmpty == false {
                        ForEach(standaloneContainers) { container in
                            containerRow(container, indent: 0)
                        }
                    }
                    ForEach(composeGroups) { group in
                        Section {
                            let isSearching = store.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                            if store.isGroupCollapsed(group.id) == false || isSearching {
                                ForEach(sortedContainers(in: group)) { container in
                                    containerRow(container, indent: 18)
                                }
                            }
                        } header: {
                            DockerGroupHeader(store: store, group: group)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .onChange(of: selectedIDs) { _, ids in
                    if let current = store.selectedContainerID, ids.contains(current) == false {
                        store.selectedContainerID = ids.sorted().first
                    } else if store.selectedContainerID == nil {
                        store.selectedContainerID = ids.sorted().first
                    }
                }
                .onChange(of: store.containers.map(\.id)) { _, currentIDs in
                    selectedIDs.formIntersection(currentIDs)
                    if let current = store.selectedContainerID,
                       currentIDs.contains(current) == false {
                        store.selectedContainerID = selectedIDs.sorted().first
                    }
                }
            }
        }
        .background(store.theme.background)
    }

    private var composeGroups: [DockerContainerGroup] {
        store.filteredGroups.filter { $0.isStandalone == false }
    }

    private var standaloneContainers: [DockerContainer] {
        guard let group = store.filteredGroups.first(where: \.isStandalone) else { return [] }
        return sortedContainers(in: group)
    }

    private func sortedContainers(in group: DockerContainerGroup) -> [DockerContainer] {
        DockerContainerOrdering.sort(group.containers, by: sortOrder,
                                     stats: store.containerStats)
    }

    private var selectedContainers: [DockerContainer] {
        store.containers.filter { selectedIDs.contains($0.id) }
    }

    @ViewBuilder
    private func containerRow(_ container: DockerContainer, indent: CGFloat) -> some View {
        DockerContainerRow(store: store, container: container)
            .padding(.leading, indent)
            .tag(container.id)
            .contextMenu {
                containerMenu(store: store, container: container)
            }
    }

    @ViewBuilder
    private func containerMenu(store: DockerStore, container: DockerContainer) -> some View {
        if container.isPaused {
            Button("Resume") { store.perform(.unpause, on: container) }
            Button("Stop") { store.perform(.stop, on: container) }
            Button("Restart") { store.perform(.restart, on: container) }
        } else if container.isRunning {
            Button("Stop") { store.perform(.stop, on: container) }
            Button("Restart") { store.perform(.restart, on: container) }
            Button("Pause") { store.perform(.pause, on: container) }
        } else {
            Button("Start") { store.perform(.start, on: container) }
        }
        Button("Terminal") { store.openTerminal(for: container) }
            .disabled(container.isRunning == false)
        Divider()
        Button("Copy container ID") { store.copyToPasteboard(container.id) }
        Button("Copy name") { store.copyToPasteboard(container.name) }
        Button("Copy docker run command") { store.copyRunCommand(for: container) }
        Button("Copy file to container…") { store.copyFileToContainer(container) }
        Button("Copy file from container…") { store.copyFileFromContainer(container) }
        Divider()
        Button("Kill", role: .destructive) { store.perform(.kill, on: container) }
        Button("Delete", role: .destructive) { store.perform(.remove, on: container) }
    }
}

struct DockerSectionHeader: View {
    let title: String
    let subtitle: String
    @Bindable var store: DockerStore

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(store.theme.text)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(store.theme.subtext)
            }
            Spacer()
            if store.isActionRunning {
                ProgressView().controlSize(.small)
                Text(store.actionLabel)
                    .font(.callout)
                    .foregroundStyle(store.theme.subtext)
                    .lineLimit(1)
            }
            if let message = store.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    Button("Retry") { store.refreshNow() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .help(message)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(store.theme.surface.opacity(0.45))
    }
}

struct DockerContainerRow: View {
    @Bindable var store: DockerStore
    let container: DockerContainer

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(container.displayName)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(store.theme.text)
                        .lineLimit(1)
                    if container.compose?.oneOff == true {
                        DockerBadge(text: "one-off", tone: .neutral, theme: store.theme)
                    }
                    if container.health == .unhealthy {
                        DockerBadge(text: "unhealthy", tone: .warning, theme: store.theme)
                    } else if container.health == .healthy {
                        DockerBadge(text: "healthy", tone: .success, theme: store.theme)
                    }
                }
                Text(container.image)
                    .font(.callout)
                    .foregroundStyle(store.theme.subtext)
                    .lineLimit(1)
                let stats = store.stats(for: container)
                HStack(spacing: 10) {
                    metric("CPU", value: stats?.cpuPercent ?? "—",
                           icon: "cpu", color: .orange)
                    metric("MEM", value: stats?.memoryUsage ?? "—",
                           icon: "memorychip", color: .purple)
                }
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(container.state.label)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(statusColor)
                if container.displayPorts != "—" {
                    Text(container.displayPorts)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                }
            }
            Button {
                if container.isPaused {
                    store.perform(.unpause, on: container)
                } else {
                    store.perform(container.isRunning ? .stop : .start, on: container)
                }
            } label: {
                Image(systemName: container.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(container.isRunning ? Color.orange : Color.green)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(store.isActionRunning)
            .accessibilityLabel(container.isRunning ? "Stop \(container.name)" :
                                    (container.isPaused ? "Resume \(container.name)" :
                                        "Start \(container.name)"))
            .help(container.isRunning ? "Stop container" :
                    (container.isPaused ? "Resume container" : "Start container"))
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private var statusColor: Color {
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

    private func metric(_ title: String, value: String,
                        icon: String, color: Color) -> some View {
        Label("\(title) \(value)", systemImage: icon)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct DockerGroupHeader: View {
    @Bindable var store: DockerStore
    let group: DockerContainerGroup

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    store.toggleGroup(group.id)
                }
            } label: {
                Image(systemName: store.isGroupCollapsed(group.id)
                      ? "chevron.right" : "chevron.down")
                    .font(.callout.weight(.semibold))
                    .frame(width: 12, height: 14)
                    .foregroundStyle(store.theme.subtext)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.isGroupCollapsed(group.id)
                                ? "Expand \(group.name)" : "Collapse \(group.name)")
            Image(systemName: group.isStandalone ? "shippingbox" : "square.stack.3d.up")
                .font(.callout)
                .foregroundStyle(store.theme.subtext)
            Text(group.name)
                .font(.callout.weight(.semibold))
                .foregroundStyle(store.theme.text)
            Text("\(group.runningCount)/\(group.totalCount)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(store.theme.subtext)
            Spacer()
            if group.compose != nil {
                Menu {
                    Button("Start project") { store.performCompose(.start, on: group) }
                        .disabled(group.canRunCompose == false)
                    Button("Stop project") { store.performCompose(.stop, on: group) }
                        .disabled(store.isActionRunning)
                    Button("Restart project") { store.performCompose(.restart, on: group) }
                        .disabled(group.canRunCompose == false)
                    Divider()
                    Button("Delete project", role: .destructive) {
                        store.performCompose(.down, on: group)
                    }
                    .disabled(group.canRunCompose == false)
                    Button("Down and remove volumes", role: .destructive) {
                        store.performCompose(.downVolumes, on: group)
                    }
                    .disabled(group.canRunCompose == false)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.callout)
                        .foregroundStyle(store.theme.subtext)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 20)
                .help(group.canRunCompose
                      ? "Project actions"
                      : "Stop containers; other project actions need the Compose files")
            }
        }
        .textCase(nil)
        .padding(.vertical, 3)
    }
}

struct DockerConnectionProblem: View {
    @Bindable var store: DockerStore

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.orange)
            Text("Docker is not available")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(store.theme.text)
            Text(store.connection.failure ?? "The Docker daemon did not answer.")
                .font(.callout)
                .foregroundStyle(store.theme.subtext)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 420)
            HStack(spacing: 8) {
                Button("Retry") { store.reconnect() }
                    .buttonStyle(.borderedProminent)
                Button("Open Docker Desktop") { openDockerDesktop() }
                    .disabled(dockerDesktopInstalled == false)
                Button("Settings") { store.isSettingsPresented = true }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    private var dockerDesktopInstalled: Bool {
        ["com.docker.docker", "com.orbstack.OrbStack", "io.rancherdesktop.app"]
            .contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    private func openDockerDesktop() {
        let bundleIDs = ["com.docker.docker", "com.orbstack.OrbStack", "io.rancherdesktop.app"]
        for id in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url,
                                                    configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
    }
}

struct DockerEmptyView: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 18, weight: .semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

struct DockerBadge: View {
    let text: String
    let tone: Tone
    let theme: DockerUITheme

    enum Tone {
        case neutral, success, warning, danger
    }

    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return theme.subtext
        case .success: return .green
        case .warning: return .orange
        case .danger: return .red
        }
    }

    private var background: Color {
        foreground.opacity(0.12)
    }
}
