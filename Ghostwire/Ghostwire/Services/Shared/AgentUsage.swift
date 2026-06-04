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

/// GW-203: single owner of the agent-activity window. "Has this machine used
/// the agent recently enough that its locally-derived meter is still live?"
/// 5h aligns with the GW-199 idle threshold and the meter's 5H bucket. The
/// constant lived in three places before (IdleStateRule/SessionDiscovery
/// maxAge, the Codex meter visibility check's literal 5*3600, and the
/// ClaudeTokenUsageParser 5H window) - this is the one definition.
enum AgentActivity {
    static let window: TimeInterval = 5 * 3600

    /// Activity at `date` counts as recent if it falls within `window` of `now`.
    static func isRecent(_ date: Date?, now: Date = Date()) -> Bool {
        guard let date else { return false }
        return now.timeIntervalSince(date) < window
    }
}

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

/// A per-model weekly sub-limit (e.g. Opus/Sonnet on the Claude OAuth plan).
/// GW-203: rides the display enum so the UI never reaches past it for the
/// data (was a Claude-only side channel via UsageService.usage in GW-201).
struct PerModelQuota: Equatable {
    let label: String
    let period: QuotaPeriod
}

/// What an agent's meter renders - the auth-branched display mode.
/// Subscription/OAuth → .quota; API key → .tokens. One shape for every
/// agent so AgentsTabView renders agent-agnostic (parity rule).
///
/// GW-203: .quota carries ALL its data (5H/7D + per-model weeklies + server
/// extra-usage spend). The UI gates on the enum mode, never on agent name -
/// when GW-200 gives Codex server quota it populates the same fields here.
enum AgentUsageDisplay: Equatable {
    case quota(
        fiveHour: QuotaPeriod?,
        sevenDay: QuotaPeriod?,
        perModel: [PerModelQuota] = [],
        extra: ExtraUsage? = nil
    )
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

    /// Freshness rule (GW-151): locally-derived meters age out after the
    /// AgentActivity.window of inactivity. Token activity in that 5H bucket
    /// (populated by the parser using AgentActivity.window) proves this
    /// machine is using the agent.
    var hasRecentActivity: Bool {
        fiveHour != .zero
    }
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
    /// GW-203: timestamp of the newest token_count event across all sessions
    /// in the window - the activity signal for meter freshness. Yielded from
    /// the snapshot scan that already visits every event, so CodexUsageService
    /// no longer needs a second mtime-walk of the rollout tree.
    var latestActivity: Date?

    var hasData: Bool {
        rateLimits != nil || tokens != .zero
    }
}
