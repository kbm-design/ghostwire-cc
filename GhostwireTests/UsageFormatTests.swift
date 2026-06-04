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
