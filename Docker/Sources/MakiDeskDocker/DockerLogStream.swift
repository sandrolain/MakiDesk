import Darwin
import Foundation

/// A long-lived `docker logs` process. It reads both pipes, forwards decoded
/// chunks on the main queue and never touches AppKit from a pipe callback.
///
/// All mutable process state is touched only on `queue`; the callbacks are
/// captured by value per stream, so a restart cannot deliver the previous
/// stream's output to the new view model.
final class DockerLogStream: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.makidesk.docker.logs")
    private var process: Process?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?

    func start(executable: URL,
               context: String?,
               arguments: [String],
               onText: @escaping @MainActor @Sendable (String) -> Void,
               onEnd: @escaping @MainActor @Sendable (Int32?) -> Void) {
        stop()
        queue.async { [weak self] in
            guard let self else { return }
            let process = Process()
            process.executableURL = executable
            var args: [String] = []
            if let context, context.isEmpty == false {
                args.append(contentsOf: ["--context", context])
            }
            args.append(contentsOf: arguments)
            process.arguments = args
            var environment = ProcessInfo.processInfo.environment
            environment["DOCKER_CLI_HINTS"] = "false"
            process.environment = environment
            process.standardInput = FileHandle.nullDevice

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            self.stdoutHandle = outPipe.fileHandleForReading
            self.stderrHandle = errPipe.fileHandleForReading
            self.process = process

            let forward: @Sendable (FileHandle) -> Void = { handle in
                let data = handle.availableData
                guard data.isEmpty == false else {
                    handle.readabilityHandler = nil
                    return
                }
                let text = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async {
                    onText(text)
                }
            }
            outPipe.fileHandleForReading.readabilityHandler = forward
            errPipe.fileHandleForReading.readabilityHandler = forward

            process.terminationHandler = { finished in
                let code = finished.terminationStatus
                DispatchQueue.main.async {
                    onEnd(code)
                }
            }

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async {
                    onEnd(nil)
                }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stdoutHandle?.readabilityHandler = nil
            self.stderrHandle?.readabilityHandler = nil
            self.stdoutHandle = nil
            self.stderrHandle = nil
            if let process = self.process {
                if process.isRunning {
                    process.terminate()
                }
                let pid = process.processIdentifier
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
                    if process.isRunning {
                        kill(pid, SIGKILL)
                    }
                }
            }
            self.process = nil
        }
    }
}
