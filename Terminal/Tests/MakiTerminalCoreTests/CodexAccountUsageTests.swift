import Foundation
import XCTest
@testable import MakiTerminalCore

final class CodexAccountUsageTests: XCTestCase {
    func testParsesMultipleQuotaWindowsAndResetCredits() throws {
        let json = #"{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"limitName":"Codex","primary":{"usedPercent":37,"windowDurationMins":300,"resetsAt":1800000000},"secondary":{"usedPercent":71,"resetsAt":1800003600},"credits":{"hasCredits":true,"unlimited":false,"balance":"12.50"}},"codex_other":{"primary":{"usedPercent":10}}},"rateLimitResetCredits":{"availableCount":2}}}"#
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let usage = try XCTUnwrap(CodexAccountUsageParser.rateLimits(
            from: object, updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        XCTAssertEqual(usage.windows.map(\.id), ["codex.primary", "codex.secondary", "codex_other.primary"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [37, 71, 10])
        XCTAssertEqual(usage.resetCredits, 2)
        XCTAssertEqual(usage.creditSummaries, ["Codex credits: 12.50"])
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(usage.lifetimeTokens)
    }

    func testSupportsLegacySingleBucketResponseAndRejectsInvalidPercentages() throws {
        let json = #"{"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":140},"secondary":{"usedPercent":55}}}}"#
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let usage = try XCTUnwrap(CodexAccountUsageParser.rateLimits(from: object))
        XCTAssertEqual(usage.windows.map(\.id), ["codex.secondary"])
        XCTAssertEqual(usage.windows.first?.usedPercent, 55)
    }

    func testParsesOnlyProvidedAccountWideUsageAndKeepsQuotaSnapshot() throws {
        let rate = #"{"result":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":23}}}}}"#
        let usageJSON = #"{"result":{"summary":{"lifetimeTokens":123456,"peakDailyTokens":5678},"dailyUsageBuckets":[{"startDate":"2026-11-14","tokens":100}],"threadId":"ignored"}}"#
        let base = try XCTUnwrap(CodexAccountUsageParser.rateLimits(from: JSONSerialization.jsonObject(with: Data(rate.utf8))))
        let result = CodexAccountUsageParser.usage(
            from: try JSONSerialization.jsonObject(with: Data(usageJSON.utf8)), into: base
        )
        XCTAssertEqual(result.windows, base.windows)
        XCTAssertEqual(result.lifetimeTokens, 123456)
        XCTAssertEqual(result.peakDailyTokens, 5678)
        XCTAssertEqual(result.updatedAt, base.updatedAt)
    }

    func testMissingUsageLeavesMetricsUnknown() throws {
        let rate = #"{"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":23}}}}"#
        let base = try XCTUnwrap(CodexAccountUsageParser.rateLimits(from: JSONSerialization.jsonObject(with: Data(rate.utf8))))
        let result = CodexAccountUsageParser.usage(from: ["result": ["summary": [:]]], into: base)
        XCTAssertNil(result.lifetimeTokens)
        XCTAssertNil(result.peakDailyTokens)
    }

    func testRefreshLifecycleAllowsOneVisibleRequestAndRejectsHiddenStaleCompletion() {
        var lifecycle = CodexUsageRefreshLifecycle()
        XCTAssertNil(lifecycle.beginRefresh())
        XCTAssertTrue(lifecycle.setVisible(true))
        let first = try! XCTUnwrap(lifecycle.beginRefresh())
        XCTAssertNil(lifecycle.beginRefresh())

        XCTAssertFalse(lifecycle.setVisible(false))
        XCTAssertFalse(lifecycle.finishRefresh(generation: first))
        XCTAssertNil(lifecycle.beginRefresh())

        XCTAssertTrue(lifecycle.setVisible(true))
        let second = try! XCTUnwrap(lifecycle.beginRefresh())
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(lifecycle.finishRefresh(generation: first))
        XCTAssertTrue(lifecycle.finishRefresh(generation: second))
        XCTAssertFalse(lifecycle.isRefreshing)
    }
}
