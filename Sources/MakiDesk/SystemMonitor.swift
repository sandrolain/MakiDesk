import AppKit
import Foundation
import Observation

/// The owner of the menu-bar disk figure and the sustained-CPU watch.
///
/// It is deliberately separate from `WorkspaceStore`: these values change on
/// their own clock, are read by a menu-bar label and a menu that must not be
/// rebuilt under the pointer, and have nothing to do with window inventory. All
/// reads run on one utility queue; only the resulting values reach the main
/// actor. Nothing polls while the watch is off, and the wake path resets the
/// baselines so a slept-through gap is never reported as sustained load.
@Observable
@MainActor
final class SystemMonitor {
    static let shared = SystemMonitor()

    // MARK: - Preferences

    private(set) var diskMenuBarMode: DiskMenuBarMode
    private(set) var diskFormat: DiskSpaceFormat
    private(set) var diskWarningThresholdGB: Double
    private(set) var cpuAlertsEnabled: Bool
    private(set) var cpuThresholdPercent: Double
    private(set) var cpuSustainedMinutes: Double
    private(set) var systemNotificationsEnabled: Bool

    // MARK: - Published readings

    private(set) var diskSpace: DiskSpace?
    /// The short string beside the icon, `nil` when the user hid it.
    private(set) var menuBarDiskText: String?
    /// Whole-machine busy share, 0…100.
    private(set) var cpuPercent: Double?
    /// The busiest readable processes at the last sample, for the System menu.
    private(set) var topProcesses: [ProcessReading] = []

    // MARK: - Workers and state that is not for the view

    @ObservationIgnored private let queue = DispatchQueue(
        label: "com.makidesk.app.system-monitor", qos: .utility
    )
    @ObservationIgnored private var diskTimer: DispatchSourceTimer?
    @ObservationIgnored private var cpuTimer: DispatchSourceTimer?
    @ObservationIgnored private var started = false
    /// Changes when the monitor starts or resumes; a late read from before a
    /// sleep cannot publish into the new session.
    @ObservationIgnored private var lifecycle = 0
    /// Changes whenever the CPU timer is replaced or turned off.
    @ObservationIgnored private var cpuGeneration = 0
    @ObservationIgnored private var previousCPU: (
        instant: TimeInterval,
        ticks: CPUTicks,
        processes: [ProcessIdentity: Double]
    )?
    @ObservationIgnored private var policy: SystemAlertPolicy
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var menuTracking = false
    @ObservationIgnored private var heldDisk: DiskSpace?
    @ObservationIgnored private var heldCPU: CPUPublish?
    @ObservationIgnored private var lastDiskWarningAt: TimeInterval

    private struct CPUPublish {
        let percent: Double?
        let top: [ProcessReading]
    }

    private init() {
        let defaults = UserDefaults.standard
        diskMenuBarMode = Settings.value(.systemDiskMenuBarMode, as: DiskMenuBarMode.self,
                                         in: defaults) ?? .always
        diskFormat = Settings.value(.systemDiskFormat, as: DiskSpaceFormat.self,
                                    in: defaults) ?? .size
        diskWarningThresholdGB = Settings.double(.systemDiskWarningThresholdGB, in: defaults)
        cpuAlertsEnabled = Settings.bool(.systemCPUAlertsEnabled, in: defaults)
        let threshold = Settings.double(.systemCPUThresholdPercent, in: defaults)
        let thresholdValue = threshold > 0 ? threshold : 100
        cpuThresholdPercent = thresholdValue
        let minutes = Settings.double(.systemCPUSustainedMinutes, in: defaults)
        let minutesValue = minutes > 0 ? minutes : 10
        cpuSustainedMinutes = minutesValue
        systemNotificationsEnabled = Settings.bool(.systemCPUNotifySystem, in: defaults)
        lastDiskWarningAt = Settings.double(.systemDiskWarningDate, in: defaults)

        var configuration = SystemAlertPolicyConfiguration()
        configuration.processThresholdPercent = thresholdValue
        configuration.sustainedSeconds = minutesValue * 60
        policy = SystemAlertPolicy(configuration: configuration)

        installObservers()
    }

    // MARK: - Lifecycle

    func start() {
        guard started == false else { return }
        started = true
        lifecycle &+= 1
        restartDiskTimer()
        restartCPUTimer()
        refreshDiskNow()
    }

    /// Re-reads the start-up disk now; used at launch, after a mount and from
    /// the System menu.
    func refreshDiskNow() {
        guard started else { return }
        let generation = lifecycle
        queue.async { [weak self] in
            let space = DiskSpace.read()
            Task { @MainActor [weak self] in
                guard let self, self.lifecycle == generation, let space else { return }
                self.publishDisk(space)
            }
        }
    }

    // MARK: - Preferences, written once and applied at once

    func updateDiskMenuBarMode(_ value: DiskMenuBarMode) {
        guard value != diskMenuBarMode else { return }
        diskMenuBarMode = value
        Settings.set(value.rawValue, for: .systemDiskMenuBarMode)
        refreshMenuBarText()
    }

    func updateDiskFormat(_ value: DiskSpaceFormat) {
        guard value != diskFormat else { return }
        diskFormat = value
        Settings.set(value.rawValue, for: .systemDiskFormat)
        refreshMenuBarText()
    }

    func updateDiskWarningThresholdGB(_ value: Double) {
        let clamped = min(max(value, 0), 1000)
        guard clamped != diskWarningThresholdGB else { return }
        diskWarningThresholdGB = clamped
        Settings.set(clamped, for: .systemDiskWarningThresholdGB)
        refreshMenuBarText()
    }

    func updateCPUAlertsEnabled(_ value: Bool) {
        guard value != cpuAlertsEnabled else { return }
        cpuAlertsEnabled = value
        Settings.set(value, for: .systemCPUAlertsEnabled)
        restartCPUTimer()
    }

    func updateCPUThresholdPercent(_ value: Double) {
        let clamped = min(max(value, 50), 800)
        guard clamped != cpuThresholdPercent else { return }
        cpuThresholdPercent = clamped
        Settings.set(clamped, for: .systemCPUThresholdPercent)
        applyPolicyConfiguration()
        // A new threshold changes what "already above" means; keeping the old
        // episode would let a looser rule fire on the next sample.
        policy.reset()
    }

    func updateCPUSustainedMinutes(_ value: Double) {
        let clamped = min(max(value, 1), 120)
        guard clamped != cpuSustainedMinutes else { return }
        cpuSustainedMinutes = clamped
        Settings.set(clamped, for: .systemCPUSustainedMinutes)
        applyPolicyConfiguration()
        policy.reset()
    }

    /// Requests Notification Center permission only when the option is turned
    /// on; an old default can never prompt at launch.
    func updateSystemNotifications(_ enabled: Bool) {
        guard enabled else {
            systemNotificationsEnabled = false
            Settings.set(false, for: .systemCPUNotifySystem)
            return
        }
        guard SystemNotifier.isAvailable else {
            systemNotificationsEnabled = false
            Settings.set(false, for: .systemCPUNotifySystem)
            HUDController.shared.show(HUDMessage.systemNotificationsUnavailable)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let granted = await SystemNotifier.shared.requestAuthorization()
            guard granted else {
                self.systemNotificationsEnabled = false
                Settings.set(false, for: .systemCPUNotifySystem)
                HUDController.shared.show(
                    HUDMessage.systemNotificationsDenied,
                    actions: [HUDAction(title: "Notification Settings") {
                        [weak self] in self?.openNotificationSettings()
                    }]
                )
                return
            }
            self.systemNotificationsEnabled = true
            Settings.set(true, for: .systemCPUNotifySystem)
        }
    }

    private func applyPolicyConfiguration() {
        policy.configuration.processThresholdPercent = cpuThresholdPercent
        policy.configuration.sustainedSeconds = cpuSustainedMinutes * 60
    }

    /// Puts the menu-bar figure and the CPU watch back to their defaults (the
    /// factory reset). The date of the last disk warning goes too: a reset is a
    /// fresh start, and the next low reading may speak once.
    func resetToDefaults() {
        updateDiskMenuBarMode(.always)
        updateDiskFormat(.size)
        updateDiskWarningThresholdGB(10)
        updateCPUThresholdPercent(100)
        updateCPUSustainedMinutes(10)
        updateSystemNotifications(false)
        updateCPUAlertsEnabled(true)
        lastDiskWarningAt = 0
        Settings.set(0, for: .systemDiskWarningDate)
        policy.reset()
    }

    // MARK: - Presented values

    var isDiskLow: Bool {
        guard let diskSpace else { return false }
        return isLow(diskSpace)
    }

    var diskMenuLine: String {
        guard let diskSpace else { return "Disk · reading…" }
        return DiskSpaceText.summary(diskSpace)
    }

    var diskDetailLine: String? {
        diskSpace.flatMap { DiskSpaceText.detail($0) }
    }

    var cpuMenuLine: String {
        guard cpuAlertsEnabled else { return "CPU alerts are off" }
        guard let cpuPercent else { return "CPU · reading…" }
        if let top = topProcesses.first, top.cpuPercent >= 20 {
            return "CPU \(CPUFormat.percent(cpuPercent)) · \(top.name) \(top.percentText)"
        }
        return "CPU \(CPUFormat.percent(cpuPercent))"
    }

    var menuBarAccessibilityLabel: String {
        guard let menuBarDiskText else { return "MakiDesk" }
        return "MakiDesk, \(menuBarDiskText) free on the start-up disk"
    }

    private func isLow(_ space: DiskSpace) -> Bool {
        let threshold = Int64(max(0, diskWarningThresholdGB) * 1_000_000_000)
        return threshold > 0 && space.displayedAvailableBytes < threshold
    }

    private func refreshMenuBarText() {
        guard let diskSpace else {
            if menuBarDiskText != nil { menuBarDiskText = nil }
            return
        }
        let text: String?
        switch diskMenuBarMode {
        case .always:
            text = DiskSpaceText.menuBar(diskSpace, format: diskFormat)
        case .belowWarning:
            text = isLow(diskSpace) ? DiskSpaceText.menuBar(diskSpace, format: diskFormat) : nil
        case .never:
            text = nil
        }
        if text != menuBarDiskText { menuBarDiskText = text }
    }

    // MARK: - Disk sampling

    private func restartDiskTimer() {
        diskTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let generation = lifecycle
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(60),
                       leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            let space = DiskSpace.read()
            Task { @MainActor [weak self] in
                guard let self, self.lifecycle == generation, let space else { return }
                self.publishDisk(space)
            }
        }
        timer.resume()
        diskTimer = timer
    }

    private func publishDisk(_ space: DiskSpace) {
        if menuTracking {
            heldDisk = space
        } else {
            applyDisk(space)
        }
        checkDiskWarning(space)
    }

    private func applyDisk(_ space: DiskSpace) {
        diskSpace = space
        refreshMenuBarText()
    }

    /// One warning a day, not one every minute. The date survives a relaunch
    /// so reopening the app is not a way to be told the same thing again.
    private func checkDiskWarning(_ space: DiskSpace) {
        guard isLow(space) else { return }
        if lastDiskWarningAt > 0 {
            let last = Date(timeIntervalSince1970: lastDiskWarningAt)
            if Calendar.current.isDateInToday(last) { return }
        }
        lastDiskWarningAt = Date().timeIntervalSince1970
        Settings.set(lastDiskWarningAt, for: .systemDiskWarningDate)
        let message = HUDMessage.diskSpaceLow(
            free: DiskSpaceText.size(space.displayedAvailableBytes),
            total: DiskSpaceText.size(space.total),
            percent: DiskSpaceText.percent(space.freeFraction)
        )
        HUDController.shared.show(message, actions: [
            HUDAction(title: "Storage Settings") { [weak self] in
                self?.openStorageSettings()
            },
        ])
    }

    // MARK: - CPU sampling

    private func restartCPUTimer() {
        cpuTimer?.cancel()
        cpuTimer = nil
        cpuGeneration &+= 1
        previousCPU = nil
        guard started, cpuAlertsEnabled else {
            cpuPercent = nil
            topProcesses = []
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let lifecycle = lifecycle
        let generation = cpuGeneration
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(15),
                       leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            let ticks = SystemLoadSampler.ticks()
            let snapshots = ProcessSampler.snapshots()
            Task { @MainActor [weak self] in
                guard let self,
                      self.lifecycle == lifecycle,
                      self.cpuGeneration == generation
                else { return }
                self.receive(ticks: ticks, snapshots: snapshots)
            }
        }
        timer.resume()
        cpuTimer = timer
    }

    private func receive(ticks: CPUTicks?, snapshots: [ProcessSnapshot]) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let ticks else { return }
        let baseline = (
            instant: now,
            ticks: ticks,
            processes: Dictionary(
                snapshots.map { ($0.identity, $0.cpuSeconds) },
                uniquingKeysWith: { first, _ in first }
            )
        )
        guard let previous = previousCPU else {
            previousCPU = baseline
            return
        }
        previousCPU = baseline

        let elapsed = now - previous.instant
        guard elapsed > 0.5 else { return }
        let load = ticks.busyPercent(since: previous.ticks)

        let readings = snapshots.compactMap { snapshot -> ProcessReading? in
            guard let before = previous.processes[snapshot.identity] else { return nil }
            let delta = snapshot.cpuSeconds - before
            guard delta >= 0 else { return nil }
            return ProcessReading(identity: snapshot.identity,
                                  name: snapshot.name,
                                  cpuPercent: delta / elapsed * 100)
        }.sorted { $0.cpuPercent > $1.cpuPercent }

        publishCPU(percent: load, top: Array(readings.prefix(5)))
        guard let load else { return }
        let events = policy.ingest(
            now: now,
            readings: readings,
            systemPercent: load,
            coreCount: ProcessInfo.processInfo.activeProcessorCount
        )
        for event in events { present(event) }
    }

    private func publishCPU(percent: Double?, top: [ProcessReading]) {
        if menuTracking {
            heldCPU = CPUPublish(percent: percent, top: top)
        } else {
            cpuPercent = percent
            topProcesses = top
        }
    }

    // MARK: - Alerts

    private func present(_ alert: SystemAlert) {
        let percent = CPUFormat.percent(alert.cpuPercent)
        let sustained = CPUFormat.minutes(alert.sustainedSeconds)
        // The alerted process is in the title; "Also busy" names the others.
        let others = alert.identity.map { identity in
            alert.top.filter { $0.identity != identity }
        } ?? alert.top
        let message: HUDMessage
        var actions: [HUDAction] = [
            HUDAction(title: "Activity Monitor") { [weak self] in
                self?.openActivityMonitor()
            },
        ]
        switch alert.kind {
        case .process:
            message = HUDMessage.processHighCPU(
                name: alert.name,
                percent: percent,
                cores: CPUFormat.cores(alert.cpuPercent),
                sustained: sustained,
                top: others
            )
            actions.append(HUDAction(title: "Snooze 1 hour") { [weak self] in
                guard let self, let identity = alert.identity else { return }
                self.snooze(identity: identity, name: alert.name)
            })
        case .system:
            message = HUDMessage.systemHighCPU(
                percent: percent, sustained: sustained, top: others
            )
        }
        HUDController.shared.show(message, actions: actions)
        if systemNotificationsEnabled {
            SystemNotifier.shared.post(title: message.title,
                                       body: message.detail ?? message.title)
        }
    }

    private func snooze(identity: ProcessIdentity, name: String) {
        policy.snooze(identity, for: 3600, now: ProcessInfo.processInfo.systemUptime)
        HUDController.shared.show(HUDMessage.cpuAlertSnoozed(name: name))
    }

    // MARK: - Opening the right place

    func openActivityMonitor() {
        let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.ActivityMonitor"
        ) ?? URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.open(url)
    }

    func openStorageSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.Storage",
            "x-apple.systempreferences:com.apple.preference.storage",
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Observers

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTracking = true }
        })
        observers.append(center.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.menuTracking = false
                self?.flushHeld()
            }
        })

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        })
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDiskNow() }
            })
        }
    }

    /// A slept-through interval is not evidence of sustained load: forget the
    /// baselines and start again rather than blame the first process sampled.
    private func handleWake() {
        guard started else { return }
        lifecycle &+= 1
        previousCPU = nil
        policy.reset()
        heldDisk = nil
        heldCPU = nil
        restartDiskTimer()
        restartCPUTimer()
        refreshDiskNow()
    }

    private func flushHeld() {
        if let heldDisk {
            applyDisk(heldDisk)
            self.heldDisk = nil
        }
        if let heldCPU {
            cpuPercent = heldCPU.percent
            topProcesses = heldCPU.top
            self.heldCPU = nil
        }
    }

    deinit {
        diskTimer?.cancel()
        cpuTimer?.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
