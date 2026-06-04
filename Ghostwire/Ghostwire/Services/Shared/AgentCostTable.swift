//
//  AgentCostTable.swift
//  Ghostwire
//
//  GW-151: static $/MTok price table for the API-key meter mode. Costs are
//  ESTIMATES - flag them as such in UI ("~$4.80").
//
//  Prices verified 2026-06-04 from the providers' live pricing pages:
//  - https://developers.openai.com/api/docs/pricing
//  - https://platform.claude.com/docs/en/about-claude/pricing
//
//  The providers ACCOUNT cached tokens differently:
//  - OpenAI: cached_input_tokens is a SUBSET of input_tokens; reasoning
//    tokens are billed inside output_tokens (reasoning_output_tokens is
//    informational only).
//  - Claude: cache_read / cache_creation are DISJOINT from input_tokens.
//    Cache writes priced at the 5-minute rate (1h writes cost 2x base -
//    accepting slight underestimation rather than parsing the breakdown).
//

import Foundation

enum AgentCostTable {

    private enum CacheAccounting {
        /// cached ⊂ input (OpenAI): cost = (input - cached)·in + cached·read + out·out
        case cachedSubsetOfInput
        /// cache fields disjoint (Claude): cost = in·in + read·read + write·write + out·out
        case cacheDisjoint
    }

    private struct ModelRates {
        /// $/MTok
        let input: Double
        let cachedRead: Double
        let cacheWrite: Double
        let output: Double
        let accounting: CacheAccounting
    }

    /// Keyed by model-id prefix - transcripts carry dated ids
    /// (claude-haiku-4-5-20251001), so lookup is longest-prefix.
    private static let rates: [String: ModelRates] = [
        // OpenAI (cacheWrite n/a → 0)
        "gpt-5.5-pro":  .init(input: 30.00, cachedRead: 0,     cacheWrite: 0, output: 180.00, accounting: .cachedSubsetOfInput),
        "gpt-5.5":      .init(input: 5.00,  cachedRead: 0.50,  cacheWrite: 0, output: 30.00,  accounting: .cachedSubsetOfInput),
        "gpt-5.4-pro":  .init(input: 30.00, cachedRead: 0,     cacheWrite: 0, output: 180.00, accounting: .cachedSubsetOfInput),
        "gpt-5.4-mini": .init(input: 0.75,  cachedRead: 0.075, cacheWrite: 0, output: 4.50,   accounting: .cachedSubsetOfInput),
        "gpt-5.4-nano": .init(input: 0.20,  cachedRead: 0.02,  cacheWrite: 0, output: 1.25,   accounting: .cachedSubsetOfInput),
        "gpt-5.4":      .init(input: 2.50,  cachedRead: 0.25,  cacheWrite: 0, output: 15.00,  accounting: .cachedSubsetOfInput),
        // Anthropic
        "claude-opus-4-8":   .init(input: 5.00, cachedRead: 0.50, cacheWrite: 6.25, output: 25.00, accounting: .cacheDisjoint),
        "claude-opus-4-7":   .init(input: 5.00, cachedRead: 0.50, cacheWrite: 6.25, output: 25.00, accounting: .cacheDisjoint),
        "claude-opus-4-6":   .init(input: 5.00, cachedRead: 0.50, cacheWrite: 6.25, output: 25.00, accounting: .cacheDisjoint),
        "claude-opus-4-5":   .init(input: 5.00, cachedRead: 0.50, cacheWrite: 6.25, output: 25.00, accounting: .cacheDisjoint),
        "claude-sonnet-4-6": .init(input: 3.00, cachedRead: 0.30, cacheWrite: 3.75, output: 15.00, accounting: .cacheDisjoint),
        "claude-sonnet-4-5": .init(input: 3.00, cachedRead: 0.30, cacheWrite: 3.75, output: 15.00, accounting: .cacheDisjoint),
        "claude-haiku-4-5":  .init(input: 1.00, cachedRead: 0.10, cacheWrite: 1.25, output: 5.00,  accounting: .cacheDisjoint)
    ]

    /// Estimated USD cost for per-model token totals. Nil when no model is
    /// priced (unknown models contribute nothing).
    static func estimateUSD(tokensByModel: [String: TokenUsageTotals]) -> Double? {
        var total: Double?

        for (model, totals) in tokensByModel {
            guard let modelRates = lookup(model) else { continue }

            let perM = 1_000_000.0
            var cost = Double(totals.outputTokens) / perM * modelRates.output

            switch modelRates.accounting {
            case .cachedSubsetOfInput:
                let uncached = max(0, totals.inputTokens - totals.cachedInputTokens)
                cost += Double(uncached) / perM * modelRates.input
                cost += Double(totals.cachedInputTokens) / perM * modelRates.cachedRead
            case .cacheDisjoint:
                cost += Double(totals.inputTokens) / perM * modelRates.input
                cost += Double(totals.cachedInputTokens) / perM * modelRates.cachedRead
                cost += Double(totals.cacheCreationInputTokens) / perM * modelRates.cacheWrite
            }

            total = (total ?? 0) + cost
        }

        return total
    }

    private static func lookup(_ model: String) -> ModelRates? {
        // Longest prefix wins so "gpt-5.4-mini" doesn't resolve to "gpt-5.4"
        rates
            .filter { model.hasPrefix($0.key) }
            .max { $0.key.count < $1.key.count }?
            .value
    }
}
