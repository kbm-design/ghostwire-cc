//
//  AgentUsageDetailView.swift
//  Ghostwire
//
//  GW-151: per-agent usage detail - swapped into AgentsTabView's homeContent
//  when a summary bar is clicked (AgentPeek-style detail toggle, no new
//  window). Quota mode: 5H + 7D bars with reset/refill times. Token mode:
//  token breakdown + estimated cost + context-window gauge.
//

import SwiftUI

struct AgentUsageDetailView: View {
    /// "claude" | "codex"
    let agent: String
    let display: AgentUsageDisplay
    let onBack: () -> Void

    private var tint: Color { AgentIdentity.tint(for: agent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            switch display {
            case .quota(let fiveHour, let sevenDay):
                quotaDetail(fiveHour: fiveHour, sevenDay: sevenDay)
            case .tokens(let tokens):
                tokenDetail(tokens)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
    }

    private var header: some View {
        Button(action: onBack) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                Text(agent.prefix(1).uppercased() + agent.dropFirst())
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Quota mode

    private func quotaDetail(fiveHour: QuotaPeriod?, sevenDay: QuotaPeriod?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let fh = fiveHour {
                quotaBar(label: "Session", period: fh, resetPrefix: "resets")
            }
            if let sd = sevenDay {
                quotaBar(label: "Weekly", period: sd, resetPrefix: "refills")
            }
        }
    }

    private func quotaBar(label: String, period: QuotaPeriod, resetPrefix: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            UsageBar(
                label: label,
                percent: period.utilization / 100,
                detail: "\(Int(period.utilization))%",
                color: barColor(period.utilization)
            )
            if let resetsAt = period.resetsAt {
                Text("\(resetPrefix) \(UsageFormat.resetTime(resetsAt))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func barColor(_ utilization: Double) -> Color {
        utilization > 80 ? .red : utilization > 60 ? .yellow : tint
    }

    // MARK: - Token mode

    private func tokenDetail(_ tokens: AgentTokenDisplay) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let cost = tokens.estimatedCostUSD {
                tokenRow("Est. spend (7d)", UsageFormat.estimatedCost(cost), emphasized: true)
            }

            tokenRow("Input", UsageFormat.tokenCount(tokens.sevenDay.inputTokens))
            if tokens.sevenDay.cachedInputTokens > 0 {
                tokenRow("Cached", UsageFormat.tokenCount(tokens.sevenDay.cachedInputTokens))
            }
            if tokens.sevenDay.cacheCreationInputTokens > 0 {
                tokenRow("Cache write", UsageFormat.tokenCount(tokens.sevenDay.cacheCreationInputTokens))
            }
            tokenRow("Output", UsageFormat.tokenCount(tokens.sevenDay.outputTokens))
            if tokens.sevenDay.reasoningOutputTokens > 0 {
                tokenRow("Reasoning", UsageFormat.tokenCount(tokens.sevenDay.reasoningOutputTokens))
            }

            if let used = tokens.contextUsed, let window = tokens.contextWindow, window > 0 {
                UsageBar(
                    label: "Context",
                    percent: Double(used) / Double(window),
                    detail: "\(UsageFormat.tokenCount(used)) / \(UsageFormat.tokenCount(window))",
                    color: tint
                )
                .padding(.top, 4)
            }
        }
    }

    private func tokenRow(_ label: String, _ value: String, emphasized: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(emphasized ? .caption.weight(.semibold) : .caption)
                .foregroundStyle(emphasized ? .primary : .secondary)
        }
    }
}
