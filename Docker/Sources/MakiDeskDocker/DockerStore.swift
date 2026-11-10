import AppKit
import Foundation
import MakiDockerCore
import MakiShared
import Observation

enum DockerSection: String, CaseIterable, Identifiable {
    case containers
    case images
    case volumes
    case networks
    case cleanup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .containers: return "Containers"
        case .images: return "Images"
        case .volumes: return "Volumes"
        case .networks: return "Networks"
        case .cleanup: return "Cleanup"
        }
    }

    var icon: String {
        switch self {
        case .containers: return "shippingbox"
        case .images: return "square.stack.3d.up"
        case .volumes: return "externaldrive"
        case .networks: return "network"
        case .cleanup: return "trash"
        }
    }
}

enum DockerConnectionState: Equatable {
    case locating
    case ready(version: String)
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var version: String? {
        if case let .ready(version) = self { return version }
        return nil
    }

    var failure: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}

enum DockerConfirm {
    @MainActor
    static func ask(title: String,
                    message: String,
                    confirm: String,
                    destructive: Bool = true) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = destructive ? .warning : .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: confirm)
        if #available(macOS 11.0, *) {
            alert.buttons.last?.hasDestructiveAction = destructive
        }
        return alert.runModal() == .alertSecondButtonReturn
    }
}

@MainActor
@Observable
final class DockerStore {
    // MARK: - State

    var section: DockerSection = .containers
    var containers: [DockerContainer] = []
    var groups: [DockerContainerGroup] = []
    var images: [DockerImage] = []
    var volumes: [DockerVolume] = []
    var networks: [DockerNetwork] = []
    var diskUsage: DockerDiskUsage = .empty
    var contexts: [DockerContext] = []
    var connection: DockerConnectionState = .locating
    var isRefreshing = false
    var isActionRunning = false
    var actionLabel = ""
    var lastError: String?
    var actionError: String?
    var actionMessage: String?
    var lastUpdated: Date?
    var search = ""
    var showStopped = true
    var autoRefresh = true {
        didSet { updateRefreshLoop() }
    }
    var selectedContainerID: String?
    var selectedImageID: String?
    var selectedVolumeID: String?
    var selectedNetworkID: String?
    var settings = DockerSettingsDocument.defaults
    var theme = DockerUITheme()
    var isSettingsPresented = false
    var dockerPath: URL?
    var currentContext: String?

    @ObservationIgnored private var cli: DockerCLI?
    @ObservationIgnored private var reader: DockerReader?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    private(set) var windowVisible = false
    @ObservationIgnored private var appActive = true
    @ObservationIgnored weak var server: DockerIPCServer?

    // MARK: - Lifecycle

    func start() {
        settings = DockerSettingsStore.load()
        showStopped = settings.showStoppedContainers
        theme = DockerUITheme(document: DockerThemeStore.load())
        Task { await connect() }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        updateRefreshLoop()
    }

    func setAppActive(_ active: Bool) {
        appActive = active
        updateRefreshLoop()
    }

    func reloadTheme() {
        theme = DockerUITheme(document: DockerThemeStore.load())
    }

    // MARK: - Connection

    private func connect() async {
        connection = .locating
        lastError = nil

        let executable: URL?
        if let path = settings.dockerPath,
           FileManager.default.isExecutableFile(atPath: path) {
            executable = URL(fileURLWithPath: path)
        } else {
            executable = await DockerExecutableLocator.locate()
        }

        guard let executable else {
            dockerPath = nil
            cli = nil
            reader = nil
            connection = .failed("The docker command was not found. Install Docker Desktop, OrbStack or colima, or choose the binary in Settings.")
            return
        }

        dockerPath = executable
        settings.dockerPath = executable.path
        let cli = DockerCLI(executableURL: executable, context: settings.contextName)
        self.cli = cli
        let reader = DockerReader(cli: cli)
        self.reader = reader

        do {
            contexts = try await reader.contexts()
        } catch {
            contexts = []
        }
        currentContext = settings.contextName
            ?? contexts.first(where: \.isCurrent)?.name

        do {
            let version = try await reader.daemonVersion()
            connection = .ready(version: version)
            updateRefreshLoop()
            await refreshAll()
        } catch {
            connection = .failed(error.localizedDescription)
            updateRefreshLoop()
        }
    }

    func reconnect() {
        Task { await connect() }
    }

    func selectContext(_ name: String?) {
        settings.contextName = name
        _ = DockerSettingsStore.save(settings)
        currentContext = name ?? contexts.first(where: \.isCurrent)?.name
        Task { await connect() }
    }

    func updateDockerPath(_ path: String?) {
        settings.dockerPath = path
        _ = DockerSettingsStore.save(settings)
        Task { await connect() }
    }

    func saveSettings() {
        settings = settings.normalized()
        showStopped = settings.showStoppedContainers
        _ = DockerSettingsStore.save(settings)
        updateRefreshLoop()
    }

    private func updateRefreshLoop() {
        let shouldRun = windowVisible && appActive && autoRefresh && connection.isReady
        guard shouldRun else {
            refreshTask?.cancel()
            refreshTask = nil
            return
        }
        guard refreshTask == nil else { return }
        let interval = max(2, settings.refreshInterval)
        refreshTask = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                guard let self else { return }
                await self.refreshAll()
            }
        }
    }

    // MARK: - Reading

    func refreshNow() {
        Task { await refreshAll() }
    }

    func refreshAll() async {
        guard let reader, isRefreshing == false else { return }
        generation += 1
        let currentGeneration = generation
        isRefreshing = true
        defer { isRefreshing = false }

        var firstError: String?

        do {
            let list = try await reader.containers()
            guard currentGeneration == generation else { return }
            containers = list
            groups = DockerGrouping.groups(list)
            reconcileContainerSelection()
        } catch {
            firstError = firstError ?? error.localizedDescription
        }

        if let firstError, containers.isEmpty, isConnectionFailure(firstError) {
            // One daemon failure would make the next four commands wait for
            // their own timeout. Stop here and show the actionable banner.
            lastError = firstError
            connection = .failed(firstError)
            updateRefreshLoop()
            return
        }

        if Task.isCancelled { return }
        do {
            let list = try await reader.images()
            guard currentGeneration == generation else { return }
            images = list
        } catch {
            firstError = firstError ?? error.localizedDescription
        }

        if Task.isCancelled { return }
        do {
            let list = try await reader.volumes()
            guard currentGeneration == generation else { return }
            volumes = list
        } catch {
            firstError = firstError ?? error.localizedDescription
        }

        if Task.isCancelled { return }
        do {
            let list = try await reader.networks()
            guard currentGeneration == generation else { return }
            networks = list
        } catch {
            firstError = firstError ?? error.localizedDescription
        }

        if Task.isCancelled { return }
        do {
            let disk = try await reader.diskUsage()
            guard currentGeneration == generation else { return }
            diskUsage = disk
            images = DockerJSON.mergingDiskUsage(images, with: disk)
            volumes = DockerJSON.mergingDiskUsage(volumes, with: disk)
        } catch {
            firstError = firstError ?? error.localizedDescription
        }

        guard currentGeneration == generation else { return }
        lastUpdated = Date()
        if let firstError {
            lastError = firstError
            if containers.isEmpty && images.isEmpty && volumes.isEmpty && networks.isEmpty {
                connection = .failed(firstError)
            }
        } else {
            lastError = nil
            if case let .ready(version) = connection {
                connection = .ready(version: version)
            } else {
                connection = .ready(version: "")
            }
        }
        reconcileImageSelection()
        reconcileVolumeSelection()
        reconcileNetworkSelection()
        updateRefreshLoop()
    }

    private func isConnectionFailure(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("cannot connect")
            || text.contains("failed to connect")
            || text.contains("is the docker daemon running")
            || text.contains("connection refused")
            || text.contains("dial unix")
            || text.contains("no such file or directory")
    }

    private func reconcileContainerSelection() {
        guard let selectedContainerID else { return }
        if containers.contains(where: { $0.id == selectedContainerID }) == false {
            self.selectedContainerID = nil
        }
    }

    private func reconcileImageSelection() {
        guard let selectedImageID else { return }
        if images.contains(where: { $0.id == selectedImageID }) == false {
            self.selectedImageID = nil
        }
    }

    private func reconcileVolumeSelection() {
        guard let selectedVolumeID else { return }
        if volumes.contains(where: { $0.id == selectedVolumeID }) == false {
            self.selectedVolumeID = nil
        }
    }

    private func reconcileNetworkSelection() {
        guard let selectedNetworkID else { return }
        if networks.contains(where: { $0.id == selectedNetworkID }) == false {
            self.selectedNetworkID = nil
        }
    }

    // MARK: - Filtering

    private var query: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var filteredGroups: [DockerContainerGroup] {
        groups.compactMap { group in
            let members = group.containers.filter { container in
                (showStopped || container.isRunning || container.isPaused)
                    && (query.isEmpty || container.matches.contains(query))
            }
            guard members.isEmpty == false else { return nil }
            return DockerContainerGroup(id: group.id,
                                        name: group.name,
                                        compose: group.compose,
                                        containers: members)
        }
    }

    var filteredImages: [DockerImage] {
        images.filter { image in
            query.isEmpty || image.matches.contains(query)
        }
    }

    var filteredVolumes: [DockerVolume] {
        volumes.filter { volume in
            query.isEmpty || volume.matches.contains(query)
        }
    }

    var filteredNetworks: [DockerNetwork] {
        networks.filter { network in
            query.isEmpty || network.matches.contains(query)
        }
    }

    var selectedContainer: DockerContainer? {
        guard let selectedContainerID else { return nil }
        return containers.first(where: { $0.id == selectedContainerID })
    }

    var selectedImage: DockerImage? {
        guard let selectedImageID else { return nil }
        return images.first(where: { $0.id == selectedImageID })
    }

    var selectedVolume: DockerVolume? {
        guard let selectedVolumeID else { return nil }
        return volumes.first(where: { $0.name == selectedVolumeID })
    }

    var selectedNetwork: DockerNetwork? {
        guard let selectedNetworkID else { return nil }
        return networks.first(where: { $0.id == selectedNetworkID })
    }

    var prunePlan: DockerPrunePlan {
        DockerPrunePlan(containers: containers, images: images,
                        volumes: volumes, networks: networks,
                        diskUsage: diskUsage)
    }

    // MARK: - Actions

    func perform(_ action: DockerContainerAction, on container: DockerContainer) {
        guard let reader, isActionRunning == false else { return }
        let name = container.name
        if action.isDestructive, settings.confirmDestructiveActions {
            let message = action == .remove
                ? "Delete \(name)? If it is running it will be stopped first. This cannot be undone."
                : "Kill \(name)? The process is terminated without a graceful shutdown."
            guard DockerConfirm.ask(title: "\(action.title) \(name)?",
                                    message: message,
                                    confirm: action.title) else { return }
        }
        isActionRunning = true
        actionLabel = "\(action.title) \(name)"
        actionMessage = nil
        actionError = nil

        Task {
            do {
                for arguments in action.arguments(containerID: container.id) {
                    _ = try await reader.cli.runChecked(arguments,
                                                        timeout: action == .remove ? 90 : 45)
                }
                actionMessage = "\(action.title) completed for \(name)"
            } catch {
                actionError = error.localizedDescription
            }
            isActionRunning = false
            await refreshAll()
        }
    }

    func performCompose(_ action: DockerComposeAction, on group: DockerContainerGroup) {
        guard let reader, let compose = group.compose, isActionRunning == false else { return }
        guard compose.canRunCompose else {
            actionError = "The Compose file or working directory is no longer available for \(group.name)."
            return
        }
        if action.isDestructive, settings.confirmDestructiveActions {
            let message = action == .downVolumes
                ? "Stop and remove \(group.name), its networks and the named volumes declared by Compose. This cannot be undone."
                : "Stop and remove the containers and networks of \(group.name). Volumes are kept."
            guard DockerConfirm.ask(title: "\(action.title)?",
                                    message: message,
                                    confirm: action.title) else { return }
        }
        isActionRunning = true
        actionLabel = "\(action.title) \(group.name)"
        actionMessage = nil
        actionError = nil

        Task {
            do {
                _ = try await reader.cli.runChecked(action.arguments(compose: compose),
                                                    timeout: 120)
                actionMessage = "\(action.title) completed for \(group.name)"
            } catch {
                actionError = error.localizedDescription
            }
            isActionRunning = false
            await refreshAll()
        }
    }

    func prune(_ mode: DockerPruneMode) {
        guard let reader, isActionRunning == false else { return }
        if settings.confirmDestructiveActions {
            guard DockerConfirm.ask(title: "\(mode.title)?",
                                    message: mode.explanation + "\n\nEstimated reclaimable space: \(prunePlan.estimatedSize(for: mode)).",
                                    confirm: mode.title) else { return }
            if mode == .all {
                guard DockerConfirm.ask(title: "Delete unused volumes too?",
                                        message: "Prune all removes every unused volume, including named volumes. Running containers and the images they use are kept. This cannot be undone.",
                                        confirm: "Delete volumes") else { return }
            }
        }
        isActionRunning = true
        actionLabel = mode.title
        actionMessage = nil
        actionError = nil

        Task {
            do {
                let result = try await reader.cli.run(mode.arguments, timeout: mode.timeout)
                if result.exitCode != 0 {
                    throw DockerCLIError.nonZero(result.exitCode, result.stderr)
                }
                actionMessage = result.stdout
                    .split(whereSeparator: { $0.isNewline })
                    .last(where: { $0.contains("reclaimed") })
                    .map(String.init)
                    ?? "\(mode.title) completed"
            } catch {
                actionError = error.localizedDescription
            }
            isActionRunning = false
            await refreshAll()
        }
    }

    func openTerminal(for container: DockerContainer) {
        guard let server, server.hasClient else {
            if DockerConfirm.ask(
                title: "MakiDesk is not running",
                message: "The container terminal is provided by MakiDesk. Open MakiDesk, then try again.",
                confirm: "Copy command",
                destructive: false
            ) {
                copyToPasteboard("docker exec -it \(container.id) \(settings.defaultShell)")
            }
            return
        }
        if server.sendOpenExec(containerID: container.id,
                               shell: settings.defaultShell,
                               title: "Docker: \(container.name)") == false {
            actionError = "Could not reach MakiDesk to open the terminal."
        }
    }

    func removeImage(_ image: DockerImage) {
        guard isActionRunning == false else { return }
        guard DockerConfirm.ask(
            title: "Remove \(image.primaryTag)?",
            message: "The image \(image.shortID) is removed. If a container still uses it, Docker will refuse.",
            confirm: "Remove image"
        ) else { return }
        runSimple(["image", "rm", image.id], label: "Remove \(image.primaryTag)")
    }

    func removeVolume(_ volume: DockerVolume) {
        guard isActionRunning == false else { return }
        guard volume.isUsed == false else {
            actionError = "This volume is used by a container and cannot be removed."
            return
        }
        guard DockerConfirm.ask(
            title: "Remove volume \(volume.name)?",
            message: "The volume and its data are removed. This cannot be undone.",
            confirm: "Remove volume"
        ) else { return }
        runSimple(["volume", "rm", volume.name], label: "Remove \(volume.name)")
    }

    func removeNetwork(_ network: DockerNetwork) {
        guard isActionRunning == false else { return }
        guard network.isUsed == false, network.isBuiltIn == false else {
            actionError = "This network is in use or is a built-in network."
            return
        }
        guard DockerConfirm.ask(
            title: "Remove network \(network.name)?",
            message: "The network is removed. This cannot be undone.",
            confirm: "Remove network"
        ) else { return }
        runSimple(["network", "rm", network.id], label: "Remove \(network.name)")
    }

    private func runSimple(_ arguments: [String], label: String) {
        guard let reader else { return }
        isActionRunning = true
        actionLabel = label
        actionMessage = nil
        actionError = nil
        Task {
            do {
                _ = try await reader.cli.runChecked(arguments, timeout: 60)
                actionMessage = "\(label) completed"
            } catch {
                actionError = error.localizedDescription
            }
            isActionRunning = false
            await refreshAll()
        }
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func inspect(_ container: DockerContainer) async -> DockerInspectSummary? {
        guard let reader else { return nil }
        do {
            return try await reader.inspect(id: container.id)
        } catch {
            actionError = error.localizedDescription
            return nil
        }
    }

    func stats(for container: DockerContainer) async -> DockerContainerStats? {
        guard let reader else { return nil }
        do {
            return try await reader.stats(id: container.id)
        } catch {
            return nil
        }
    }

    func logCommand(containerID: String, follow: Bool, timestamps: Bool) -> [String] {
        DockerCommands.logs(id: containerID, tail: settings.logTail,
                            follow: follow, timestamps: timestamps)
    }

    var executableURL: URL? { cli?.executableURL }
    var contextName: String? { settings.contextName }
    var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }
}
