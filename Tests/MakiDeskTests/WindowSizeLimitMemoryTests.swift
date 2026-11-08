import CoreGraphics
import XCTest
@testable import MakiDesk

/// The session memory of size floors and fixed lengths. It learns only from a
/// guarded refusal and relaxes only when the app accepts something smaller.
@MainActor
final class WindowSizeLimitMemoryTests: XCTestCase {
    private let previous = CGRect(x: 0, y: 0, width: 400, height: 300)
    private let wanted = CGRect(x: 50, y: 40, width: 800, height: 600)
    private let identity = "123-cg456"
    private let bundle = "com.example.editor"

    func testARefusalRaisesTheFloorOnlyOnTheAxisItRefused() {
        let memory = WindowSizeLimitMemory()
        let actual = CGRect(x: 50, y: 40, width: 960, height: 600)
        XCTAssertTrue(memory.observeRefusal(identity: identity, bundleId: bundle,
                                            wanted: wanted, previous: previous,
                                            actual: actual))
        let limits = memory.limits(for: identity, bundleId: bundle)
        XCTAssertEqual(limits.minimum.width, 960)
        XCTAssertEqual(limits.minimum.height, 0)
    }

    func testARefusalAtTheWrongOriginTeachesNothing() {
        let memory = WindowSizeLimitMemory()
        let actual = CGRect(x: 0, y: 0, width: 960, height: 600)
        XCTAssertFalse(memory.observeRefusal(identity: identity, bundleId: bundle,
                                             wanted: wanted, previous: previous,
                                             actual: actual))
        XCTAssertTrue(memory.limits(for: identity, bundleId: bundle).isEmpty)
    }

    func testAnAppHintCarriesToAnotherWindowOfTheSameApp() {
        let memory = WindowSizeLimitMemory()
        _ = memory.observeRefusal(identity: identity, bundleId: bundle,
                                  wanted: wanted, previous: previous,
                                  actual: CGRect(x: 50, y: 40, width: 960, height: 600))
        let sibling = memory.limits(for: "999-cg111", bundleId: bundle)
        XCTAssertEqual(sibling.minimum.width, 960)
        XCTAssertTrue(memory.limits(for: "999-cg111", bundleId: "com.example.other").isEmpty)
    }

    func testAnAcceptedSmallerSizeLowersTheFloor() {
        let memory = WindowSizeLimitMemory()
        _ = memory.observeRefusal(identity: identity, bundleId: bundle,
                                  wanted: wanted, previous: previous,
                                  actual: CGRect(x: 50, y: 40, width: 960, height: 600))
        XCTAssertTrue(memory.observeAccepted(identity: identity, bundleId: bundle,
                                             actual: CGSize(width: 700, height: 600)))
        XCTAssertEqual(memory.limits(for: identity, bundleId: bundle).minimum.width, 700)
        // The app's hint comes down with it, so a sibling starts from the
        // smaller fact rather than the old high-water mark.
        XCTAssertEqual(memory.limits(for: "999-cg111", bundleId: bundle).minimum.width, 700)
    }

    func testAnAcceptedSizeWithinTheDeltaLeavesTheFloorAlone() {
        let memory = WindowSizeLimitMemory()
        _ = memory.observeRefusal(identity: identity, bundleId: bundle,
                                  wanted: wanted, previous: previous,
                                  actual: CGRect(x: 50, y: 40, width: 960, height: 600))
        XCTAssertFalse(memory.observeAccepted(identity: identity, bundleId: bundle,
                                              actual: CGSize(width: 955, height: 600)))
        XCTAssertEqual(memory.limits(for: identity, bundleId: bundle).minimum.width, 960)
    }

    func testAFixedLengthNeedsTwoIdenticalRefusals() {
        let memory = WindowSizeLimitMemory()
        let fixedWidth = FixedAxis(axis: .width, length: 960)
        let wantedFrame = CGRect(x: 0, y: 0, width: 700, height: 500)
        let actual = CGRect(x: 0, y: 0, width: 960, height: 500)
        let previousFrame = CGRect(x: 0, y: 0, width: 960, height: 200)

        _ = memory.observeRefusal(identity: identity, bundleId: bundle,
                                  wanted: wantedFrame, previous: previousFrame,
                                  actual: actual)
        XCTAssertFalse(memory.knowsFixed(fixedWidth, identity: identity))

        _ = memory.observeRefusal(identity: identity, bundleId: bundle,
                                  wanted: wantedFrame, previous: previousFrame,
                                  actual: actual)
        XCTAssertTrue(memory.knowsFixed(fixedWidth, identity: identity))
        XCTAssertFalse(memory.knowsFixed(FixedAxis(axis: .width, length: 800),
                                         identity: identity))
    }

    func testAnAcceptedDifferentLengthClearsAFixedRecord() {
        let memory = WindowSizeLimitMemory()
        let fixedWidth = FixedAxis(axis: .width, length: 960)
        let wantedFrame = CGRect(x: 0, y: 0, width: 700, height: 500)
        let actual = CGRect(x: 0, y: 0, width: 960, height: 500)
        let previousFrame = CGRect(x: 0, y: 0, width: 960, height: 200)
        for _ in 0..<2 {
            _ = memory.observeRefusal(identity: identity, bundleId: bundle,
                                      wanted: wantedFrame, previous: previousFrame,
                                      actual: actual)
        }
        XCTAssertTrue(memory.knowsFixed(fixedWidth, identity: identity))

        _ = memory.observeAccepted(identity: identity, bundleId: bundle,
                                   actual: CGSize(width: 820, height: 500))
        XCTAssertFalse(memory.knowsFixed(fixedWidth, identity: identity))
    }

    func testSentinelAndZeroIdentitiesTeachNothing() {
        let memory = WindowSizeLimitMemory()
        XCTAssertFalse(memory.observeRefusal(identity: "", bundleId: bundle,
                                             wanted: wanted, previous: previous,
                                             actual: CGRect(x: 50, y: 40, width: 960, height: 600)))
        XCTAssertFalse(memory.observeRefusal(identity: identity, bundleId: bundle,
                                             wanted: wanted, previous: previous,
                                             actual: CGRect(x: 50, y: 40, width: 20_000, height: 600)))
        XCTAssertTrue(memory.limits(for: identity, bundleId: bundle).isEmpty)
    }

    func testForgetRemovesTheFloorButKeepsTheAppHint() {
        let memory = WindowSizeLimitMemory()
        _ = memory.observeRefusal(identity: identity, bundleId: bundle,
                                  wanted: wanted, previous: previous,
                                  actual: CGRect(x: 50, y: 40, width: 960, height: 600))
        memory.forget(identity: identity)
        XCTAssertTrue(memory.limits(for: identity, bundleId: nil).isEmpty)
        // The hint is evidence about the app, not about the window that left.
        XCTAssertEqual(memory.limits(for: "999-cg111", bundleId: bundle).minimum.width, 960)
    }

    func testATerminatedAppsFloorsGoWithIt() {
        let memory = WindowSizeLimitMemory()
        for (windowIdentity, pid) in [("123-cg456", pid_t(123)), ("789-cg101", pid_t(789))] {
            _ = memory.observeRefusal(identity: windowIdentity, bundleId: bundle,
                                      wanted: wanted, previous: previous,
                                      actual: CGRect(x: 50, y: 40, width: 960, height: 600))
        }
        memory.forget(pid: 123)
        XCTAssertTrue(memory.limits(for: "123-cg456", bundleId: nil).isEmpty)
        XCTAssertEqual(memory.limits(for: "789-cg101", bundleId: nil).minimum.width, 960)
    }

    func testTheClampNeverShrinksAnAcceptedFrame() {
        var limits = WindowSizeLimits()
        limits.minimum = CGSize(width: 500, height: 300)
        XCTAssertEqual(limits.clamped(CGSize(width: 400, height: 800)),
                       CGSize(width: 500, height: 800))
        XCTAssertTrue(limits.isTooSmall(CGSize(width: 480, height: 800)))
        XCTAssertFalse(limits.isTooSmall(CGSize(width: 500, height: 800)))
    }
}
