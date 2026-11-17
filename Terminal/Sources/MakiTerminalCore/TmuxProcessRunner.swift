import Foundation

public enum TmuxCommandFailure: Error, Equatable, Sendable {
    case executableUnavailable
    case timedOut
    case outputTooLarge
    case couldNotStart
    case outputReadFailed
    case commandFailed(exitCode: Int32, diagnostic: String?)
    case invalidOutput
    case tooManySessions

    public var userMessage: String {
        switch self {
        case .executableUnavailable:
            return "tmux is unavailable"
        case .timedOut:
            return "the tmux command timed out"
        case .outputTooLarge:
            return "tmux returned too much data"
        case .couldNotStart:
            return "the tmux command could not be started"
        case .outputReadFailed:
            return "tmux output could not be read"
        case let .commandFailed(exitCode, diagnostic):
            if TmuxProcessRunner.isNoServerDiagnostic(diagnostic) {
                return "no tmux server is running"
            }
            return "tmux exited with status \(exitCode)"
        case .invalidOutput:
            return "tmux returned invalid output"
        case .tooManySessions:
            return "too many tmux sessions to enumerate"
        }
    }
}

enum TmuxProcessRunner {
    private enum TerminationFailure {
        case timedOut
        case outputTooLarge
        case outputReadFailed
    }

    private final class ExecutionState {
        private let lock = NSLock()
        private var failure: TerminationFailure?

        func setFailure(_ failure: TerminationFailure) {
            lock.lock()
            if self.failure == nil { self.failure = failure }
            lock.unlock()
        }

        var currentFailure: TerminationFailure? {
            lock.lock()
            defer { lock.unlock() }
            return failure
        }
    }

    static func run(executable: URL,
                    arguments: [String],
                    timeout: TimeInterval,
                    maximumOutputBytes: Int) -> Result<Data, TmuxCommandFailure> {
        guard timeout.isFinite, timeout > 0, maximumOutputBytes >= 0 else {
            return .failure(.couldNotStart)
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        let state = ExecutionState()

        do {
            try process.run()
        } catch {
            return .failure(.couldNotStart)
        }

        let timeoutWork = DispatchWorkItem {
            guard process.isRunning else { return }
            state.setFailure(.timedOut)
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout,
                                                      execute: timeoutWork)

        var output = Data()
        do {
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 64 * 1024),
                  chunk.isEmpty == false {
                guard chunk.count <= maximumOutputBytes - output.count else {
                    state.setFailure(.outputTooLarge)
                    if process.isRunning { process.terminate() }
                    break
                }
                output.append(chunk)
            }
        } catch {
            state.setFailure(.outputReadFailed)
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            timeoutWork.cancel()
            switch state.currentFailure {
            case .timedOut:
                return .failure(.timedOut)
            case .outputTooLarge:
                return .failure(.outputTooLarge)
            case .outputReadFailed, nil:
                return .failure(.outputReadFailed)
            }
        }

        process.waitUntilExit()
        timeoutWork.cancel()

        switch state.currentFailure {
        case .timedOut:
            return .failure(.timedOut)
        case .outputTooLarge:
            return .failure(.outputTooLarge)
        case .outputReadFailed:
            return .failure(.outputReadFailed)
        case nil:
            guard process.terminationStatus == 0 else {
                let diagnostic = String(data: output, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(.commandFailed(exitCode: process.terminationStatus,
                                               diagnostic: diagnostic))
            }
            return .success(output)
        }
    }

    static func isNoServerDiagnostic(_ diagnostic: String?) -> Bool {
        diagnostic?.localizedCaseInsensitiveContains("no server running") == true
    }
}
