//
//  AgentUsage.swift
//  Ghostwire
//
//  GW-151: shared usage-meter model. Each agent's meter is auth-branched:
//  subscription/OAuth → quota % (5H/7D windows), API key → token totals
//  (+ estimated cost). Never summed across agents - separate billing
//  universes.
//

import Foundation

/// Cumulative token totals (Codex: total_token_usage shape; Claude: usage{}).
struct TokenUsageTotals: Equatable, Codable {
    var inputTokens: Int = 0
    /// Codex: cached_input_tokens; Claude: cache_read_input_tokens
    var cachedInputTokens: Int = 0
    /// Claude only: cache_creation_input_tokens (billed above input rate)
    var cacheCreationInputTokens: Int = 0
    var outputTokens: Int = 0
    /// Codex only: reasoning_output_tokens
    var reasoningOutputTokens: Int = 0

    static let zero = TokenUsageTotals()

    static func += (lhs: inout TokenUsageTotals, rhs: TokenUsageTotals) {
        lhs.inputTokens += rhs.inputTokens
        lhs.cachedInputTokens += rhs.cachedInputTokens
        lhs.cacheCreationInputTokens += rhs.cacheCreationInputTokens
        lhs.outputTokens += rhs.outputTokens
        lhs.reasoningOutputTokens += rhs.reasoningOutputTokens
    }
}

/// 5H/7D rate-limit windows as reported by the agent (Codex: rate_limits
/// primary/secondary on token_count events; Claude: OAuth usage endpoint).
struct AgentRateLimits: Equatable, Codable {
    var fiveHour: QuotaPeriod?
    var sevenDay: QuotaPeriod?
}

/// What an agent's meter renders - the auth-branched display mode.
/// Subscription/OAuth → .quota; API key → .tokens. One shape for every
/// agent so BuddyTabView renders agent-agnostic (parity rule).
enum AgentUsageDisplay: Equatable {
    case quota(fiveHour: QuotaPeriod?, sevenDay: QuotaPeriod?)
    case tokens(AgentTokenDisplay)
}

/// Token-mode payload: window totals + estimated cost + context gauge.
struct AgentTokenDisplay: Equatable {
    /// 5H-window totals (zero when the source only has session granularity)
    var fiveHour: TokenUsageTotals = .zero
    var sevenDay: TokenUsageTotals = .zero
    /// From AgentCostTable - an estimate, render with "~"
    var estimatedCostUSD: Double?
    var contextUsed: Int?
    var contextWindow: Int?
}

/// One agent's parsed usage state for a polling window.
struct CodexUsageSnapshot: Equatable, Codable {
    /// Non-nil only when the LATEST token_count carried rate_limits
    /// (ChatGPT-subscription auth) → quota mode. Nil → token mode.
    var rateLimits: AgentRateLimits?
    /// Tokens summed across sessions in the window (latest cumulative
    /// total per session - totals grow within a session).
    var tokens: TokenUsageTotals = .zero
    /// Same totals attributed per model (for cost estimation).
    var tokensByModel: [String: TokenUsageTotals] = [:]
    /// last_token_usage.total of the latest event → context gauge numerator.
    var lastContextUsed: Int?
    /// model_context_window of the latest event → context gauge denominator.
    var modelContextWindow: Int?

    var hasData: Bool {
        rateLimits != nil || tokens != .zero
    }
}
