import CoreGraphics
import XCTest
@testable import MakiDesk

/// The focus dim's rules are pure values, so the placement can be checked
/// without a window server, a display or Accessibility (T62).
final class FocusDimTests: XCTestCase {
    private let ownPID: pid_t = 999

    private func entry(pid: pid_t = 100, number: CGWindowID,
                       frame: CGRect, layer: Int = 0,
                       alpha: CGFloat = 1) -> WindowController.CGWindowEntry {
        WindowController.CGWindowEntry(pid: pid, frame: frame, number: number,
                                       name: nil, layer: layer, alpha: alpha)
    }

    private func screen(_ id: CGDirectDisplayID, _ frame: CGRect) -> FocusDim.Screen {
        FocusDim.Screen(id: id, frame: frame)
    }

    // MARK: - Settings

    func testOpacityIsClampedToTheSupportedRange() {
        XCTAssertEqual(FocusDim.clampedOpacity(0), FocusDim.opacityRange.lowerBound)
        XCTAssertEqual(FocusDim.clampedOpacity(1), FocusDim.opacityRange.upperBound)
        XCTAssertEqual(FocusDim.clampedOpacity(0.4), 0.4)
    }

    func testFadeIsClampedToTheSupportedRange() {
        XCTAssertEqual(FocusDim.clampedFade(-1), 0)
        XCTAssertEqual(FocusDim.clampedFade(3), FocusDim.fadeRange.upperBound)
        XCTAssertEqual(FocusDim.clampedFade(0.2), 0.2)
    }

    func testReduceTransparencyMakesTheVeilSolid() {
        XCTAssertEqual(FocusDim.alpha(opacity: 0.3, reduceTransparency: true), 1)
        XCTAssertEqual(FocusDim.alpha(opacity: 0.3, reduceTransparency: false), 0.3)
        // The range still applies with transparency on.
        XCTAssertEqual(FocusDim.alpha(opacity: 4, reduceTransparency: false),
                       CGFloat(FocusDim.opacityRange.upperBound))
    }

    // MARK: - Anchors

    func testTopmostWindowSkipsOwnFloatingInvisibleAndTinyWindows() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let stack = [
            entry(pid: ownPID, number: 1, frame: display),                 // our own veil
            entry(number: 2, frame: display, layer: 3),                    // floating panel
            entry(number: 3, frame: display, alpha: 0),                    // hidden window
            entry(number: 4, frame: CGRect(x: 10, y: 10, width: 20, height: 20)), // too small
            entry(number: 5, frame: CGRect(x: -500, y: 0, width: 400, height: 400)), // other display
            entry(number: 6, frame: CGRect(x: 100, y: 100, width: 600, height: 500))
        ]
        XCTAssertEqual(FocusDim.topmostWindow(on: display, stack: stack, ownPID: ownPID), 6)
    }

    func testTopmostWindowOfAnAppIgnoresItsFloatingWindows() {
        let stack = [
            entry(pid: 100, number: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 300), layer: 2),
            entry(pid: 100, number: 2, frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        ]
        XCTAssertEqual(FocusDim.topmostWindow(of: 100, in: stack), 2)
    }

    func testLowestWindowOfAnAppIsTheBackmostOnTheDisplay() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let stack = [
            entry(pid: 100, number: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 300)),
            entry(pid: 200, number: 2, frame: CGRect(x: 0, y: 0, width: 900, height: 700)),
            entry(pid: 100, number: 3, frame: CGRect(x: 500, y: 300, width: 400, height: 300)),
            entry(pid: 100, number: 4, frame: CGRect(x: 2000, y: 0, width: 400, height: 300))
        ]
        XCTAssertEqual(FocusDim.lowestWindow(of: 100, on: display, stack: stack, ownPID: ownPID), 3)
    }

    func testDisplayUsesTheLargestIntersectionWithNegativeOrigins() {
        let screens = [
            screen(1, CGRect(x: 0, y: 0, width: 1440, height: 900)),
            screen(2, CGRect(x: -1920, y: -200, width: 1920, height: 1080))
        ]
        // Mostly on the left display, a sliver on the main one.
        let straddling = CGRect(x: -400, y: 100, width: 500, height: 400)
        XCTAssertEqual(FocusDim.display(of: straddling, in: screens), 2)
        XCTAssertEqual(FocusDim.display(of: CGRect(x: -100, y: 100, width: 400, height: 400),
                                        in: screens), 1)
        XCTAssertNil(FocusDim.display(of: CGRect(x: 5000, y: 5000, width: 100, height: 100),
                                      in: screens))
    }

    // MARK: - Drift

    func testReorderOnlyWhenTheVeilIsAboveTheAnchor() {
        XCTAssertTrue(FocusDim.needsReorder(panel: 0, anchor: 3))
        XCTAssertTrue(FocusDim.needsReorder(panel: 2, anchor: 3))
        // Further down only dims more windows, which is intended.
        XCTAssertFalse(FocusDim.needsReorder(panel: 4, anchor: 3))
        XCTAssertFalse(FocusDim.needsReorder(panel: 3, anchor: 3))
    }

    // MARK: - Plans

    private var twoDisplays: [FocusDim.Screen] {
        [
            screen(1, CGRect(x: 0, y: 0, width: 1440, height: 900)),
            screen(2, CGRect(x: 1440, y: 0, width: 1920, height: 1080))
        ]
    }

    func testIndependentModeAnchorsEveryDisplayToItsOwnTopmostWindow() {
        let stack = [
            entry(pid: 100, number: 10, frame: CGRect(x: 100, y: 100, width: 600, height: 500)),
            entry(pid: 200, number: 20, frame: CGRect(x: 1600, y: 100, width: 800, height: 600)),
            entry(pid: 200, number: 21, frame: CGRect(x: 1600, y: 700, width: 800, height: 300))
        ]
        let plan = FocusDim.plan(screens: twoDisplays, stack: stack, focused: 10, focusedPID: 100,
                                 source: .window, mode: .independent, ownPID: ownPID)
        XCTAssertEqual(plan, [
            FocusDim.Placement(display: 1, anchor: 10),
            FocusDim.Placement(display: 2, anchor: 20)
        ])
    }

    func testSingleModeDimsTheOtherDisplays() {
        let stack = [
            entry(pid: 100, number: 10, frame: CGRect(x: 100, y: 100, width: 600, height: 500)),
            entry(pid: 200, number: 20, frame: CGRect(x: 1600, y: 100, width: 800, height: 600))
        ]
        let plan = FocusDim.plan(screens: twoDisplays, stack: stack, focused: 20, focusedPID: 200,
                                 source: .window, mode: .single, ownPID: ownPID)
        XCTAssertEqual(plan, [
            FocusDim.Placement(display: 1, anchor: nil),
            FocusDim.Placement(display: 2, anchor: 20)
        ])
    }

    func testSingleModeLightsBothDisplaysAWindowStraddles() {
        let stack = [
            entry(pid: 100, number: 10, frame: CGRect(x: 1300, y: 100, width: 400, height: 500))
        ]
        let plan = FocusDim.plan(screens: twoDisplays, stack: stack, focused: 10, focusedPID: 100,
                                 source: .window, mode: .single, ownPID: ownPID)
        XCTAssertEqual(plan.map(\.anchor), [10, 10])
    }

    func testWholeAppAnchorsBelowTheLowestWindowOfTheApp() {
        let stack = [
            entry(pid: 100, number: 10, frame: CGRect(x: 100, y: 100, width: 600, height: 500)),
            entry(pid: 100, number: 11, frame: CGRect(x: 200, y: 200, width: 600, height: 500)),
            entry(pid: 200, number: 20, frame: CGRect(x: 100, y: 100, width: 900, height: 700))
        ]
        let plan = FocusDim.plan(screens: [twoDisplays[0]], stack: stack, focused: 10, focusedPID: 100,
                                 source: .application, mode: .independent, ownPID: ownPID)
        XCTAssertEqual(plan, [FocusDim.Placement(display: 1, anchor: 11)])
    }

    func testWholeAppDimsADisplayWithoutTheApp() {
        let stack = [
            entry(pid: 100, number: 10, frame: CGRect(x: 100, y: 100, width: 600, height: 500)),
            entry(pid: 200, number: 20, frame: CGRect(x: 1600, y: 100, width: 800, height: 600))
        ]
        let plan = FocusDim.plan(screens: twoDisplays, stack: stack, focused: 10, focusedPID: 100,
                                 source: .application, mode: .independent, ownPID: ownPID)
        XCTAssertEqual(plan, [
            FocusDim.Placement(display: 1, anchor: 10),
            FocusDim.Placement(display: 2, anchor: nil)
        ])
    }

    func testAnEmptyDisplayIsFullyDimmed() {
        let stack = [
            entry(pid: 100, number: 10, frame: CGRect(x: 100, y: 100, width: 600, height: 500))
        ]
        let plan = FocusDim.plan(screens: twoDisplays, stack: stack, focused: 10, focusedPID: 100,
                                 source: .window, mode: .independent, ownPID: ownPID)
        XCTAssertEqual(plan, [
            FocusDim.Placement(display: 1, anchor: 10),
            FocusDim.Placement(display: 2, anchor: nil)
        ])
    }

    func testNoScreensMeansNoPlan() {
        XCTAssertTrue(FocusDim.plan(screens: [], stack: [], focused: 1, focusedPID: 100,
                                    source: .window, mode: .independent, ownPID: ownPID).isEmpty)
    }
}
