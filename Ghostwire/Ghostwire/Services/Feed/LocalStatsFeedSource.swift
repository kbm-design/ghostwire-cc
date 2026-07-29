//
//  LocalStatsFeedSource.swift
//  Ghostwire
//
//  GW-261. Numbers Ghostwire already knows, surfaced as cards: agent quota and
//  live agent activity. No network, no auth, no permission — the data is
//  in-process already, so these cards work on a machine that has connected
//  nothing at all.
//
//  Each card follows the feed rule: one question answered at a glance ("how
//  much quota is left", "is anything waiting on me"), and nothing shown that
//  the user can't act on from the notch they're already looking at.
//
//  Cards are OMITTED, not zeroed, when their data isn't there: no Claude auth
//  means no quota card, rather than a card confidently reading 0%.
//

import Foundation

struct LocalStatsFeedSource: FeedSource {
    let id = "local.stats"
    let displayName = "Ghostwire activity"
    /// Local reads are free, but the values only move as fast as the agents do.
    let refreshInterval: TimeInterval = 30

    /// GW-182. Quota and agent status are about work in progress — they matter
    /// in an editor or a terminal and are noise in a music player.
    let affinity: [AppCategory: Double] = [.coding: 1.0]

    func fetch() async throws -> [FeedCard] {
        let now = Date()
        var cards: [FeedCard] = []
        if let quota = await Self.quotaCard(sourceId: id, now: now) { cards.append(quota) }
        if let agents = await Self.agentsCard(sourceId: id, now: now) { cards.append(agents) }
        return cards
    }

    /// Claude's 5-hour window — the number that actually governs whether you can
    /// keep working. Omitted entirely when usage is unavailable (not signed in,
    /// or never fetched).
    @MainActor
    static func quotaCard(sourceId: String, now: Date) -> FeedCard? {
        let service = UsageService.shared
        guard service.isAvailable, let fiveHour = service.usage.fiveHour else { return nil }
        return FeedCard(
            id: "\(sourceId).quota",
            sourceId: sourceId,
            kind: .data(
                label: "Claude · 5h used",
                value: "\(Int(fiveHour.utilization.rounded()))%",
                delta: fiveHour.resetsAt.map { "resets \(Self.relative.localizedString(for: $0, relativeTo: now))" }
            ),
            updatedAt: now,
            // GW-182: near the ceiling, the number stops being trivia and starts
            // governing whether the user can keep working — worth the notch.
            urgency: fiveHour.utilization >= Self.quotaAttentionThreshold ? .attention : .info
        )
    }

    /// Percent of the 5-hour window at which quota becomes worth surfacing.
    static let quotaAttentionThreshold: Double = 90

    /// Live agent sessions, with the count that actually demands action —
    /// how many are blocked waiting for an approval — as the secondary line.
    static func agentsCard(sourceId: String, now: Date) async -> FeedCard? {
        let sessions = await SessionStore.shared.allSessions()
        let live = sessions.filter { if case .ended = $0.phase { return false } else { return true } }
        guard !live.isEmpty else { return nil }

        let waiting = live.filter { if case .waitingForApproval = $0.phase { return true } else { return false } }.count
        return FeedCard(
            id: "\(sourceId).agents",
            sourceId: sourceId,
            kind: .data(
                label: "Agents running",
                value: "\(live.count)",
                // Unsigned, so the card renders it neutral rather than red/green.
                delta: waiting > 0 ? "\(waiting) waiting on you" : nil
            ),
            updatedAt: now,
            // GW-182: a blocked agent is the one thing in the feed that is
            // literally waiting on the user. This is the Tier-A signal the
            // ranker leans on hardest, and it needs no ambient capture at all.
            urgency: waiting > 0 ? .attention : .info
        )
    }

    nonisolated(unsafe) private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}
