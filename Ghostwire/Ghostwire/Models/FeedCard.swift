//
//  FeedCard.swift
//  Ghostwire
//
//  GW-259. The card-rendering layer's content model. A `Source` (app | mcp | api)
//  turns its items into `FeedCard`s; the tabbed surface renders them. The card
//  layer never knows which backend produced a card — that's the clean seam
//  (MCP-vs-REST stays hidden inside the Source).
//
//  Kinds are FORMAT-driven, not source-driven: flexible artifacts (text / data /
//  list) that work for broad content, plus a `.generic` fallback so nothing is
//  ever blocked on a template existing. Source-specific shapes (a crypto ticker,
//  a Linear ticket) map onto these formats rather than each minting their own kind.
//

import Foundation

/// One rendered item in a feed. Ranking-agnostic: no order/score field, so GW-182
/// context ranking can sort a `[FeedCard]` later with no model change.
struct FeedCard: Identifiable, Equatable, Sendable {
    /// Stable within a Source (a Source reuses the id across refreshes so a card
    /// updates in place rather than churning).
    let id: String
    /// Which Source emitted this — opaque to the card layer.
    let sourceId: String
    /// Bundle id for the attribution glyph (GW-221 resolver). Nil → kind glyph.
    let sourceApp: String?
    let kind: FeedCardKind
    /// Last time the Source refreshed this card's value. Drives staleness/dim.
    let updatedAt: Date
    /// Optional deep link — when set, the card offers an "open" affordance
    /// (e.g. a ticket card opens its Linear URL). Click is the only non-copy/send
    /// action this layer exposes; there is no app-control here.
    let link: URL?

    init(
        id: String,
        sourceId: String,
        sourceApp: String? = nil,
        kind: FeedCardKind,
        updatedAt: Date,
        link: URL? = nil
    ) {
        self.id = id
        self.sourceId = sourceId
        self.sourceApp = sourceApp
        self.kind = kind
        self.updatedAt = updatedAt
        self.link = link
    }
}

/// Format-driven card shapes. Extensible: a new format (e.g. `.keyValue`, `.chart`)
/// drops in here + one dispatcher case, without touching the existing renderers.
enum FeedCardKind: Equatable, Sendable {
    /// A prose / snippet card — title over body text.
    case text(title: String, body: String)
    /// A single data point — a big value with a label and optional signed delta
    /// (covers a stat, a count, a price, etc.).
    case data(label: String, value: String, delta: String?)
    /// A short list of rows under a heading (search results, multiple tickets…).
    case list(title: String, items: [String])
    /// Universal fallback — title + optional subtitle + optional trailing value.
    /// Any Source with no better-fitting format renders here.
    case generic(title: String, subtitle: String?, value: String?)
}

extension FeedCard {
    /// Plain-text representation used by the Copy and Send-to-agent actions — the
    /// card's content flattened to text the same way regardless of kind.
    var plainText: String {
        switch kind {
        case let .text(title, body):
            return [title, body]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        case let .data(label, value, delta):
            let head = "\(label): \(value)"
            return delta.map { "\(head) (\($0))" } ?? head
        case let .list(title, items):
            let rows = items.map { "- \($0)" }.joined(separator: "\n")
            return title.isEmpty ? rows : "\(title)\n\(rows)"
        case let .generic(title, subtitle, value):
            return [title, subtitle, value]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    /// Whether this card's value is stale and should be dimmed. Mirrors the
    /// usage-meter freshness check (`AgentActivity.isRecent`): a card goes stale
    /// once it hasn't refreshed within `tolerance ×` its Source's `refreshInterval`.
    /// The Source owns the interval; the card layer just renders the verdict.
    func isStale(refreshInterval: TimeInterval, tolerance: Double = 2, now: Date = Date()) -> Bool {
        guard refreshInterval > 0 else { return false }
        return now.timeIntervalSince(updatedAt) > refreshInterval * tolerance
    }
}
