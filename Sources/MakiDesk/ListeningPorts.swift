import Darwin
import Foundation
import Observation

/// One TCP socket in `LISTEN`, with the process that holds it (U4).
struct ListeningPort: Identifiable, Equatable, Sendable {
    let port: Int
    let pid: Int32
    let processName: String
    /// The addresses lsof reported for this process and port, deduplicated:
    /// `*`, `127.0.0.1`, `[::1]`, …
    let addresses: [String]

    var id: String { "\(pid)-\(port)" }
    /// What the list and the confirmation call it.
    var name: String { processName.isEmpty ? "pid \(pid)" : processName }

    /// The filter: port, process name, pid or address. Empty matches all.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.isEmpty == false else { return true }
        return String(port).contains(needle)
            || String(pid).contains(needle)
            || processName.localizedCaseInsensitiveContains(needle)
            || addresses.contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}

/// Reads the `lsof -Fpcn` records. Pure, so the shapes that matter — IPv4,
/// IPv6 wildcard, several addresses for one process, malformed lines — are
/// tests instead of a manual inspection of the output.
enum ListeningPortsParser {
    static func parse(_ output: String) -> [ListeningPort] {
        var currentPID: Int32?
        var currentName = ""
        var found: [String: ListeningPort] = [:]

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard let marker = line.first else { continue }
            let value = String(line.dropFirst())
            switch marker {
            case "p":
                currentPID = Int32(value)
            case "c":
                currentName = value
            case "n":
                guard let pid = currentPID, let (port, address) = split(value) else { continue }
                let key = "\(pid)-\(port)"
                if var existing = found[key] {
                    if existing.addresses.contains(address) == false {
                        existing = ListeningPort(port: existing.port, pid: existing.pid,
                                                 processName: existing.processName,
                                                 addresses: existing.addresses + [address])
                    }
                    found[key] = existing
                } else {
                    found[key] = ListeningPort(port: port, pid: pid,
                                               processName: currentName, addresses: [address])
                }
            default:
                break
            }
        }

        return found.values.sorted { lhs, rhs in
            if lhs.port != rhs.port { return lhs.port < rhs.port }
            let names = lhs.name.localizedStandardCompare(rhs.name)
            if names != .orderedSame { return names == .orderedAscending }
            return lhs.pid < rhs.pid
        }
    }

    /// `127.0.0.1:3000`, `*:8080`, `[::1]:3000` → port and host. The last colon
    /// separates the port even for IPv6, whose address keeps its brackets.
    static func split(_ address: String) -> (port: Int, host: String)? {
        guard let colon = address.lastIndex(of: ":") else { return nil }
        guard let port = Int(address[address.index(after: colon)...]),
              (1...65535).contains(port) else { return nil }
        let host = String(address[..<colon])
        return (port, host.isEmpty ? "*" : host)
    }
}

/// Why the reader could not answer.
enum ListeningPortsFailure: Error, Equatable, Sendable {
    case lsofUnavailable
    case timedOut
    case launchFailed(String)

    var message: String {
        switch self {
        case .lsofUnavailable:
            return "lsof is not available on this Mac."
        case .timedOut:
            return "lsof did not answer in time."
        case let .launchFailed(reason):
            return "Could not run lsof: \(reason)"
        }
    }
}

/// The `lsof` call, injectable so the model can be tested without a process.
struct ListeningPortsReader: Sendable {
    let load: @Sendable () -> Result<[ListeningPort], ListeningPortsFailure>

    init(load: @escaping @Sendable () -> Result<[ListeningPort], ListeningPortsFailure>) {
        self.load = load
    }

    /// Fixed argv, no shell, stderr discarded, a three-second ceiling. lsof
    /// needs no root for the sockets of the current user; a process it cannot
    /// inspect is simply absent, which is the honest result.
    static let live = ListeningPortsReader {
        let executable = "/usr/sbin/lsof"
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return .failure(.lsofUnavailable)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }
        let collected = ListeningPortsOutput()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global(qos: .utility).async {
            collected.store(output.fileHandleForReading.readDataToEndOfFile())
            reading.leave()
        }
        if finished.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            reading.wait()
            return .failure(.timedOut)
        }
        reading.wait()
        let data = collected.data
        return .success(ListeningPortsParser.parse(String(decoding: data, as: UTF8.self)))
    }
}

/// The stdout collector for the reader: the pipe is drained on its own queue so
/// a long list cannot fill the pipe buffer and stop lsof from exiting.
private final class ListeningPortsOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    func store(_ data: Data) {
        lock.lock()
        value = data
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// The list shown by the Ports window: read when opened, never polled.
@Observable
@MainActor
final class ListeningPortsModel {
    private(set) var ports: [ListeningPort] = []
    private(set) var isLoading = false
    private(set) var failure: ListeningPortsFailure?

    @ObservationIgnored private let reader: ListeningPortsReader
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var refreshCompletion: (@MainActor @Sendable () -> Void)?

    init(reader: ListeningPortsReader = .live) {
        self.reader = reader
    }

    func refresh(completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard isLoading == false else {
            completion?()
            return
        }
        isLoading = true
        refreshCompletion = completion
        generation &+= 1
        let generation = generation
        let reader = reader
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { reader.load() }.value
            guard let self, self.generation == generation else { return }
            self.isLoading = false
            switch result {
            case let .success(ports):
                self.ports = ports
                self.failure = nil
            case let .failure(failure):
                // Keep what was on screen: a transient lsof failure is not a
                // reason to claim there are no ports.
                self.failure = failure
            }
            let completion = self.refreshCompletion
            self.refreshCompletion = nil
            completion?()
        }
    }
}
