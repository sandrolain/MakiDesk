import Foundation
import MakiTerminalCore

enum GitStatusReader {
    private static let maximumOutputBytes = 4 * 1024 * 1024
    private static let commandTimeout: TimeInterval = 5

    static func read(directory: String) -> (root: String, files: [GitChangedFile])? {
        guard let rootData = runGit(directory: directory, arguments: ["rev-parse", "--show-toplevel"]),
              let root = String(data: rootData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              root.isEmpty == false,
              let status = runGit(directory: root, arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=all"]) else { return nil }
        return (root, GitChangedFilesParser.parse(status))
    }

    private static func runGit(directory: String, arguments: [String]) -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + commandTimeout,
                                                          execute: timeout)
            var data = Data()
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 64 * 1024),
                  chunk.isEmpty == false {
                data.append(chunk)
                if data.count > maximumOutputBytes {
                    if process.isRunning { process.terminate() }
                    timeout.cancel()
                    process.waitUntilExit()
                    return nil
                }
            }
            timeout.cancel()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch { return nil }
    }
}
