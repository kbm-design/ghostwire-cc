//
//  AlertHistoryView.swift
//  Ghostwire
//
//  GW-208: the "recent alerts" history, reached via a single compact access
//  row at the END of the active-chats list (ClaudeInstancesView) — clock glyph
//  + count + chevron, quiet styling. Tapping it swaps the full history view
//  into AgentsTabView's homeContent (the AgentUsageDetailView idiom: a
//  back-chevron header, no new window). The quick view spends zero pixels on
//  the list itself.
//
//  Renders AlertHistoryStore (GW-144) — the governed, capped store of the
//  permission/ready alerts the app actually raised. Read-only viewer with a
//  small/quiet Clear. House style: identity tint encodes WHICH agent, an
//  outcome glyph encodes how it resolved, no name pills, no title+badge stacks.
//  One code path for Claude / Codex / any future agent — gated on the
//  AgentIdentity tint, never agent-name strings.
//

import SwiftUI

/// Full "Recent alerts" view, swapped into homeContent when the access row is
/// tapped (AgentUsageDetailView-style detail toggle): back-chevron header +
/// Clear, then the newest-first rich one-line rows.
struct AlertHistoryView: View {
    @ObservedObject private var store = AlertHistoryStore.shared
    let onBack: () -> Void

    /// Newest first — the store keeps oldest-first for pruning.
    private var alerts: [AgentAlert] {
        store.alerts.reversed()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(alerts) { alert in
                        AlertHistoryRow(alert: alert)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
    }

    /// Back chevron + "Recent alerts" + a small Clear (matches the
    /// AgentUsageDetailView header idiom; Clear trails as the lone action).
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
            .help("Back to Agents")

            Spacer()

            Button(action: { store.clear() }) {
                Text("Clear")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove all recorded alerts")
        }
    }
}

/// Compact end-of-list access row: clock glyph + "Recent alerts" + count +
/// chevron, quiet styling. Lives at the bottom of the instances list; tapping
/// it opens the full AlertHistoryView. Renders nothing when there are no
/// alerts (the home stays quiet).
struct AlertHistoryAccessRow: View {
    @ObservedObject private var store = AlertHistoryStore.shared
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        if !store.alerts.isEmpty {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tertiary)

                    Text("Recent alerts")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    Text("\(store.alerts.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Spacer(minLength: 4)

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Color.white.opacity(0.05) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .padding(.top, 6)
        }
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
        // GW-408: Ghostwire blocked it — not the user's call, so it must not
        // wear the same glyph as a denial they made.
        case "blocked": return ("exclamationmark.octagon", TerminalColors.red)
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
