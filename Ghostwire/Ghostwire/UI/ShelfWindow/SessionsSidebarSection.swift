//
//  SessionsSidebarSection.swift
//  Ghostwire
//
//  Live sessions at the top of the window sidebar. The window used to open on a
//  static "Agents" nav row; the sessions themselves are the destination, so they
//  ARE the row now — click one and the Agents pane opens on its chat.
//
//  Row anatomy, left to right, every element in a fixed-width lane so the
//  columns line up across rows:
//
//    [state] [agent] repo-name ......... 4m
//
//  State is a dot, and it is deliberately the LEFTMOST thing: "does this need
//  me" is the only question the sidebar has to answer at a glance. It is absent
//  — not grey, absent — when a session wants nothing, so a dot anywhere in the
//  column means something. The agent mark carries identity (which agent), never
//  state, per AgentIdentity's rule: color = who, motion/icon = what.
//

import SwiftUI

// MARK: - Ordering

/// Shared session ordering. `ClaudeInstancesView` renders the same sessions in
/// the notch and must agree with the sidebar — two sort implementations would
/// drift into two different "top" sessions for the same machine.
enum SessionOrdering {
    /// Priority: needs-you / working > finished-and-waiting > idle. Secondary by
    /// last user message (stable: it doesn't move when the agent replies).
    static func sorted(_ sessions: [SessionState]) -> [SessionState] {
        sessions.sorted { a, b in
            let pa = priority(a.phase), pb = priority(b.phase)
            if pa != pb { return pa < pb }
            let dateA = a.conversationInfo.lastUserMessageDate ?? a.lastActivity
            let dateB = b.conversationInfo.lastUserMessageDate ?? b.lastActivity
            return dateA > dateB
        }
    }

    /// Lower = higher. Approval shares priority with processing so a request
    /// arriving doesn't yank the row to the top and move what you were reading.
    static func priority(_ phase: SessionPhase) -> Int {
        switch phase {
        case .waitingForApproval, .processing, .compacting: return 0
        case .waitingForInput: return 1
        case .idle, .ended: return 2
        }
    }
}

// MARK: - Section

struct SessionsSidebarSection: View {
    /// How many stay exposed; the rest fold behind one row.
    static let exposedCount = 5

    @ObservedObject private var bridge = GhostwireSessionBridge.shared
    let onOpen: (SessionState) -> Void
    /// Highlighted row — the session the Agents pane is currently showing.
    let selectedSessionID: String?

    @State private var showingAll = false

    private var sessions: [SessionState] {
        SessionOrdering.sorted(bridge.sessionMonitor.instances)
    }

    private var visible: [SessionState] {
        showingAll ? sessions : Array(sessions.prefix(Self.exposedCount))
    }

    private var hiddenCount: Int {
        max(0, sessions.count - Self.exposedCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            header

            if sessions.isEmpty {
                emptyState
            } else {
                // Re-renders the relative times without each row owning a timer.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(visible) { session in
                            SessionSidebarRow(
                                session: session,
                                now: context.date,
                                isSelected: session.sessionId == selectedSessionID
                            ) {
                                onOpen(session)
                            }
                        }
                    }
                }

                if hiddenCount > 0 {
                    moreRow
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Sessions")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Color.white.opacity(0.4))
            Spacer(minLength: 0)
        }
        .frame(height: 28)
        .padding(.horizontal, 10)
    }

    private var emptyState: some View {
        Text("No sessions")
            .font(.system(size: 12))
            .foregroundStyle(Color.white.opacity(0.35))
            .frame(height: 30)
            .padding(.horizontal, 10)
    }

    private var moreRow: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { showingAll.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(showingAll ? 180 : 0))
                    .frame(width: 20)
                Text(showingAll ? "Show fewer" : "\(hiddenCount) earlier session\(hiddenCount == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.white.opacity(0.4))
            .frame(height: 30)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Row

private struct SessionSidebarRow: View {
    let session: SessionState
    let now: Date
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                // Fixed lane, occupied only when the session wants something.
                Group {
                    if let color = stateColor {
                        Circle().fill(color).frame(width: 6, height: 6)
                    }
                }
                .frame(width: 8)

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AgentIdentity.tint(for: session.agent).opacity(0.18))
                    .frame(width: 20, height: 20)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(AgentIdentity.tint(for: session.agent))
                            .frame(width: 8, height: 8)
                    )

                Text(session.projectName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(Color.white.opacity(isSelected ? 0.92 : 0.82))

                Spacer(minLength: 4)

                Text(Self.relativeTime(from: session.lastActivity, to: now))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.4))
                    .layoutPriority(1)
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.09) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(session.cwd)
    }

    /// nil = wants nothing. Amber = your turn, green = working.
    private var stateColor: Color? {
        switch session.phase {
        case .waitingForApproval, .waitingForInput: return .orange
        case .processing, .compacting: return .green
        case .idle, .ended: return nil
        }
    }

    /// Compact enough for a 224pt sidebar: "now", "4m", "3h", "2d".
    static func relativeTime(from date: Date, to now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }
}
