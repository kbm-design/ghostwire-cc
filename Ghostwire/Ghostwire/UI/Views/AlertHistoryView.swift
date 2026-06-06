//
//  AlertHistoryView.swift
//  Ghostwire
//
//  GW-207: the "recent alerts" history, rendered as a TRAILING SECTION at the
//  bottom of the active-chats list (ClaudeInstancesView). One feed: live
//  session rows first, history below the fold — reachable only by scrolling
//  past the present into the past. The quick view spends zero pixels on it.
//
//  Renders AlertHistoryStore (GW-144) — the governed, capped store of the
//  permission/ready alerts the app actually raised. Read-only viewer with a
//  small/quiet Clear. House style: identity tint encodes WHICH agent, an
//  outcome glyph encodes how it resolved, no name pills, no title+badge stacks.
//  One code path for Claude / Codex / any future agent — gated on the
//  AgentIdentity tint, never agent-name strings.
//

import SwiftUI

/// Trailing history section: a quiet "Recent alerts" caption divider + the
/// newest-first one-line rows + a small Clear. Embedded inside the instances
/// scroll, so it only appears once you scroll past the live rows. Renders
/// nothing when there are no alerts (the home stays quiet).
struct AlertHistorySection: View {
    @ObservedObject private var store = AlertHistoryStore.shared

    /// Newest first — the store keeps oldest-first for pruning.
    private var alerts: [AgentAlert] {
        store.alerts.reversed()
    }

    var body: some View {
        if !alerts.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                sectionHeader
                ForEach(alerts) { alert in
                    AlertHistoryRow(alert: alert)
                }
            }
            .padding(.top, 6)
        }
    }

    /// Quiet divider: a "Recent alerts" caption with the small Clear trailing.
    private var sectionHeader: some View {
        HStack(spacing: 6) {
            Text("Recent alerts")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            Button(action: { store.clear() }) {
                Text("Clear")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove all recorded alerts")
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }
}

// MARK: - Row

/// One recorded alert, one line (GW-207): identity tint dot (which agent) +
/// folder + permission command/outcome glyph OR ready "user responded" +
/// relative time. No agent-name pill, no title+badge stack.
private struct AlertHistoryRow: View {
    let alert: AgentAlert

    @State private var isHovered = false

    private var tint: Color {
        AgentIdentity.tint(for: alert.agent)
    }

    /// Outcome glyph + color for permission alerts. nil outcome → nothing
    /// (unanswered is the absence state, not a glyph).
    private var outcomeGlyph: (symbol: String, color: Color)? {
        switch alert.outcome {
        case "allowed": return ("checkmark", TerminalColors.green)
        case "denied": return ("xmark", TerminalColors.red)
        case "timedOut": return ("timer", .white.opacity(0.4))
        default: return nil
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Identity dot (which agent) — tint over a name pill (house style).
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)

            // folder
            if let folder = alert.folder, !folder.isEmpty {
                Text(folder)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // permission: the command (truncated inline is fine — history, not
            // the approval surface). ready: "user responded" or nothing.
            if alert.kind == "permission" {
                if let command = alert.command, !command.isEmpty {
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    // Pre-v2 rows carried only the tool name in `detail`;
                    // without this they'd render as a bare dot + timestamp.
                    Text(alert.detail ?? "Approval")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let glyph = outcomeGlyph {
                    Image(systemName: glyph.symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(glyph.color)
                }
            } else if alert.kind == "ready" {
                if alert.outcome == "responded" {
                    Text("user responded")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if alert.folder == nil {
                    // Pre-v2 ready rows have no folder either - keep a label.
                    Text("Ready")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            // relative time of the alert itself
            Text(Self.relativeFormatter.localizedString(for: alert.date, relativeTo: Date()))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .layoutPriority(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.white.opacity(0.05) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
