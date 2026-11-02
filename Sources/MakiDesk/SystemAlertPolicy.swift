import Foundation

/// The rule that turns two CPU samples into one notice (or none).
///
/// The point is not "this process is busy": a browser tab, a build or a video
/// call is busy on purpose. The rule is "the same process has been over the
/// threshold for long enough that it is worth the user's attention", with
/// hysteresis for a single quiet sample and a cooldown so an episode produces
/// one notice, not one per sample. Pure state and pure arithmetic: it can be
/// tested at any speed without touching a real process.
struct SystemAlertPolicyConfiguration: Equatable, Sendable {
    /// Percent of one core. 100 means one fully busy core.
    var processThresholdPercent: Double = 100
    /// Percent of the whole machine, from the CPU ticks.
    var systemThresholdPercent: Double = 80
    var sustainedSeconds: TimeInterval = 600
    /// How long one process (or the system) stays quiet after a notice.
    var cooldownSeconds: TimeInterval = 1800
    /// The minimum number of consecutive samples above the threshold. The
    /// duration check comes first; this keeps a policy with a very short
    /// duration from firing on the second sample after launch.
    var minimumSamplesAbove: Int = 3
    /// A single dip below the threshold does not restart the episode.
    var samplesBelowToReset: Int = 2
    /// A different hot process waits this long before its own notice, so five
    /// busy processes do not become five notices in five samples.
    var minimumSecondsBetweenAlerts: TimeInterval = 300
    /// The sum of the readable processes, in machine percent, must be below
    /// this share of the total before the notice blames "system processes".
    var systemExplanationRatio: Double = 0.5
    /// A vanished process is forgotten after this long.
    var purgeSeconds: TimeInterval = 3600
}

struct SystemAlert: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case process(ProcessIdentity)
        case system
    }

    let kind: Kind
    /// The process name, or "System processes".
    let name: String
    /// Percent of one core (process) or of the whole machine (system).
    let cpuPercent: Double
    let sustainedSeconds: TimeInterval
    let top: [ProcessReading]

    var identity: ProcessIdentity? {
        if case .process(let identity) = kind { return identity }
        return nil
    }
}

struct SystemAlertPolicy {
    var configuration: SystemAlertPolicyConfiguration

    private struct Track: Equatable {
        var name: String
        var aboveSince: TimeInterval?
        var aboveCount = 0
        var belowCount = 0
        var lastEmitted: TimeInterval?
        var snoozedUntil: TimeInterval?
        var lastSeen: TimeInterval
        var peakPercent: Double = 0
    }

    private var tracks: [ProcessIdentity: Track] = [:]
    private var systemTrack: Track?
    private var lastAlertAt: TimeInterval = -.infinity

    init(configuration: SystemAlertPolicyConfiguration = .init()) {
        self.configuration = configuration
    }

    /// Feeds one sample. Returns the notices that are due now; most samples
    /// return none. `systemPercent` is the whole-machine share and `coreCount`
    /// is used to put the per-process percentages on the same scale.
    mutating func ingest(now: TimeInterval, readings: [ProcessReading],
                         systemPercent: Double, coreCount: Int) -> [SystemAlert] {
        updateProcessTracks(now: now, readings: readings)
        let systemUpdated = updateSystemTrack(now: now, systemPercent: systemPercent)

        let readingsByIdentity = Dictionary(
            readings.map { ($0.identity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let top = readings.sorted { $0.cpuPercent > $1.cpuPercent }
            .prefix(3)

        // One process notice at a time, and not immediately after the previous
        // one: the queue in the HUD would otherwise present a burst of names.
        let candidates = tracks.compactMap { identity, track -> (ProcessIdentity, Track)? in
            guard readingsByIdentity[identity] != nil,
                  isSustained(track, now: now),
                  track.snoozedUntil.map({ $0 <= now }) ?? true,
                  now - (track.lastEmitted ?? -.infinity) >= configuration.cooldownSeconds
            else { return nil }
            return (identity, track)
        }.sorted { lhs, rhs in
            (readingsByIdentity[lhs.0]?.cpuPercent ?? 0) > (readingsByIdentity[rhs.0]?.cpuPercent ?? 0)
        }

        if let (identity, track) = candidates.first,
           let reading = readingsByIdentity[identity],
           now - lastAlertAt >= configuration.minimumSecondsBetweenAlerts {
            lastAlertAt = now
            tracks[identity]?.lastEmitted = now
            return [SystemAlert(
                kind: .process(identity),
                name: reading.name,
                cpuPercent: reading.cpuPercent,
                sustainedSeconds: now - (track.aboveSince ?? now),
                top: Array(top)
            )]
        }

        // The total is high and the readable processes do not explain it: the
        // load is in a root daemon or in the kernel, which this user cannot
        // sample. Saying so is more useful than naming the wrong process.
        guard let systemTrack, isSustained(systemTrack, now: now),
              systemUpdated,
              now - (systemTrack.lastEmitted ?? -.infinity) >= configuration.cooldownSeconds,
              now - lastAlertAt >= configuration.minimumSecondsBetweenAlerts
        else { return [] }

        let explained = readings.reduce(0) { $0 + $1.cpuPercent } / Double(max(1, coreCount))
        guard explained < systemPercent * configuration.systemExplanationRatio else { return [] }

        lastAlertAt = now
        self.systemTrack?.lastEmitted = now
        return [SystemAlert(
            kind: .system,
            name: "System processes",
            cpuPercent: systemPercent,
            sustainedSeconds: now - (systemTrack.aboveSince ?? now),
            top: Array(top)
        )]
    }

    /// A snooze keeps the episode alive; when it ends, an already-sustained
    /// process can be reported without waiting for a second full window.
    mutating func snooze(_ identity: ProcessIdentity, for seconds: TimeInterval,
                         now: TimeInterval) {
        guard var track = tracks[identity] else { return }
        track.snoozedUntil = now + max(0, seconds)
        tracks[identity] = track
    }

    mutating func reset() {
        tracks.removeAll()
        systemTrack = nil
        lastAlertAt = -.infinity
    }

    // MARK: - Tracks

    private mutating func updateProcessTracks(now: TimeInterval, readings: [ProcessReading]) {
        for reading in readings {
            var track = tracks[reading.identity]
                ?? Track(name: reading.name, lastSeen: now)
            track.name = reading.name
            track.lastSeen = now
            advance(&track, value: reading.cpuPercent,
                    threshold: configuration.processThresholdPercent, now: now)
            tracks[reading.identity] = track
        }
        tracks = tracks.filter { now - $0.value.lastSeen <= configuration.purgeSeconds }
    }

    /// Returns true when the system figure was present and above the threshold.
    private mutating func updateSystemTrack(now: TimeInterval, systemPercent: Double) -> Bool {
        var track = systemTrack ?? Track(name: "System processes", lastSeen: now)
        track.lastSeen = now
        advance(&track, value: systemPercent,
                threshold: configuration.systemThresholdPercent, now: now)
        systemTrack = track
        return systemPercent >= configuration.systemThresholdPercent
    }

    private func advance(_ track: inout Track, value: Double, threshold: Double,
                         now: TimeInterval) {
        if value >= threshold {
            if track.aboveSince == nil { track.aboveSince = now }
            track.aboveCount += 1
            track.belowCount = 0
            track.peakPercent = max(track.peakPercent, value)
        } else {
            track.belowCount += 1
            track.aboveCount = 0
            if track.belowCount >= configuration.samplesBelowToReset {
                track.aboveSince = nil
                track.peakPercent = 0
                track.belowCount = 0
            }
        }
    }

    private func isSustained(_ track: Track, now: TimeInterval) -> Bool {
        guard let since = track.aboveSince else { return false }
        return now - since >= configuration.sustainedSeconds
            && track.aboveCount >= configuration.minimumSamplesAbove
    }
}
