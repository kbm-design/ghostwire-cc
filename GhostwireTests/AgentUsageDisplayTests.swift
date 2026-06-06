//
//  AgentUsageDisplayTests.swift
//  GhostwireTests
//
//  GW-151: auth-branched display-mode selection. Quota mode requires BOTH
//  signals (latest rate_limits non-null AND auth.json not apikey) - the
//  issue's "corroborate" rule. auth.json flips immediately on login changes;
//  rollout events can lag up to 7 days.
//

import XCTest
@testable import Ghostwire

final class AgentUsageDisplayTests: XCTestCase {

    private let limits = AgentRateLimits(
        fiveHour: QuotaPeriod(utilization: 36.0, resetsAt: nil),
        sevenDay: QuotaPeriod(utilization: 8.0, resetsAt: nil)
    )

    private func tokenSnapshot(rateLimits: AgentRateLimits? = nil) -> CodexUsageSnapshot {
        CodexUsageSnapshot(
            rateLimits: rateLimits,
            tokens: TokenUsageTotals(inputTokens: 1_000_000, cachedInputTokens: 800_000, outputTokens: 50_000),
            tokensByModel: ["gpt-5.5": TokenUsageTotals(inputTokens: 1_000_000, cachedInputTokens: 800_000, outputTokens: 50_000)],
            lastContextUsed: 147_488,
            modelContextWindow: 258_400
        )
    }

    func testSubscriptionAuthWithRateLimitsYieldsQuota() {
        let display = CodexUsageService.makeDisplay(snapshot: tokenSnapshot(rateLimits: limits), authMode: "chatgpt")

        guard case .quota(let fiveHour, let sevenDay, _, _) = display else {
            return XCTFail("expected quota mode, got \(String(describing: display))")
        }
        XCTAssertEqual(fiveHour?.utilization, 36.0)
        XCTAssertEqual(sevenDay?.utilization, 8.0)
    }

    func testApiKeyAuthYieldsTokensEvenWithStaleRateLimits() {
        // auth.json says apikey → stale subscription events must not win
        let display = CodexUsageService.makeDisplay(snapshot: tokenSnapshot(rateLimits: limits), authMode: "apikey")

        guard case .tokens(let tokens) = display else {
            return XCTFail("expected token mode, got \(String(describing: display))")
        }
        XCTAssertEqual(tokens.sevenDay.inputTokens, 1_000_000)
    }

    func testNullRateLimitsYieldsTokensRegardlessOfAuthMode() {
        let display = CodexUsageService.makeDisplay(snapshot: tokenSnapshot(), authMode: "chatgpt")

        guard case .tokens = display else {
            return XCTFail("expected token mode, got \(String(describing: display))")
        }
    }

    func testTokenDisplayCarriesCostAndContext() {
        let display = CodexUsageService.makeDisplay(snapshot: tokenSnapshot(), authMode: "apikey")

        guard case .tokens(let tokens) = display else {
            return XCTFail("expected token mode")
        }
        // (1M-0.8M)*$5 + 0.8M*$0.50 + 0.05M*$30 = 1.00 + 0.40 + 1.50 = $2.90
        XCTAssertEqual(tokens.estimatedCostUSD ?? -1, 2.90, accuracy: 0.001)
        XCTAssertEqual(tokens.contextUsed, 147_488)
        XCTAssertEqual(tokens.contextWindow, 258_400)
    }

    func testEmptySnapshotYieldsNil() {
        XCTAssertNil(CodexUsageService.makeDisplay(snapshot: CodexUsageSnapshot(), authMode: "apikey"))
    }
}
