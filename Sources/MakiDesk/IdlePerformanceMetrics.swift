import AppKit
import Darwin
import os

/// Low-frequency process CPU sampling for diagnosing sustained idle usage.
@MainActor
final class IdlePerformanceMetrics {
    static let shared = IdlePerformanceMetrics()

    private let logger = Logger(subsystem: "com.makidesk.app", category: "Idle Performance")
    private var timer: Timer?
    private var previousSample: (instant: ContinuousClock.Instant, processCPU: Double, mainThreadCPU: Double)?
    private var diagnosticSamplesRemaining = 0
    private var sampleInterval: TimeInterval = 60

    private init() {}

    func start() {
        guard timer == nil else { return }
        if UserDefaults.standard.bool(forKey: "IdlePerformanceDiagnostics") {
            // One-shot opt-in: sample every 5 seconds for ten minutes, then
            // return to the normal low-frequency sampler automatically.
            UserDefaults.standard.set(false, forKey: "IdlePerformanceDiagnostics")
            sampleInterval = 5
            diagnosticSamplesRemaining = 120
            logger.notice("Detailed idle CPU diagnostics enabled for 10 minutes")
        }
        previousSample = currentSample()
        scheduleTimer()
    }

    private func scheduleTimer() {
        // The timer is scheduled on the main run loop, so its block always runs
        // on the main actor; assumeIsolated states that instead of hopping.
        timer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportSample() }
        }
    }

    private func reportSample() {
        guard let previous = previousSample,
              let current = currentSample() else { return }
        previousSample = current

        let elapsedNanoseconds = Double(previous.instant.duration(to: current.instant).components.seconds) * 1e9
            + Double(previous.instant.duration(to: current.instant).components.attoseconds) / 1e9
        guard elapsedNanoseconds > 0 else { return }

        let processPercent = max(0, current.processCPU - previous.processCPU) / elapsedNanoseconds * 100
        let mainThreadPercent = max(0, current.mainThreadCPU - previous.mainThreadCPU) / elapsedNanoseconds * 100
        let elapsedSeconds = Int(elapsedNanoseconds / 1e9)
        logger.info("Idle CPU sample (\(elapsedSeconds)s): process_pct=\(processPercent, privacy: .public), main_thread_pct=\(mainThreadPercent, privacy: .public)")
        guard diagnosticSamplesRemaining > 0 else { return }
        diagnosticSamplesRemaining -= 1
        if diagnosticSamplesRemaining == 0 {
            timer?.invalidate()
            sampleInterval = 60
            scheduleTimer()
            logger.notice("Detailed idle CPU diagnostics finished")
        }
    }

    private func currentSample() -> (instant: ContinuousClock.Instant, processCPU: Double, mainThreadCPU: Double)? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        var threadTime = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &threadTime) == 0 else { return nil }

        let userNanoseconds = Double(usage.ru_utime.tv_sec) * 1e9 + Double(usage.ru_utime.tv_usec) * 1e3
        let systemNanoseconds = Double(usage.ru_stime.tv_sec) * 1e9 + Double(usage.ru_stime.tv_usec) * 1e3
        let mainThreadNanoseconds = Double(threadTime.tv_sec) * 1e9 + Double(threadTime.tv_nsec)
        return (.now, userNanoseconds + systemNanoseconds, mainThreadNanoseconds)
    }
}
