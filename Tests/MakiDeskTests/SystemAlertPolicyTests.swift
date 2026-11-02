import XCTest
@testable import MakiDesk

/// The sustained-load rule: one notice per episode, not one per sample.
final class SystemAlertPolicyTests: XCTestCase {
    private let identity = ProcessIdentity(pid: 42, startSeconds: 100)

    private func reading(_ percent: Double, name: String = "Busy",
                         identity: ProcessIdentity? = nil) -> ProcessReading {
        ProcessReading(identity: identity ?? self.identity, name: name,
                       cpuPercent: percent)
    }

    private func configuration(sustained: TimeInterval = 20,
                               cooldown: TimeInterval = 1800,
                               minimumSpacing: TimeInterval = 0,
                               processThreshold: Double = 100) -> SystemAlertPolicyConfiguration {
        var configuration = SystemAlertPolicyConfiguration()
        configuration.processThresholdPercent = processThreshold
        configuration.sustainedSeconds = sustained
        configuration.cooldownSeconds = cooldown
        configuration.minimumSecondsBetweenAlerts = minimumSpacing
        configuration.minimumSamplesAbove = 3
        configuration.samplesBelowToReset = 2
        configuration.systemThresholdPercent = 80
        configuration.systemExplanationRatio = 0.5
        return configuration
    }

    func testAProcessIsReportedOnlyAfterTheWholeWindow() {
        var policy = SystemAlertPolicy(configuration: configuration(sustained: 20))

        XCTAssertTrue(policy.ingest(now: 0, readings: [reading(150)],
                                    systemPercent: 20, coreCount: 8).isEmpty)
        XCTAssertTrue(policy.ingest(now: 10, readings: [reading(150)],
                                    systemPercent: 20, coreCount: 8).isEmpty)
        let events = policy.ingest(now: 20, readings: [reading(150)],
                                   systemPercent: 20, coreCount: 8)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.identity, identity)
        XCTAssertEqual(events.first?.cpuPercent, 150)
        XCTAssertEqual(events.first?.sustainedSeconds, 20)
    }

    func testTheEpisodeStaysQuietForTheCooldown() {
        var policy = SystemAlertPolicy(configuration: configuration(sustained: 20,
                                                                    cooldown: 100))
        _ = policy.ingest(now: 0, readings: [reading(150)], systemPercent: 20, coreCount: 8)
        _ = policy.ingest(now: 10, readings: [reading(150)], systemPercent: 20, coreCount: 8)
        XCTAssertEqual(policy.ingest(now: 20, readings: [reading(150)],
                                     systemPercent: 20, coreCount: 8).count, 1)

        XCTAssertTrue(policy.ingest(now: 60, readings: [reading(150)],
                                    systemPercent: 20, coreCount: 8).isEmpty)
        XCTAssertEqual(policy.ingest(now: 120, readings: [reading(150)],
                                     systemPercent: 20, coreCount: 8).count, 1)
    }

    func testOneQuietSampleDoesNotRestartTheWindow() {
        var policy = SystemAlertPolicy(configuration: configuration(sustained: 20))
        _ = policy.ingest(now: 0, readings: [reading(150)], systemPercent: 20, coreCount: 8)
        _ = policy.ingest(now: 10, readings: [reading(150)], systemPercent: 20, coreCount: 8)
        _ = policy.ingest(now: 15, readings: [reading(90)], systemPercent: 5, coreCount: 8)
        _ = policy.ingest(now: 20, readings: [reading(150)], systemPercent: 20, coreCount: 8)
        _ = policy.ingest(now: 25, readings: [reading(150)], systemPercent: 20, coreCount: 8)
        let events = policy.ingest(now: 30, readings: [reading(150)],
                                   systemPercent: 20, coreCount: 8)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.sustainedSeconds, 30)
    }

    func testTwoQuietSamplesResetTheWindow() {
        var policy = SystemAlertPolicy(configuration: configuration(sustained: 20))
        _ = policy.ingest(now: 0, readings: [reading(150)], systemPercent: 20, coreCount: 8)
        _ = policy.ingest(now: 10, readings: [reading(150)], systemPercent: 20, coreCount: 8)
        _ = policy.ingest(now: 20, readings: [reading(20)], systemPercent: 5, coreCount: 8)
        _ = policy.ingest(now: 30, readings: [reading(20)], systemPercent: 5, coreCount: 8)
        XCTAssertTrue(policy.ingest(now: 40, readings: [reading(150)],
                                    systemPercent: 20, coreCount: 8).isEmpty)
    }

    func testSnoozeSilencesTheEpisodeAndEndsByItself() {
        var policy = SystemAlertPolicy(configuration: configuration(sustained: 120))
        _ = policy.ingest(now: 0, readings: [reading(150)], systemPercent: 20, coreCount: 8)
        _ = policy.ingest(now: 10, readings: [reading(150)], systemPercent: 20, coreCount: 8)
        _ = policy.ingest(now: 20, readings: [reading(150)], systemPercent: 20, coreCount: 8)
        policy.snooze(identity, for: 60, now: 20)

        XCTAssertTrue(policy.ingest(now: 100, readings: [reading(150)],
                                    systemPercent: 20, coreCount: 8).isEmpty)
        // Sustained from the first sample, snooze over: reported without a
        // second window.
        XCTAssertEqual(policy.ingest(now: 130, readings: [reading(150)],
                                     systemPercent: 20, coreCount: 8).count, 1)
    }

    func testARestartedProcessIsANewEpisode() {
        var policy = SystemAlertPolicy(configuration: configuration(sustained: 20))
        let old = ProcessIdentity(pid: 42, startSeconds: 100)
        let new = ProcessIdentity(pid: 42, startSeconds: 200)
        _ = policy.ingest(now: 0, readings: [reading(150, identity: old)],
                          systemPercent: 20, coreCount: 8)
        _ = policy.ingest(now: 10, readings: [reading(150, identity: old)],
                          systemPercent: 20, coreCount: 8)
        _ = policy.ingest(now: 20, readings: [reading(150, identity: old)],
                          systemPercent: 20, coreCount: 8)
        XCTAssertTrue(policy.ingest(now: 21, readings: [reading(150, identity: new)],
                                    systemPercent: 20, coreCount: 8).isEmpty)
    }

    func testUnexplainedSystemLoadIsReportedAsSystemProcesses() {
        var policy = SystemAlertPolicy(configuration: configuration(
            sustained: 20, processThreshold: 1000
        ))
        for now in [0.0, 10.0] {
            XCTAssertTrue(policy.ingest(now: now, readings: [reading(20)],
                                        systemPercent: 90, coreCount: 8).isEmpty)
        }
        let events = policy.ingest(now: 20, readings: [reading(20)],
                                   systemPercent: 90, coreCount: 8)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .system)
        XCTAssertEqual(events.first?.name, "System processes")
    }

    func testExplainedLoadIsNotBlamedOnTheSystem() {
        var policy = SystemAlertPolicy(configuration: configuration(
            sustained: 20, processThreshold: 1000
        ))
        for now in [0.0, 10.0, 20.0] {
            _ = policy.ingest(now: now, readings: [reading(700)],
                              systemPercent: 90, coreCount: 8)
        }
        XCTAssertTrue(policy.ingest(now: 30, readings: [reading(700)],
                                    systemPercent: 90, coreCount: 8).isEmpty)
    }

    func testAProcessNoticeWinsOverASystemNoticeOnTheSameSample() {
        var policy = SystemAlertPolicy(configuration: configuration(sustained: 20))
        _ = policy.ingest(now: 0, readings: [reading(150)], systemPercent: 90, coreCount: 8)
        _ = policy.ingest(now: 10, readings: [reading(150)], systemPercent: 90, coreCount: 8)
        let events = policy.ingest(now: 20, readings: [reading(150)],
                                   systemPercent: 90, coreCount: 8)
        XCTAssertEqual(events.count, 1)
        XCTAssertNotNil(events.first?.identity)
    }
}
