import XCTest
@testable import MakiDesk

/// The intelligent layout (T18) is pure, so every rule can be read off a table of
/// cases: the number of windows, how dense their content looks, what kind of app
/// they are and how big they are decide between the grid and the golden spiral,
/// and always with a reason to show.
final class LayoutAdvisorTests: XCTestCase {
    private func subject(_ id: String,
                         app: String = "Example",
                         bundle: String? = nil,
                         title: String = "",
                         width: CGFloat = 800,
                         height: CGFloat = 600) -> LayoutSubject {
        LayoutSubject(id: id, appName: app, bundleId: bundle, title: title,
                      area: Double(width * height))
    }

    private func measure(_ scores: [String: Double]) -> ContentMeasure {
        ContentMeasure(scores: scores)
    }

    // MARK: - Reads on the set of windows

    func testNothingToArrange() {
        let advice = LayoutAdvisor.advise([], measure: measure([:]))
        XCTAssertEqual(advice.layout, .grid)
        XCTAssertNil(advice.leadID)
    }

    func testOneWindowFillsTheScreen() {
        let advice = LayoutAdvisor.advise([subject("a")], measure: measure([:]))
        XCTAssertEqual(advice.layout, .grid)
        XCTAssertTrue(advice.reason.contains("one window"))
    }

    func testTwoWindowsGetEqualHalves() {
        let advice = LayoutAdvisor.advise([subject("a"), subject("b")], measure: measure(["a": 9, "b": 1]))
        XCTAssertEqual(advice.layout, .grid)
        XCTAssertTrue(advice.reason.contains("two windows"))
    }

    func testMoreWindowsThanTheSpiralHoldsGetTheGrid() {
        // Uniform content: nothing triggers the weighted layout, so the spiral
        // cap is what decides.
        let subjects = (0..<7).map { subject("w\($0)") }
        let advice = LayoutAdvisor.advise(subjects,
                                          measure: measure(Dictionary(uniqueKeysWithValues:
                                              (0..<7).map { ("w\($0)", 5.0) })))
        XCTAssertEqual(advice.layout, .grid)
        XCTAssertTrue(advice.reason.contains("stops at"))
    }

    // MARK: - The content measure (M1)

    func testWithoutAMeasureTheGridIsTheFallback() {
        let big = subject("big", width: 1600, height: 1200)
        let advice = LayoutAdvisor.advise([big, subject("b"), subject("c")], measure: measure([:]))
        XCTAssertEqual(advice.layout, .grid)
        XCTAssertTrue(advice.reason.contains("no content measurement"))
    }

    func testTheDenserWindowTakesTheWidestSlot() {
        // 1.5× the runner-up: enough for the spiral, below the 2× that would
        // make the weighted layout the better answer (T30).
        let subjects = [subject("a", app: "Notes"), subject("b"), subject("c")]
        let advice = LayoutAdvisor.advise(subjects, measure: measure(["a": 15, "b": 10, "c": 8]))
        XCTAssertEqual(advice.layout, .goldenSpiral)
        XCTAssertEqual(advice.leadID, "a")
        XCTAssertTrue(advice.reason.contains("Notes"))
        XCTAssertTrue(advice.reason.contains("densest"))
    }

    func testSimilarDensitiesGetEqualCells() {
        let subjects = [subject("a"), subject("b"), subject("c"), subject("d")]
        let advice = LayoutAdvisor.advise(subjects, measure: measure(["a": 6, "b": 5, "c": 4, "d": 3]))
        XCTAssertEqual(advice.layout, .grid)
        XCTAssertNil(advice.leadID)
        XCTAssertTrue(advice.reason.contains("similar density"))
    }

    func testThreeWindowsGetTheSpiralRatherThanAnEmptyQuarter() {
        let subjects = [subject("a"), subject("b"), subject("c")]
        let advice = LayoutAdvisor.advise(subjects, measure: measure(["a": 5, "b": 5, "c": 5]))
        XCTAssertEqual(advice.layout, .goldenSpiral)
        XCTAssertEqual(advice.leadID, "a")
        XCTAssertTrue(advice.reason.contains("three windows"))
    }

    func testAWindowThatCouldNotBeMeasuredStillWinsWhenItIsFarBigger() {
        let subjects = [
            subject("a", app: "Diagram", width: 1000, height: 1000),   // not captured
            subject("b", width: 400, height: 300),
            subject("c", width: 300, height: 200)
        ]
        let advice = LayoutAdvisor.advise(subjects, measure: measure(["b": 5, "c": 4]))
        XCTAssertEqual(advice.layout, .goldenSpiral)
        XCTAssertEqual(advice.leadID, "a")
        XCTAssertTrue(advice.reason.contains("bigger"))
    }

    // MARK: - The kind of window

    func testAVideoTakesTheWidestSlotEvenWhenItMeasuresLow() {
        let subjects = [subject("b"), subject("c"), subject("v", app: "VLC")]
        let advice = LayoutAdvisor.advise(subjects, measure: measure(["b": 5, "c": 5, "v": 5]))
        XCTAssertEqual(advice.layout, .goldenSpiral)
        XCTAssertEqual(advice.leadID, "v")
        XCTAssertTrue(advice.reason.contains("video"))
    }

    func testASetOfOneKindNamesThatKindWhenNothingStandsOut() {
        let subjects = (0..<4).map { subject("s\($0)", app: "Sublime Text", bundle: "com.sublimetext.4") }
        let advice = LayoutAdvisor.advise(subjects, measure: measure(["s0": 5, "s1": 4, "s2": 4, "s3": 3]))
        XCTAssertEqual(advice.layout, .grid)
        XCTAssertEqual(advice.reason, "4 editor windows: equal cells")
    }

    func testTheSameSetAlwaysGivesTheSameAdvice() {
        let subjects = [subject("a"), subject("b"), subject("c")]
        let first = LayoutAdvisor.advise(subjects, measure: measure(["a": 15, "b": 10, "c": 8]))
        let second = LayoutAdvisor.advise(subjects.reversed(), measure: measure(["a": 15, "b": 10, "c": 8]))
        XCTAssertEqual(first, second)
        XCTAssertEqual(second.leadID, "a")
    }

    // MARK: - The content-weighted layout (T30)

    func testClearlyImbalancedContentGetsTheWeightedLayout() {
        let subjects = [subject("a", app: "Xcode", bundle: "com.apple.dt.Xcode"),
                        subject("b", app: "Notes"), subject("c", app: "Preview")]
        let advice = LayoutAdvisor.advise(subjects, measure: measure(["a": 30, "b": 10, "c": 8]))
        XCTAssertEqual(advice.layout, .content)
        XCTAssertNil(advice.leadID)
        XCTAssertNotNil(advice.weights)
        XCTAssertEqual(advice.weights?.count, 3)
        XCTAssertTrue(advice.reason.contains("content"))
    }

    func testManyWindowsWithUnevenContentGetTheWeightedLayout() {
        // More windows than the spiral can hold: a treemap has no such limit.
        let subjects = (0..<8).map { subject("w\($0)") }
        var scores: [String: Double] = [:]
        for index in 0..<8 { scores["w\(index)"] = index == 0 ? 60 : 10 }
        let advice = LayoutAdvisor.advise(subjects, measure: measure(scores))
        XCTAssertEqual(advice.layout, .content)
    }

    func testPriorsAloneCanTriggerTheWeightedLayout() {
        let subjects = [subject("editor", app: "Xcode", bundle: "com.apple.dt.Xcode"),
                        subject("chat", app: "Slack", bundle: "com.tinyspeck.slackmacgap"),
                        subject("other", app: "Finder", bundle: "com.apple.finder")]
        let advice = LayoutAdvisor.advise(subjects,
                                          measure: measure(["editor": 10, "chat": 10, "other": 10]))
        XCTAssertEqual(advice.layout, .content)
        XCTAssertTrue(advice.reason.contains("weighs"))
        // Equal scores sit at the median, where the content factor is 1.3.
        XCTAssertEqual(advice.weights?["editor"] ?? 0, 1.4 * 1.3, accuracy: 0.001)
        XCTAssertEqual(advice.weights?["chat"] ?? 0, 0.7 * 1.3, accuracy: 0.001)
    }

    func testCustomPriorsAreUsedByTheAdvisor() {
        let subjects = [subject("editor", app: "Xcode", bundle: "com.apple.dt.Xcode"),
                        subject("chat", app: "Slack", bundle: "com.tinyspeck.slackmacgap"),
                        subject("other", app: "Finder", bundle: "com.apple.finder")]
        let priors: [WindowKind: Double] = [.editor: 2.0, .chat: 0.5, .other: 1.0]
        let advice = LayoutAdvisor.advise(subjects,
                                          measure: measure(["editor": 10, "chat": 10, "other": 10]),
                                          priors: priors)
        XCTAssertEqual(advice.layout, .content)
        XCTAssertEqual(advice.weights?["editor"] ?? 0, 2.0 * 1.3, accuracy: 0.001)
        XCTAssertEqual(advice.weights?["chat"] ?? 0, 0.5 * 1.3, accuracy: 0.001)
    }

    func testWeightedLayoutNeedsAMeasureEvenWhenPriorsDiffer() {
        let subjects = [subject("editor", app: "Xcode", bundle: "com.apple.dt.Xcode"),
                        subject("chat", app: "Slack", bundle: "com.tinyspeck.slackmacgap"),
                        subject("other", app: "Finder", bundle: "com.apple.finder")]
        let advice = LayoutAdvisor.advise(subjects, measure: measure([:]))
        XCTAssertEqual(advice.layout, .grid)
        XCTAssertTrue(advice.reason.contains("no content measurement"))
    }

    func testTwoWindowsNeverGetTheWeightedLayout() {
        let advice = LayoutAdvisor.advise([subject("a"), subject("b")],
                                          measure: measure(["a": 90, "b": 1]))
        XCTAssertEqual(advice.layout, .grid)
        XCTAssertNil(advice.weights)
    }

    func testUniformContentAndPriorsKeepTheOldRules() {
        let subjects = (0..<4).map { subject("w\($0)") }
        let advice = LayoutAdvisor.advise(subjects,
                                          measure: measure(Dictionary(uniqueKeysWithValues:
                                              (0..<4).map { ("w\($0)", 5.0) })))
        XCTAssertEqual(advice.layout, .grid)
        XCTAssertNil(advice.weights)
    }

    func testWeightsUseTheMedianAndLeaveUnmeasuredWindowsAtTheirPrior() {
        let subjects = [subject("low"), subject("high"),
                        subject("plain", app: "Xcode", bundle: "com.apple.dt.Xcode")]
        let weights = LayoutAdvisor.weights(subjects, measure: measure(["low": 10, "high": 20]))
        // Median 15: 0.7 + 0.6 × (10/15) and (20/15).
        XCTAssertEqual(weights["low"] ?? 0, 0.7 + 0.6 * (10.0 / 15.0), accuracy: 0.0001)
        XCTAssertEqual(weights["high"] ?? 0, 0.7 + 0.6 * (20.0 / 15.0), accuracy: 0.0001)
        XCTAssertEqual(weights["plain"] ?? 0, 1.4, accuracy: 0.0001)
    }

    func testWeightFactorClampsAtTwo() {
        let weights = LayoutAdvisor.weights([subject("a"), subject("b"), subject("c")],
                                            measure: measure(["a": 1000, "b": 1, "c": 1]))
        XCTAssertEqual(weights["a"] ?? 0, 1.0 * 2.0, accuracy: 0.0001)
    }

    // MARK: - Reading the kind off the app

    func testKindComesFromTheApp() {
        XCTAssertEqual(LayoutAdvisor.kind(bundleId: "com.apple.dt.Xcode", appName: "Xcode", title: ""), .editor)
        XCTAssertEqual(LayoutAdvisor.kind(bundleId: "com.googlecode.iterm2", appName: "iTerm2", title: ""), .terminal)
        XCTAssertEqual(LayoutAdvisor.kind(bundleId: "com.apple.Safari", appName: "Safari", title: ""), .browser)
        XCTAssertEqual(LayoutAdvisor.kind(bundleId: "com.tinyspeck.slackmacgap", appName: "Slack", title: ""), .chat)
        XCTAssertEqual(LayoutAdvisor.kind(bundleId: "com.apple.Preview", appName: "Preview", title: ""), .document)
        XCTAssertEqual(LayoutAdvisor.kind(bundleId: "org.videolan.vlc", appName: "VLC", title: ""), .video)
    }

    func testKindFallsBackToTheFileInTheTitle() {
        XCTAssertEqual(LayoutAdvisor.kind(bundleId: "com.example.Thing", appName: "Thing", title: "main.swift"), .editor)
        XCTAssertEqual(LayoutAdvisor.kind(bundleId: "com.example.Thing", appName: "Thing", title: "notes.md"), .document)
        XCTAssertEqual(LayoutAdvisor.kind(bundleId: "com.example.Thing", appName: "Thing", title: "Untitled"), .other)
        XCTAssertEqual(LayoutAdvisor.kind(bundleId: nil, appName: "Thing", title: "report.pdf"), .document)
    }
}
