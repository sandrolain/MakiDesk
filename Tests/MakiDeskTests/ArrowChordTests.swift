import Carbon.HIToolbox
import XCTest
@testable import MakiDesk

/// S03: the two-arrow chord that spans a window on one axis.
///
/// The rule is pure: the physical key state arrives through `isKeyDown`, so the
/// combinations — both arrows of the pair, a remapped row, a disabled row — are
/// assertions rather than three hands on a keyboard.
final class ArrowChordTests: XCTestCase {
    private let down: (Int) -> Bool = { _ in true }
    private let up: (Int) -> Bool = { _ in false }

    // MARK: - The pair

    func testEachArrowCommandKnowsItsPartner() {
        XCTAssertEqual(ArrowChord.member(for: .leftHalf)?.axis, .horizontal)
        XCTAssertEqual(ArrowChord.member(for: .rightHalf)?.axis, .horizontal)
        XCTAssertEqual(ArrowChord.member(for: .topHalf)?.axis, .vertical)
        XCTAssertEqual(ArrowChord.member(for: .bottomHalf)?.axis, .vertical)
        XCTAssertEqual(ArrowChord.member(for: .leftHalf)?.partnerKey, kVK_RightArrow)
        XCTAssertEqual(ArrowChord.member(for: .rightHalf)?.partnerKey, kVK_LeftArrow)
        XCTAssertEqual(ArrowChord.member(for: .topHalf)?.partnerKey, kVK_DownArrow)
        XCTAssertEqual(ArrowChord.member(for: .bottomHalf)?.partnerKey, kVK_UpArrow)
    }

    func testOtherCommandsHaveNoChord() {
        for action in [WindowController.ShortcutAction.center, .phi, .minimize,
                       .toggleFullScreen, .gridLayout, .centerCycle] {
            XCTAssertNil(ArrowChord.member(for: action), "\(action)")
        }
    }

    func testThePairIsInTableOrder() {
        XCTAssertEqual(ArrowChord.rowIDs(for: .horizontal), ["window.left", "window.right"])
        XCTAssertEqual(ArrowChord.rowIDs(for: .vertical), ["window.top", "window.bottom"])
    }

    // MARK: - The keyboard state

    func testBothArrowsTogetherSpanTheAxis() {
        XCTAssertEqual(ArrowChord.axis(for: .topHalf, bindings: .defaults, isKeyDown: down),
                       .vertical)
        XCTAssertEqual(ArrowChord.axis(for: .bottomHalf, bindings: .defaults, isKeyDown: down),
                       .vertical)
        XCTAssertEqual(ArrowChord.axis(for: .leftHalf, bindings: .defaults, isKeyDown: down),
                       .horizontal)
        XCTAssertEqual(ArrowChord.axis(for: .rightHalf, bindings: .defaults, isKeyDown: down),
                       .horizontal)
    }

    func testOneArrowAloneIsTheOrdinaryStep() {
        for action in [WindowController.ShortcutAction.topHalf, .bottomHalf,
                       .leftHalf, .rightHalf] {
            XCTAssertNil(ArrowChord.axis(for: action, bindings: .defaults, isKeyDown: up),
                         "\(action)")
        }
    }

    func testTheChordNeedsThePairInForce() {
        // A remapped vertical arrow turns the vertical chord off; the
        // horizontal pair is untouched.
        let remapped = ShortcutBindings(overrides: [
            "window.bottom": ShortcutOverride(binding: ShortcutBinding(
                keyCode: kVK_ANSI_Z, modifiers: ShortcutDefinitions.ctrlOptShift))
        ])
        XCTAssertFalse(ArrowChord.isIntact(.vertical, in: remapped))
        XCTAssertTrue(ArrowChord.isIntact(.horizontal, in: remapped))
        XCTAssertNil(ArrowChord.axis(for: .topHalf, bindings: remapped, isKeyDown: down))
        XCTAssertEqual(ArrowChord.axis(for: .leftHalf, bindings: remapped, isKeyDown: down),
                       .horizontal)
    }

    func testATurnedOffArrowTurnsTheChordOff() {
        let disabled = ShortcutBindings(overrides: [
            "window.left": ShortcutOverride(disabled: true)
        ])
        XCTAssertFalse(ArrowChord.isIntact(.horizontal, in: disabled))
        XCTAssertNil(ArrowChord.axis(for: .rightHalf, bindings: disabled, isKeyDown: down))
    }

    func testDefaultsAreIntact() {
        XCTAssertTrue(ArrowChord.isIntact(.horizontal, in: .defaults))
        XCTAssertTrue(ArrowChord.isIntact(.vertical, in: .defaults))
    }

    // MARK: - The table

    func testTheDocumentedRowsExist() {
        guard let height = ShortcutDefinitions.definition(id: "window.fullHeight"),
              let width = ShortcutDefinitions.definition(id: "window.fullWidth") else {
            return XCTFail("missing the chord rows")
        }
        XCTAssertEqual(height.display, "⌃⌥↑ + ↓")
        XCTAssertEqual(width.display, "⌃⌥← + →")
        XCTAssertFalse(height.isGlobal)
        XCTAssertFalse(width.isGlobal)
        XCTAssertEqual(height.section, "Window")
        XCTAssertEqual(width.section, "Window")
    }
}
