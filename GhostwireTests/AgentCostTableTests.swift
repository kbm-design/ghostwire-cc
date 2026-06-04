//
//  AgentCostTableTests.swift
//  GhostwireTests
//
//  GW-151: estimated API cost from token totals. Prices verified 2026-06-04:
//  developers.openai.com/api/docs/pricing + platform.claude.com/docs/en/
//  about-claude/pricing. The providers account cached tokens differently:
//  OpenAI cached_input is a SUBSET of input; Claude cache fields are
//  DISJOINT from input_tokens.
//

import XCTest
@testable import Ghostwire

final class AgentCostTableTests: XCTestCase {

    // MARK: - OpenAI semantics (cached ⊂ input)

    func testGpt55CostSubtractsCachedFromInput() {
        // 1M input (of which 0.5M cached), 0.1M output @ $5 / $0.50 / $30:
        // (1M-0.5M)*$5 + 0.5M*$0.50 + 0.1M*$30 = 2.50 + 0.25 + 3.00
        let totals = TokenUsageTotals(
            inputTokens: 1_000_000, cachedInputTokens: 500_000, outputTokens: 100_000
        )

        let cost = AgentCostTable.estimateUSD(tokensByModel: ["gpt-5.5": totals])

        XCTAssertEqual(cost ?? -1, 5.75, accuracy: 0.001)
    }

    func testReasoningTokensAreNotDoubleBilled() {
        // OpenAI bills reasoning as part of output_tokens; reasoning_output_
        // tokens is informational. 0.1M output incl. 0.04M reasoning = $3.00.
        let totals = TokenUsageTotals(
            inputTokens: 0, cachedInputTokens: 0,
            outputTokens: 100_000, reasoningOutputTokens: 40_000
        )

        let cost = AgentCostTable.estimateUSD(tokensByModel: ["gpt-5.5": totals])

        XCTAssertEqual(cost ?? -1, 3.0, accuracy: 0.001)
    }

    // MARK: - Claude semantics (cache fields disjoint)

    func testClaudeOpusCostAddsAllFourBuckets() {
        // 1M each @ opus-4-8: $5 in + $6.25 cache-write + $0.50 cache-read + $25 out
        let totals = TokenUsageTotals(
            inputTokens: 1_000_000, cachedInputTokens: 1_000_000,
            cacheCreationInputTokens: 1_000_000, outputTokens: 1_000_000
        )

        let cost = AgentCostTable.estimateUSD(tokensByModel: ["claude-opus-4-8": totals])

        XCTAssertEqual(cost ?? -1, 36.75, accuracy: 0.001)
    }

    func testDatedClaudeModelIdsMatchByPrefix() {
        // Transcripts carry dated ids like claude-haiku-4-5-20251001
        let totals = TokenUsageTotals(inputTokens: 1_000_000)

        let cost = AgentCostTable.estimateUSD(tokensByModel: ["claude-haiku-4-5-20251001": totals])

        XCTAssertEqual(cost ?? -1, 1.0, accuracy: 0.001)  // haiku-4-5: $1/MTok input
    }

    // MARK: - Unknown models

    func testUnknownModelYieldsNil() {
        let totals = TokenUsageTotals(inputTokens: 1_000_000)
        XCTAssertNil(AgentCostTable.estimateUSD(tokensByModel: ["mystery-model-9": totals]))
    }

    func testMixedKnownAndUnknownCountsKnownOnly() {
        let known = TokenUsageTotals(inputTokens: 1_000_000)   // haiku: $1
        let unknown = TokenUsageTotals(inputTokens: 99_000_000)

        let cost = AgentCostTable.estimateUSD(tokensByModel: [
            "claude-haiku-4-5": known,
            "mystery-model-9": unknown
        ])

        XCTAssertEqual(cost ?? -1, 1.0, accuracy: 0.001)
    }

    func testEmptyInputYieldsNil() {
        XCTAssertNil(AgentCostTable.estimateUSD(tokensByModel: [:]))
    }
}
