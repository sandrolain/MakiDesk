import CoreGraphics
import XCTest
@testable import MakiDesk

/// The two identities a display transition needs: which desk this is (the saved
/// layout key) and whether it has stopped moving (the fingerprint).
final class DisplayLayoutTests: XCTestCase {
    private let first: CGDirectDisplayID = 1
    private let second: CGDirectDisplayID = 2

    func testTheLayoutKeyIsStableAcrossScreenOrder() {
        let left = DisplayLayoutIdentity([
            (first, CGSize(width: 1440, height: 900)),
            (second, CGSize(width: 1920, height: 1080)),
        ])
        let right = DisplayLayoutIdentity([
            (second, CGSize(width: 1920, height: 1080)),
            (first, CGSize(width: 1440, height: 900)),
        ])
        XCTAssertEqual(left.key, right.key)
        XCTAssertEqual(left.key, "1:1440x900|2:1920x1080")
    }

    func testAResolutionChangeIsADifferentLayoutSet() {
        let before = DisplayLayoutIdentity([(first, CGSize(width: 1440, height: 900))])
        let after = DisplayLayoutIdentity([(first, CGSize(width: 1920, height: 1080))])
        XCTAssertNotEqual(before.key, after.key)
    }

    func testADockChangeSettlesTheDeskWithoutChangingTheLayoutKey() {
        let identity = DisplayLayoutIdentity([(first, CGSize(width: 1440, height: 900))])
        let before = DisplayFingerprint(
            identity: identity,
            visible: [first: CGRect(x: 0, y: 0, width: 1440, height: 875)],
            scales: [first: 2])
        let after = DisplayFingerprint(
            identity: identity,
            visible: [first: CGRect(x: 0, y: 60, width: 1440, height: 815)],
            scales: [first: 2])
        XCTAssertNotEqual(before.signature, after.signature)
        XCTAssertEqual(before.identity.key, after.identity.key)
    }

    func testAScaleChangeIsANewFingerprint() {
        let identity = DisplayLayoutIdentity([(first, CGSize(width: 1440, height: 900))])
        let retina = DisplayFingerprint(identity: identity, visible: [:], scales: [first: 2])
        let external = DisplayFingerprint(identity: identity, visible: [:], scales: [first: 1])
        XCTAssertNotEqual(retina.signature, external.signature)
    }

    func testSubPointNoiseDoesNotKeepTheDeskUnsettled() {
        let identity = DisplayLayoutIdentity([(first, CGSize(width: 1440, height: 900))])
        let firstReading = DisplayFingerprint(
            identity: identity,
            visible: [first: CGRect(x: 0.2, y: 0.1, width: 1440, height: 875)],
            scales: [first: 2])
        let secondReading = DisplayFingerprint(
            identity: identity,
            visible: [first: CGRect(x: 0.4, y: 0.3, width: 1440, height: 875)],
            scales: [first: 2])
        XCTAssertEqual(firstReading.signature, secondReading.signature)
    }
}
