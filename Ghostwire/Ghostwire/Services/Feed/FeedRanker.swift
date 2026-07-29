//
//  FeedRanker.swift
//  Ghostwire
//
//  GW-182 — what the notch shows, given what the user is doing. Pure and
//  deterministic: cards + a `ContextProfile` in, a reordered `[FeedCard]` out.
//  No clock, no store, no I/O — the whole policy is exercisable in tests.
//
//  This RANKS but never CURATES. `FeedCardStore.orderedCards` remains the user's
//  order and the only thing `move()` persists; ranking is a derived view laid
//  over it for the notch's scarce top-N row (the window grid keeps user order).
//  That separation is deliberate: `setCards` deliberately does not persist —
//  writing a computed order back would recreate the GW-261 refresh-race bug,
//  where whichever Source won the network race froze at the top forever.
//
//  URGENCY IS A TIER, NOT A TERM. A card whose Source escalated it — an agent
//  blocked on an approval, quota about to run out — sorts above every card that
//  didn't, full stop. The architecture writes this as `critical ≫ attention >
//  info` and the `≫` is load-bearing: as a weighted term, a blocked agent could
//  lose to a merely topical card sitting high in the user's order, which is
//  exactly backwards. It also means the single most valuable behaviour here
//  needs no ambient capture at all, and can't be tuned away by weight drift.
//
//  Within a tier, three terms decide:
//
//   • context    — Source affinity · the user's category distribution (GW-172).
//   • novelty    — this card's content changed since the user last looked.
//   • user order — their curated position, as a prior rather than a rule.
//
//  BUT the context and novelty terms only exist at all under `.context` mode,
//  which is NOT the default. The shipped default (`.alerts`) computes neither:
//  the user's order holds, and the only card that can move is one that is
//  waiting on them — a promotion the card itself explains on its face. A feed
//  that rearranges for reasons the user can't see is worse than one that never
//  moves, and with a handful of cards there is almost nothing to arbitrate.
//
//  The gate is the CONFIDENCE FLOOR (the ticket's "wrong-but-confident is worse
//  than missing"): unless some card clears a real bar on urgency or context,
//  ranking returns the user's order untouched. Silence is a valid answer, and
//  it's the answer on a fresh install where nothing has affinity yet.
//
//  Stability is the other half of calm tech. `FeedCardRowView` animates on order
//  change, so a jittery score becomes motion in peripheral vision that means
//  nothing. Incumbency (below) makes the previous ranking sticky, so a card only
//  moves when it beats the incumbent by a margin — not when it edges past it.
//

import Foundation

enum FeedRanker {

    /// Term weights and the two thresholds. Defaults are the shipped policy;
    /// tests vary them to pin one term at a time.
    /// Weights apply WITHIN an urgency tier — urgency itself is not weighted
    /// (see the file header). Tests vary these to pin one term at a time.
    struct Weights: Equatable, Sendable {
        /// Affinity between the Source and the user's current context.
        var context: Double = 0.55
        /// Changed since they last looked.
        var novelty: Double = 0.20
        /// Their own curated position.
        var order: Double = 0.25
        /// Stickiness of the previous ranking. Doubles as the swap margin: a
        /// challenger must beat an incumbent by more than this to displace it.
        var incumbency: Double = 0.08
        /// Below this, ranking declines to have an opinion.
        var floor: Double = 0.25
        /// Multiplier on novelty when the user has just come back from away —
        /// "what changed while I was gone" is the whole question on return.
        var returnNoveltyBoost: Double = 2.0

        static let `default` = Weights()
    }

    /// Everything outside the card list that the score depends on.
    struct Inputs: Sendable {
        /// Derived from the ambient spine. `.empty` when capture is off.
        var profile: ContextProfile = .empty
        /// sourceId → declared category affinity.
        var affinities: [String: [AppCategory: Double]] = [:]
        /// cardId → when its CONTENT last changed (not when it last refreshed).
        var contentChangedAt: [String: Date] = [:]
        /// When the user last had a feed surface open. Nil → they haven't looked
        /// yet, so nothing counts as new to them.
        var lastViewedAt: Date?
        /// Card ids in the previously emitted ranking, best-first.
        var previousOrder: [String] = []

        /// Strip everything the ambient spine contributes, leaving urgency, the
        /// user's order and incumbency. What `.alerts` mode scores against.
        func withoutContextSignals() -> Inputs {
            var copy = self
            copy.profile = .empty
            copy.affinities = [:]
            copy.contentChangedAt = [:]
            copy.lastViewedAt = nil
            return copy
        }
    }

    /// One card's score with its terms kept separate — the shape a future
    /// "why did this rank here" diagnostics view (architecture §6) would read,
    /// and what makes a failing test say which term was wrong.
    struct Score: Equatable, Sendable {
        /// Urgency escalation, 0…1. NOT part of `total` — it selects the tier
        /// the card sorts in, and `total` only orders cards within a tier.
        var urgency: Double = 0
        var context: Double = 0
        var novelty: Double = 0
        var order: Double = 0
        var incumbency: Double = 0

        /// Rank within the urgency tier.
        func total(_ w: Weights) -> Double {
            context * w.context
                + novelty * w.novelty
                + order * w.order
                + incumbency * w.incumbency
        }
    }

    // MARK: - Entry point

    /// Rank `cards` (in user order) for the notch. Returns the user's order
    /// unchanged under `.fixed`, when nothing has escalated under `.alerts`, or
    /// whenever the confidence floor isn't cleared under `.context`.
    static func ranked(
        _ cards: [FeedCard],
        inputs: Inputs,
        mode: FeedRankingMode = .alerts,
        weights: Weights = .default
    ) -> [FeedCard] {
        guard cards.count > 1, mode != .fixed else { return cards }
        // Under `.alerts` the context and novelty terms are not merely
        // outweighed — they are not computed. The only thing that can move a
        // card is its own escalation, so nothing can shift for a reason the user
        // can't read off the card itself.
        let scores = score(
            cards,
            inputs: mode.allowsContext ? inputs : inputs.withoutContextSignals(),
            weights: weights
        )
        guard clearsFloor(scores, weights: weights) else { return cards }

        // Urgency tier first, then within-tier score. Stable: a genuine tie
        // keeps the user's order rather than whatever the sort happens to do.
        return zip(cards, scores)
            .enumerated()
            .sorted { lhs, rhs in
                let l = lhs.element.1, r = rhs.element.1
                if l.urgency != r.urgency { return l.urgency > r.urgency }
                let lt = l.total(weights), rt = r.total(weights)
                if lt != rt { return lt > rt }
                return lhs.offset < rhs.offset
            }
            .map(\.element.0)
    }

    /// True when at least one card has a real reason to move. Only urgency
    /// ESCALATION and context match count — the order prior and incumbency are
    /// restatements of the existing order, so letting them clear the floor would
    /// make the floor meaningless.
    static func clearsFloor(_ scores: [Score], weights: Weights) -> Bool {
        scores.contains { max($0.urgency, $0.context) >= weights.floor }
    }

    // MARK: - Terms

    /// Score each card, positionally aligned with `cards`.
    static func score(
        _ cards: [FeedCard],
        inputs: Inputs,
        weights: Weights = .default
    ) -> [Score] {
        let previousRank = Dictionary(
            inputs.previousOrder.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let noveltyBoost = inputs.profile.returningFromAway ? weights.returnNoveltyBoost : 1

        return cards.enumerated().map { index, card in
            Score(
                urgency: card.urgency.escalation,
                context: inputs.profile.match(inputs.affinities[card.sourceId] ?? [:]),
                novelty: min(1, isNovel(card, inputs: inputs) ? noveltyBoost : 0),
                order: positionPrior(index: index, count: cards.count),
                incumbency: previousRank[card.id].map {
                    positionPrior(index: $0, count: inputs.previousOrder.count)
                } ?? 0
            )
        }
    }

    /// Whether the card's content changed since the user last had the feed open.
    /// Deliberately measured against content, not `updatedAt` — every Source
    /// stamps `updatedAt` on every refresh whether or not the value moved, so
    /// `updatedAt` tracks polling, not news.
    static func isNovel(_ card: FeedCard, inputs: Inputs) -> Bool {
        guard let lastViewedAt = inputs.lastViewedAt,
              let changedAt = inputs.contentChangedAt[card.id] else { return false }
        return changedAt > lastViewedAt
    }

    /// 1 at the top of the list, 0 at the bottom, linear between.
    static func positionPrior(index: Int, count: Int) -> Double {
        guard count > 1 else { return 1 }
        return 1 - Double(index) / Double(count - 1)
    }
}

// MARK: - Novelty tracking

/// Keeps "when did this card's content last change", which no existing type
/// records. Pure so the diffing rules are testable without a live feed.
enum FeedNovelty {

    /// Fold a new card set into the change log. A card whose `kind` is unchanged
    /// keeps its existing timestamp; a changed or brand-new card stamps `now`;
    /// ids that no longer exist are dropped so the map can't grow forever.
    ///
    /// First sight of a card stamps `now` rather than nil — it genuinely did
    /// appear at that moment. It still won't read as novel until the user has
    /// looked at the feed at least once (`FeedRanker.isNovel`), so a launch
    /// doesn't arrive with every card claiming to be new.
    static func tracking(
        previous: [String: Date],
        oldCards: [FeedCard],
        newCards: [FeedCard],
        now: Date
    ) -> [String: Date] {
        let oldByID = Dictionary(
            oldCards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        var result: [String: Date] = [:]
        for card in newCards {
            if let old = oldByID[card.id], old.kind == card.kind, let stamp = previous[card.id] {
                result[card.id] = stamp
            } else {
                result[card.id] = now
            }
        }
        return result
    }
}
