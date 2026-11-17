import Foundation

public enum GitStatusReadFailure: Equatable, Sendable {
    case directoryUnavailable
    case commandFailed
    case outputTooLarge
    case couldNotStart
}

public enum GitStatusReadResult: Equatable, Sendable {
    case notRepository
    case success(root: String, files: [GitChangedFile])
    case failure(GitStatusReadFailure)
}

public enum GitStatusReader {
    private static let defaultMaximumOutputBytes = 4 * 1024 * 1024
    private static let defaultCommandTimeout: TimeInterval = 5

    private enum CommandResult {
        case success(Data)
        case commandFailed
        case outputTooLarge
        case couldNotStart
    }

    public static func read(directory: String) -> GitStatusReadResult {
        read(directory: directory,
             gitExecutable: URL(fileURLWithPath: "/usr/bin/git"),
             commandTimeout: defaultCommandTimeout,
             maximumOutputBytes: defaultMaximumOutputBytes)
    }

    static func read(directory: String,
                     gitExecutable: URL,
                     commandTimeout: TimeInterval,
                     maximumOutputBytes: Int,
                     fileManager: FileManager = .default) -> GitStatusReadResult {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failure(.directoryUnavailable)
        }

        let rootResult = runGit(directory: directory,
                                arguments: ["rev-parse", "--show-toplevel"],
                                executable: gitExecutable,
                                commandTimeout: commandTimeout,
                                maximumOutputBytes: maximumOutputBytes)
        let rootData: Data
        switch rootResult {
        case let .success(data):
            rootData = data
        case .commandFailed:
            return hasRepositoryMetadata(in: directory, fileManager: fileManager)
                ? .failure(.commandFailed)
                : .notRepository
        case .outputTooLarge:
            return .failure(.outputTooLarge)
        case .couldNotStart:
            return .failure(.couldNotStart)
        }

        guard let root = String(data: rootData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              root.isEmpty == false else {
            return .failure(.commandFailed)
        }

        switch runGit(directory: root,
                      arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
                      executable: gitExecutable,
                      commandTimeout: commandTimeout,
                      maximumOutputBytes: maximumOutputBytes) {
        case let .success(data):
            return .success(root: root, files: GitChangedFilesParser.parse(data))
        case .commandFailed:
            return .failure(.commandFailed)
        case .outputTooLarge:
            return .failure(.outputTooLarge)
        case .couldNotStart:
            return .failure(.couldNotStart)
        }
    }

    private static func runGit(directory: String,
                               arguments: [String],
                               executable: URL,
                               commandTimeout: TimeInterval,
                               maximumOutputBytes: Int) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = ["-C", directory] + arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let timeout = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + commandTimeout,
                                                          execute: timeout)
            var data = Data()
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 64 * 1024),
                  chunk.isEmpty == false {
                data.append(chunk)
                if data.count > maximumOutputBytes {
                    timeout.cancel()
                    if process.isRunning { process.terminate() }
                    process.waitUntilExit()
                    return .outputTooLarge
                }
            }
            timeout.cancel()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? .success(data) : .commandFailed
        } catch {
            return .couldNotStart
        }
    }

    private static func hasRepositoryMetadata(in directory: String,
                                              fileManager: FileManager) -> Bool {
        var candidate = URL(fileURLWithPath: directory).standardizedFileURL
        while true {
            if fileManager.fileExists(atPath: candidate.appendingPathComponent(".git").path) {
                return true
            }
            let bareRepositoryMarkers = ["HEAD", "config", "objects", "refs"]
            if bareRepositoryMarkers.allSatisfy({
                fileManager.fileExists(atPath: candidate.appendingPathComponent($0).path)
            }) {
                return true
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return false }
            candidate = parent
        }
    }
}
