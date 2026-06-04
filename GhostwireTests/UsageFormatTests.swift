//
//  UsageFormatTests.swift
//  GhostwireTests
//
//  GW-151: compact formatting for the usage meter (minimal-text rule -
//  these strings are the ONLY text the summary row shows).
//

import XCTest
@testable import Ghostwire

final class UsageFormatTests: XCTestCase {

    func testTokenCountsAbbreviate() {
        XCTAssertEqual(UsageFormat.tokenCount(950), "950")
        XCTAssertEqual(UsageFormat.tokenCount(1_200), "1.2k")
        XCTAssertEqual(UsageFormat.tokenCount(82_000), "82k")
        XCTAssertEqual(UsageFormat.tokenCount(1_240_000), "1.2M")
        XCTAssertEqual(UsageFormat.tokenCount(82_490_395), "82M")
        XCTAssertEqual(UsageFormat.tokenCount(1_300_000_000), "1.3B")
    }

    func testCostIsFlaggedAsEstimate() {
        XCTAssertEqual(UsageFormat.estimatedCost(4.8012), "~$4.80")
        XCTAssertEqual(UsageFormat.estimatedCost(0.004), "~$0.00")
        XCTAssertEqual(UsageFormat.estimatedCost(1234.5), "~$1,234.50")
    }

    func testQuotaBarShowsSessionNormally() {
        let selection = UsageFormat.quotaBarSelection(
            fiveHour: QuotaPeriod(utilization: 38, resetsAt: nil),
            sevenDay: QuotaPeriod(utilization: 40, resetsAt: nil)
        )
        XCTAssertEqual(selection?.label, "Session")
        XCTAssertEqual(selection?.period.utilization, 38)
    }

    func testQuotaBarSwitchesToWeeklyWhenSevenDayIsCritical() {
        // Weekly >=90% is the binding constraint - the bar must SAY which
        // window it's showing when it switches (label = timeframe rule)
        let selection = UsageFormat.quotaBarSelection(
            fiveHour: QuotaPeriod(utilization: 12, resetsAt: nil),
            sevenDay: QuotaPeriod(utilization: 92, resetsAt: nil)
        )
        XCTAssertEqual(selection?.label, "Weekly")
        XCTAssertEqual(selection?.period.utilization, 92)
    }

    func testQuotaBarFallsBackToWeeklyWhenSessionMissing() {
        let selection = UsageFormat.quotaBarSelection(
            fiveHour: nil,
            sevenDay: QuotaPeriod(utilization: 40, resetsAt: nil)
        )
        XCTAssertEqual(selection?.label, "Weekly")
    }

    func testQuotaBarNilWhenNoPeriods() {
        XCTAssertNil(UsageFormat.quotaBarSelection(fiveHour: nil, sevenDay: nil))
    }

    // MARK: - Freshness (locally-derived meters age out; endpoint quota is pinned)

    func testTokenDisplayWithFiveHourActivityIsFresh() {
        let tokens = AgentTokenDisplay(
            fiveHour: TokenUsageTotals(inputTokens: 1_000),
            sevenDay: TokenUsageTotals(inputTokens: 50_000)
        )
        XCTAssertTrue(tokens.hasRecentActivity)
    }

    func testTokenDisplayWithoutFiveHourActivityIsStale() {
        // 7D data but nothing in the 5H window → agent idle → meter is
        // clutter (and misses any spend happening off this machine)
        let tokens = AgentTokenDisplay(
            sevenDay: TokenUsageTotals(inputTokens: 50_000)
        )
        XCTAssertFalse(tokens.hasRecentActivity)
    }

    func testCompactResetTimeUsesSingleUnit() {
        // Tooltip variant: whole single unit so "2h · 5h" stays as short
        // as "API · 7d"
        XCTAssertEqual(UsageFormat.resetTimeCompact(Date(timeIntervalSinceNow: 2.2 * 3600)), "2h")
        XCTAssertEqual(UsageFormat.resetTimeCompact(Date(timeIntervalSinceNow: 1.6 * 3600)), "2h")
        XCTAssertEqual(UsageFormat.resetTimeCompact(Date(timeIntervalSinceNow: 45 * 60 + 30)), "45m")
        XCTAssertEqual(UsageFormat.resetTimeCompact(Date(timeIntervalSinceNow: -10)), "now")
    }

    func testTokenSummaryPrefersCostWhenAvailable() {
        // Summary detail text: spend figure when priced, token count fallback
        let tokens = AgentTokenDisplay(
            sevenDay: TokenUsageTotals(inputTokens: 1_200_000, outputTokens: 40_000),
            estimatedCostUSD: 4.80
        )
        XCTAssertEqual(UsageFormat.tokenSummary(tokens), "~$4.80")

        let unpriced = AgentTokenDisplay(
            sevenDay: TokenUsageTotals(inputTokens: 1_200_000, outputTokens: 40_000)
        )
        XCTAssertEqual(UsageFormat.tokenSummary(unpriced), "1.2M tok")
    }
}
