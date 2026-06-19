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

    /// The first N cards mirror into the notch. Tunable via Defaults.
    var notchVisibleCount: Int { max(0, Defaults[.feedNotchVisibleCount]) }

    /// Exactly the cards the notch shows — the top-N of the ordered list.
    var notchCards: [FeedCard] { Array(orderedCards.prefix(notchVisibleCount)) }

    init(cards: [FeedCard] = FeedCardStore.sampleCards) {
        orderedCards = Self.reconcile(cards: cards, order: Defaults[.feedCardOrder])
        persistOrder()
    }

    /// Replace the live card set (later: called by Sources as they refresh;
    /// for now seeded with samples). Re-applies the persisted order.
    func setCards(_ cards: [FeedCard]) {
        orderedCards = Self.reconcile(cards: cards, order: Defaults[.feedCardOrder])
        persistOrder()
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

// MARK: - Temporary sample seed (GW-259)

extension FeedCardStore {
    /// TEMPORARY: hand-built sample cards so the feed has content before real
    /// `Source`s (the GW-259 data side) exist. Replace with Source output later.
    nonisolated static var sampleCards: [FeedCard] {
        let now = Date()
        return [
            FeedCard(id: "sample.text", sourceId: "demo.text", sourceApp: "com.apple.finder",
                     kind: .text(title: "Release note", body: "v0.1.7 ships hold-to-talk and opt-in voice capture."),
                     updatedAt: now),
            FeedCard(id: "sample.btc", sourceId: "demo.data", sourceApp: nil,
                     kind: .data(label: "BTC", value: "$64,210", delta: "+2.4%"),
                     updatedAt: now),
            FeedCard(id: "sample.prs", sourceId: "demo.data", sourceApp: nil,
                     kind: .data(label: "Open PRs", value: "12", delta: "-3"),
                     updatedAt: now.addingTimeInterval(-3600)),
            FeedCard(id: "sample.assigned", sourceId: "demo.list", sourceApp: nil,
                     kind: .list(title: "Assigned to you", items: ["GW-259 Tabbed surface", "GW-261 Stats widget", "GW-285 Card refresh", "GW-214 MCP client"]),
                     updatedAt: now),
            FeedCard(id: "sample.ticket", sourceId: "demo.ticket", sourceApp: nil,
                     kind: .generic(title: "Tabbed surface primitive", subtitle: "In Progress · GW-259", value: nil),
                     updatedAt: now,
                     link: URL(string: "https://linear.app/ghostwire/issue/GW-259")),
            FeedCard(id: "sample.generic", sourceId: "demo.generic", sourceApp: nil,
                     kind: .generic(title: "Untemplated source", subtitle: "Falls back to the generic card", value: "42"),
                     updatedAt: now),
        ]
    }
}
