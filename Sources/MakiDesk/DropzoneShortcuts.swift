import Foundation

/// One entry of `shortcuts list --show-identifiers`.
///
/// The editor only needs the list to prefill a command and to warn about a
/// shortcut that disappeared; the dropzone itself stores the UUID in its
/// command line and never depends on this type.
struct DropzoneShortcut: Identifiable, Equatable, Sendable {
    /// The shortcut UUID, as printed by the CLI.
    let id: String
    let name: String
}

/// Reads and parses the Shortcuts catalog (T44).
///
/// This is deliberately a small, separate helper: the dropzone command is
/// `shortcuts run <UUID>` (or any other CLI), and Shortcuts is only a source of
/// prefilled commands. Nothing here runs a shortcut or needs Accessibility.
enum DropzoneShortcutCatalog {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let executable = URL(fileURLWithPath: "/usr/bin/shortcuts")
    static let defaultTimeout: TimeInterval = 5

    /// Parses the command's output. Malformed lines are skipped instead of
    /// failing the whole list: a new macOS version must not empty the picker.
    static func parse(_ output: String) -> [DropzoneShortcut] {
        var seen = Set<String>()
        var entries: [DropzoneShortcut] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasSuffix(")"),
                  let separator = line.range(of: " (", options: .backwards) else { continue }
            let identifier = String(line[separator.upperBound..<line.index(before: line.endIndex)])
            guard identifier.count == 36, UUID(uuidString: identifier) != nil else { continue }
            let name = String(line[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard name.isEmpty == false, seen.insert(identifier).inserted else { continue }
            entries.append(DropzoneShortcut(id: identifier, name: name))
        }
        return entries.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Runs `shortcuts list` off the main thread with a watchdog. A missing
    /// command or a failure is returned as a message the editor can show.
    static func load(timeout: TimeInterval = defaultTimeout) async -> Result<[DropzoneShortcut], Failure> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: run(timeout: timeout))
            }
        }
    }

    private static func run(timeout: TimeInterval) -> Result<[DropzoneShortcut], Failure> {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return .failure(Failure(message: "The shortcuts command is not available on this Mac."))
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["list", "--show-identifiers"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return .failure(Failure(message: "Could not run shortcuts: \(error.localizedDescription)"))
        }

        // The list is normally ~60 ms. The watchdog only releases a stuck
        // process; it is not a polling loop.
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        if process.terminationReason == .uncaughtSignal {
            return .failure(Failure(message: "The shortcuts command did not answer in time."))
        }
        guard process.terminationStatus == 0 else {
            let message = String(data: errors, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .failure(Failure(message: message.isEmpty
                ? "shortcuts list failed (exit \(process.terminationStatus))."
                : "shortcuts list failed: \(message)"))
        }
        return .success(parse(String(data: output, encoding: .utf8) ?? ""))
    }

    /// The prefill appended to `shortcuts run <UUID>` for what the zone accepts.
    /// `{paths}` is a whole token: with several items it becomes several
    /// arguments, which `shortcuts run` accepts after one `--input-path`.
    static func inputFlag(for accepts: DropzoneAccept) -> String? {
        if accepts.kinds.contains(.files) || accepts.kinds.contains(.images) {
            return "--input-path {paths}"
        }
        if accepts.kinds.contains(.text) {
            return "--input-path {textfile}"
        }
        if accepts.kinds.contains(.urls) {
            return "--input-path {urlsfile}"
        }
        return nil
    }
}
