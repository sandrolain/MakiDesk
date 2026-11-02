import Darwin
import Foundation

/// The numbers behind the menu-bar disk line and the CPU watch.
///
/// Everything here is a value plus a read: no timers, no presentation, no
/// AppKit. `SystemMonitor` owns when these run; the tests exercise the rules
/// without a desktop. All reads happen on a worker queue, never on the main
/// actor, because both `statfs`/`URLResourceValues` and the process list are
/// cross-system calls even when they are quick.

// MARK: - Disk

/// One snapshot of the volume that holds a path (`/` by default).
struct DiskSpace: Equatable, Sendable {
    let volumeName: String
    let totalBytes: Int64
    /// Free blocks, without the space macOS may reclaim by purging caches and
    /// snapshots.
    let availableBytes: Int64
    /// What Finder and Storage settings call available: the figure above plus
    /// what the system can purge. Nil when the volume reports none.
    let availableForImportantUsageBytes: Int64?

    /// The figure shown to the user. Finder parity matters more than the
    /// strict block count: a user comparing the two must not see two numbers.
    var displayedAvailableBytes: Int64 {
        max(0, availableForImportantUsageBytes ?? availableBytes)
    }

    var strictlyAvailableBytes: Int64 { max(0, availableBytes) }
    var total: Int64 { max(0, totalBytes) }
    var freeFraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(displayedAvailableBytes) / Double(total)))
    }

    /// True when the purgeable allowance is large enough to be worth naming,
    /// so the menu does not repeat two figures that are nearly the same.
    var hasPurgeableSpace: Bool {
        guard let important = availableForImportantUsageBytes else { return false }
        return important > strictlyAvailableBytes + 1_000_000_000
    }

    /// Reads the volume at `path`. The resource values path is preferred: it
    /// gives the purgeable allowance the Finder uses. `statfs` is the fallback
    /// for a volume that does not answer, and returns the strict count only.
    static func read(atPath path: String = "/") -> DiskSpace? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        if let values = try? url.resourceValues(forKeys: keys),
           let total = values.volumeTotalCapacity, total > 0,
           let available = values.volumeAvailableCapacity {
            return DiskSpace(
                volumeName: values.volumeName ?? "Disk",
                totalBytes: Int64(total),
                availableBytes: Int64(available),
                availableForImportantUsageBytes: values.volumeAvailableCapacityForImportantUsage
            )
        }

        var stats = statfs()
        guard statfs(path, &stats) == 0 else { return nil }
        let block = Int64(stats.f_bsize)
        return DiskSpace(
            volumeName: "Disk",
            totalBytes: Int64(stats.f_blocks) * block,
            availableBytes: Int64(stats.f_bavail) * block,
            availableForImportantUsageBytes: nil
        )
    }
}

enum DiskMenuBarMode: String, CaseIterable, Identifiable, Sendable {
    case always
    case belowWarning
    case never

    var id: String { rawValue }

    var label: String {
        switch self {
        case .always: return "Always"
        case .belowWarning: return "Only below the warning level"
        case .never: return "Never"
        }
    }
}

enum DiskSpaceFormat: String, CaseIterable, Identifiable, Sendable {
    case size
    case percent

    var id: String { rawValue }

    var label: String {
        switch self {
        case .size: return "Size"
        case .percent: return "Percentage"
        }
    }
}

/// Decimal units, like the Finder: 1 GB is 1,000,000,000 bytes. Byte counts in
/// binary units would disagree with Storage settings and every screenshot of
/// the same disk.
enum DiskSpaceText {
    static func size(_ bytes: Int64, locale: Locale = .current) -> String {
        let value = Double(max(0, bytes))
        let (scaled, unit): (Double, String)
        if value >= 1_000_000_000_000 {
            (scaled, unit) = (value / 1_000_000_000_000, "TB")
        } else if value >= 1_000_000_000 {
            (scaled, unit) = (value / 1_000_000_000, "GB")
        } else {
            (scaled, unit) = (value / 1_000_000, "MB")
        }
        return "\(number(scaled, locale: locale)) \(unit)"
    }

    static func percent(_ fraction: Double, locale: Locale = .current) -> String {
        let value = min(1, max(0, fraction)) * 100
        return "\(number(value, locale: locale))%"
    }

    /// The short figure the menu bar has room for.
    static func menuBar(_ space: DiskSpace, format: DiskSpaceFormat,
                        locale: Locale = .current) -> String {
        switch format {
        case .size: return size(space.displayedAvailableBytes, locale: locale)
        case .percent: return percent(space.freeFraction, locale: locale)
        }
    }

    /// The line at the top of the menu and in the System submenu.
    static func summary(_ space: DiskSpace, locale: Locale = .current) -> String {
        let free = size(space.displayedAvailableBytes, locale: locale)
        let total = size(space.total, locale: locale)
        let share = percent(space.freeFraction, locale: locale)
        return "\(space.volumeName) · \(free) free of \(total) (\(share))"
    }

    /// The purgeable split, only when the difference is worth reading.
    static func detail(_ space: DiskSpace, locale: Locale = .current) -> String? {
        guard space.hasPurgeableSpace else { return nil }
        let important = size(space.displayedAvailableBytes, locale: locale)
        let strict = size(space.strictlyAvailableBytes, locale: locale)
        return "\(important) available to apps, purgeable included · \(strict) strictly free"
    }

    private static func number(_ value: Double, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = value >= 100 ? 0 : 1
        formatter.maximumFractionDigits = value >= 100 ? 0 : 1
        return formatter.string(from: NSNumber(value: value)) ?? "0"
    }
}

// MARK: - CPU

/// Cumulative CPU ticks for the whole machine. The difference between two
/// reads is the only honest measure of total load: `ps`-style percentages are
/// decayed averages and mix two meanings.
struct CPUTicks: Equatable, Sendable {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64

    var busy: UInt64 { user &+ system &+ nice }
    var total: UInt64 { busy &+ idle }

    /// Busy share between two reads, 0…100 for the whole machine.
    func busyPercent(since previous: CPUTicks) -> Double? {
        guard total > previous.total, busy >= previous.busy else { return nil }
        let totalDelta = total - previous.total
        guard totalDelta > 0 else { return nil }
        let busyDelta = busy - previous.busy
        return min(100, max(0, Double(busyDelta) / Double(totalDelta) * 100))
    }
}

enum SystemLoadSampler {
    static func ticks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }
}

/// A process as the sampler sees it: enough to tell whether this is the same
/// process across two reads, and enough to name it without its arguments.
struct ProcessIdentity: Hashable, Sendable {
    let pid: Int32
    /// Process start time; PID reuse after a crash or a relaunch gives a new
    /// identity instead of carrying the old one's high-CPU history.
    let startSeconds: Int64
}

struct ProcessSnapshot: Equatable, Sendable {
    let identity: ProcessIdentity
    let name: String
    let path: String?
    /// Cumulative user + system time, in seconds.
    let cpuSeconds: Double
}

/// One process's share between two snapshots, in percent of **one core**
/// (100% is a fully busy core; a six-thread build can read 600%).
struct ProcessReading: Identifiable, Equatable, Sendable {
    let identity: ProcessIdentity
    let name: String
    let cpuPercent: Double

    var id: ProcessIdentity { identity }

    var percentText: String { CPUFormat.percent(cpuPercent) }
}

enum ProcessSampler {
    /// Every process this user may inspect. Root-owned processes answer
    /// `EPERM` to `proc_pid_rusage`; the monitor reports their aggregate load
    /// instead of inventing a name. The scan is ~0.2 ms for a few hundred
    /// processes, which is why it can run every 15 seconds on a worker.
    static func snapshots() -> [ProcessSnapshot] {
        let pids = allPIDs()
        guard pids.isEmpty == false else { return [] }

        var snapshots: [ProcessSnapshot] = []
        snapshots.reserveCapacity(pids.count)
        for pid in pids where pid > 0 {
            guard let cpuSeconds = cpuSeconds(pid: pid) else { continue }
            let start = startSeconds(pid: pid)
            let path = executablePath(pid: pid)
            let name = displayName(pid: pid, path: path)
            snapshots.append(ProcessSnapshot(
                identity: ProcessIdentity(pid: pid, startSeconds: start),
                name: name,
                path: path,
                cpuSeconds: cpuSeconds
            ))
        }
        return snapshots
    }

    private static func allPIDs() -> [pid_t] {
        let stride = MemoryLayout<pid_t>.stride
        var capacity = 2048
        while capacity <= 65_536 {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let written = buffer.withUnsafeMutableBufferPointer { pointer in
                proc_listpids(UInt32(PROC_ALL_PIDS), 0, pointer.baseAddress,
                              Int32(pointer.count * stride))
            }
            guard written > 0 else { return [] }
            // libproc reports the buffer size in bytes, not the entry count.
            let count = min(Int(written) / stride, buffer.count)
            if count < buffer.count {
                buffer.removeLast(buffer.count - count)
                return buffer
            }
            capacity *= 2
        }
        return []
    }

    private static func cpuSeconds(pid: pid_t) -> Double? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return nil }
        return (Double(info.ri_user_time) + Double(info.ri_system_time)) / 1_000_000_000
    }

    private static func startSeconds(pid: pid_t) -> Int64 {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        guard result == size else { return 0 }
        return Int64(info.pbi_start_tvsec)
    }

    private static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = buffer.withUnsafeMutableBytes { raw in
            proc_pidpath(pid, raw.baseAddress, UInt32(raw.count))
        }
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func displayName(pid: pid_t, path: String?) -> String {
        if let path, path.isEmpty == false {
            let name = URL(fileURLWithPath: path).lastPathComponent
            if name.isEmpty == false { return name }
        }
        var buffer = [CChar](repeating: 0, count: 256)
        let length = buffer.withUnsafeMutableBytes { raw in
            proc_name(pid, raw.baseAddress, UInt32(raw.count))
        }
        if length > 0 { return String(cString: buffer) }
        return "pid \(pid)"
    }
}

enum CPUFormat {
    static func percent(_ value: Double) -> String {
        "\(Int(max(0, value).rounded()))%"
    }

    static func cores(_ value: Double) -> String {
        let cores = max(0, value) / 100
        let number = String(format: "%.1f", cores)
        return cores == 1 ? "\(number) core" : "\(number) cores"
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        let whole = Int((max(0, seconds) / 60).rounded(.down))
        return whole <= 0 ? "under a minute" : "\(whole) min"
    }
}
