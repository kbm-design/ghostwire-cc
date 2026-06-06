//
//  AlertHistoryView.swift
//  Ghostwire
//
//  GW-139: the "recent terminal alerts" history list for the Agents tab.
//  Renders AlertHistoryStore (GW-144) — the governed, capped store of the
//  permission/ready alerts the app actually raised. Read-only viewer:
//  identity tint encodes WHICH agent, a glyph encodes the alert kind, and
//  the relative time encodes WHEN. One code path for Claude / Codex / any
//  future agent — gated on the AgentIdentity tint, never agent-name strings.
//
//  Swapped into AgentsTabView's homeContent like AgentUsageDetailView
//  (AgentPeek-style detail toggle, no new window).
//

import SwiftUI

struct AlertHistoryView: View {
    @ObservedObject private var store = AlertHistoryStore.shared
    let onBack: () -> Void

    /// Newest first — the store keeps oldest-first for pruning.
    private var alerts: [AgentAlert] {
        store.alerts.reversed()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if alerts.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(alerts) { alert in
                            AlertHistoryRow(alert: alert)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Recent alerts")
                        .font(.subheadline.weight(.medium))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            if !alerts.isEmpty {
                Button(action: { store.clear() }) {
                    Text("Clear")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove all recorded alerts")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell.slash")
                .font(.system(size: 22))
                .foregroundColor(.white.opacity(0.2))
            Text("No alerts yet")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Permission and ready-for-input alerts appear here.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

/// One recorded alert: identity tint (which agent) + kind glyph (what) +
/// optional detail (the pending tool) + relative time (when). No agent-name
/// label — the tint carries identity, matching the session-row badge (GW-138).
private struct AlertHistoryRow: View {
    let alert: AgentAlert

    @State private var isHovered = false

    private var tint: Color {
        AgentIdentity.tint(for: alert.agent)
    }

    /// "permission" → amber gate glyph; "ready" → green ready glyph; else dot.
    private var kindGlyph: String {
        switch alert.kind {
        case "permission": return "hand.raised"
        case "ready": return "bell"
        default: return "circle.fill"
        }
    }

    private var kindColor: Color {
        switch alert.kind {
        case "permission": return TerminalColors.amber
        case "ready": return TerminalColors.green
        default: return .white.opacity(0.5)
        }
    }

    /// Short human description of the alert kind (forward-compat: unknown
    /// kinds render their raw string rather than vanishing).
    private var kindLabel: String {
        switch alert.kind {
        case "permission": return "Approval"
        case "ready": return "Ready"
        default: return alert.kind.capitalized
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Identity dot (which agent) layered behind the kind glyph (what).
            ZStack {
                Circle()
                    .fill(tint.opacity(0.18))
                    .frame(width: 22, height: 22)
                Image(systemName: kindGlyph)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(kindColor)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(kindLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                    if let detail = alert.detail, !detail.isEmpty {
                        Text(MCPToolFormatter.formatToolName(detail))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(Self.relativeFormatter.localizedString(for: alert.date, relativeTo: Date()))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            // Identity tick on the trailing edge — same tint cue as the
            // session-row badge, so the agent reads at a glance.
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
                .opacity(0.8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
