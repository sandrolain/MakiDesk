import Foundation
import MakiDockerCore
import Observation

struct DockerStatsSample: Identifiable {
    let date: Date
    let cpuPercent: Double
    let memoryPercent: Double

    var id: Date { date }
}

@MainActor
@Observable
final class DockerLogsModel {
    var buffer = DockerLogBuffer()
    var query = ""
    var following = true
    var timestamps = false
    var status = "Select Logs to start the stream."
    var isActive = false
    var isFollowingOutput = true

    @ObservationIgnored private var stream: DockerLogStream?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var containerID: String?
    @ObservationIgnored private var executable: URL?
    @ObservationIgnored private var context: String?
    @ObservationIgnored private var tail = 500
    @ObservationIgnored private var maxLines = 20_000

    var filteredText: String { buffer.filtered(by: query) }
    var lineCount: Int { buffer.lines.count }
    var dropped: Int { buffer.dropped }

    func start(containerID: String,
               executable: URL,
               context: String?,
               tail: Int,
               maxLines: Int,
               following: Bool,
               timestamps: Bool) {
        stop()
        generation += 1
        let token = generation
        self.containerID = containerID
        self.executable = executable
        self.context = context
        self.tail = tail
        self.maxLines = maxLines
        self.following = following
        self.timestamps = timestamps
        buffer = DockerLogBuffer(maxLines: maxLines, maxBytes: 8 * 1024 * 1024)
        isActive = true
        isFollowingOutput = true
        status = following ? "Following…" : "Reading…"

        let stream = DockerLogStream()
        self.stream = stream
        stream.start(
            executable: executable,
            context: context,
            arguments: DockerCommands.logs(id: containerID, tail: tail,
                                           follow: following, timestamps: timestamps),
            onText: { [weak self] text in
                guard let self, token == self.generation else { return }
                var copy = self.buffer
                _ = copy.append(text)
                self.buffer = copy
            },
            onEnd: { [weak self] code in
                guard let self, token == self.generation else { return }
                self.isActive = false
                if let code, code != 0 {
                    self.status = "Stream ended (exit \(code))."
                } else {
                    self.status = following ? "Stream ended. The container may have stopped."
                                            : "Log snapshot loaded."
                }
            }
        )
    }

    func stop() {
        generation += 1
        stream?.stop()
        stream = nil
        isActive = false
        status = "Paused."
    }

    func restart() {
        guard let containerID, let executable else { return }
        start(containerID: containerID, executable: executable, context: context,
              tail: tail, maxLines: maxLines, following: following,
              timestamps: timestamps)
    }

    func setFollowing(_ value: Bool) {
        guard value != following else { return }
        following = value
        if isActive { restart() }
    }

    func setTimestamps(_ value: Bool) {
        guard value != timestamps else { return }
        timestamps = value
        if isActive { restart() }
    }

    func clear() {
        var copy = buffer
        copy.clear()
        buffer = copy
    }
}

@MainActor
@Observable
final class DockerStatsModel {
    var stats = DockerContainerStats.empty
    var history: [DockerStatsSample] = []
    var isRunning = false
    var error: String?
    var lastUpdated: Date?
    var isStale: Bool { error != nil && lastUpdated != nil }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var containerID: String?

    func start(container: DockerContainer, store: DockerStore, interval: Double) {
        stop()
        if containerID != container.id {
            stats = .empty
            lastUpdated = nil
            containerID = container.id
        }
        guard container.state == .running else {
            error = "No statistics while the container is stopped."
            return
        }
        isRunning = true
        error = nil
        history = []
        task = Task { [weak self] in
            while Task.isCancelled == false {
                guard let self else { return }
                if let value = await store.stats(for: container) {
                    self.stats = value
                    self.error = nil
                    self.lastUpdated = Date()
                    let cpu = Self.percentage(value.cpuPercent)
                    let memory = Self.percentage(value.memoryPercent)
                    if let cpu, let memory {
                        self.history.append(DockerStatsSample(date: Date(),
                                                              cpuPercent: cpu,
                                                              memoryPercent: memory))
                        if self.history.count > 60 {
                            self.history.removeFirst(self.history.count - 60)
                        }
                    }
                } else {
                    self.error = "Docker did not return statistics."
                }
                let nanos = UInt64(max(1, interval) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    private static func percentage(_ value: String) -> Double? {
        Double(value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: ""))
    }
}

@MainActor
@Observable
final class DockerProcessesModel {
    var processes: [DockerProcess] = []
    var isRunning = false
    var isLoading = false
    var error: String?
    var lastUpdated: Date?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var currentContainer: DockerContainer?
    @ObservationIgnored private weak var currentStore: DockerStore?

    func start(container: DockerContainer, store: DockerStore, interval: Double = 5) {
        stop()
        guard container.state == .running else {
            error = "Processes are available only while the container is running."
            return
        }
        generation += 1
        let token = generation
        currentContainer = container
        currentStore = store
        isRunning = true
        error = nil
        task = Task { [weak self] in
            guard let self else { return }
            while Task.isCancelled == false, token == self.generation {
                await self.load(container: container, store: store, token: token)
                try? await Task.sleep(nanoseconds: UInt64(max(3, interval) * 1_000_000_000))
            }
            if token == self.generation { self.isRunning = false }
        }
    }

    func refreshNow() {
        guard isRunning, let currentContainer, let currentStore else { return }
        guard isLoading == false else {
            refreshPending = true
            return
        }
        let token = generation
        Task { await load(container: currentContainer, store: currentStore, token: token) }
    }

    func stop() {
        generation += 1
        task?.cancel()
        task = nil
        refreshPending = false
        isRunning = false
        isLoading = false
        currentContainer = nil
        currentStore = nil
        processes = []
        error = nil
        lastUpdated = nil
    }

    private func load(container: DockerContainer, store: DockerStore, token: Int) async {
        guard token == generation else { return }
        guard isLoading == false else {
            refreshPending = true
            return
        }
        isLoading = true
        let value = await store.processes(for: container)
        guard token == generation, Task.isCancelled == false else { return }
        if let value {
            processes = value
            error = nil
            lastUpdated = Date()
        } else {
            error = "Could not read the process list."
        }
        isLoading = false
        if refreshPending {
            refreshPending = false
            await load(container: container, store: store, token: token)
        }
    }
}

@MainActor
@Observable
final class DockerInspectModel {
    var summary: DockerInspectSummary?
    var isLoading = false
    var error: String?

    @ObservationIgnored private var generation = 0

    func load(container: DockerContainer, store: DockerStore) {
        generation += 1
        let token = generation
        summary = nil
        isLoading = true
        error = nil
        Task { [weak self] in
            guard let self else { return }
            let value = await store.inspect(container)
            guard token == self.generation else { return }
            self.summary = value
            if value == nil { self.error = "Could not read the container details." }
            self.isLoading = false
        }
    }

    func clear() {
        generation += 1
        summary = nil
        error = nil
        isLoading = false
    }
}
