//
//  FeedCardStore.swift
//  Ghostwire
//
//  GW-259. The single source of truth for the Dashboard feed: the cards in
//  user-curated order, read by BOTH surfaces — the notch's top-N row and the
//  detachable window's full reorderable list. One writer (the window list's
//  drag-reorder), two readers; mutating the order here updates both reactively.
//
//  Order persists as an array of stable FeedCard ids in Defaults (same idiom as
//  notchTabOrder), applied to the live card set on each update: known ids hold
//  their saved position, new ids append, vanished ids drop out. This survives
//  the later swap from sample data to real Sources with no change here.
//

import Defaults
import Foundation
import Observation

@Observable
@MainActor
final class FeedCardStore {
    static let shared = FeedCardStore()

    /// All cards in user order (persisted order applied to the live set).
    private(set) var orderedCards: [FeedCard]

    /// GW-182 — cardId → when its CONTENT last changed. Distinct from
    /// `FeedCard.updatedAt`, which every Source stamps on every refresh whether
    /// or not the value moved: `updatedAt` measures polling, this measures news.
    /// In-memory only; "new since you last looked" is a within-session question.
    private(set) var contentChangedAt: [String: Date] = [:]

    /// The first N cards mirror into the notch. Tunable via Defaults.
    var notchVisibleCount: Int { max(0, Defaults[.feedNotchVisibleCount]) }

    /// Exactly the cards the notch shows — the top-N of the ordered list.
    var notchCards: [FeedCard] { Array(orderedCards.prefix(notchVisibleCount)) }

    init(cards: [FeedCard] = []) {
        Self.migrateRacedOrderIfNeeded()
        orderedCards = Self.reconcile(cards: cards, order: Defaults[.feedCardOrder])
    }

    /// Replace the live card set — called by `FeedSourceCoordinator` as Sources
    /// refresh (GW-261). Applies the user's saved order but deliberately does
    /// NOT write one back.
    ///
    /// Writing here is what caused the first-run ordering bug: sources refresh
    /// concurrently, so the first `setCards` lands with only the fastest
    /// source's cards. Persisting that partial set froze the winner of a network
    /// race at the top, and every later source appended behind it — permanently,
    /// since `reconcile` honours saved positions on every subsequent launch.
    /// Only an explicit `move` is a choice worth persisting.
    func setCards(_ cards: [FeedCard], now: Date = Date()) {
        contentChangedAt = FeedNovelty.tracking(
            previous: contentChangedAt, oldCards: orderedCards, newCards: cards, now: now
        )
        orderedCards = Self.reconcile(cards: cards, order: Defaults[.feedCardOrder])
    }

    /// Drag-reorder from the window list. Persists the new id order so the notch
    /// top-N follows. Callers wrap this in `withAnimation` for the reshuffle.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        orderedCards.move(fromOffsets: source, toOffset: destination)
        persistOrder()
    }

    private func persistOrder() {
        Defaults[.feedCardOrder] = orderedCards.map(\.id)
    }

    /// One-time cleanup (GW-261). Every `feedCardOrder` written before this
    /// build came from `setCards` persisting whatever partial card set happened
    /// to refresh first — plus, on older installs, the ids of the deleted
    /// `sampleCards`. No shipped build ever exposed a way to reorder cards
    /// (GW-290 is still open, `move` has no caller), so there is no
    /// user-authored order that this can destroy.
    nonisolated static func migrateRacedOrderIfNeeded() {
        guard !Defaults[.feedCardOrderMigrated] else { return }
        Defaults[.feedCardOrder] = []
        Defaults[.feedCardOrderMigrated] = true
    }

    /// Pure: apply a persisted id order to a live card set. Known ids keep their
    /// saved position; ids not in `order` append in their incoming order; ids in
    /// `order` with no live card are dropped. No duplicates.
    nonisolated static func reconcile(cards: [FeedCard], order: [String]) -> [FeedCard] {
        let byId = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [FeedCard] = []
        var used = Set<String>()
        for id in order {
            guard let card = byId[id], !used.contains(id) else { continue }
            result.append(card)
            used.insert(id)
        }
        for card in cards where !used.contains(card.id) {
            result.append(card)
            used.insert(card.id)
        }
        return result
    }
}

