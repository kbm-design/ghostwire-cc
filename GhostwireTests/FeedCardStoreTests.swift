//
//  FeedCardStoreTests.swift
//  GhostwireTests
//
//  GW-259: the feed store's ordering logic — the pure reconciliation (persisted
//  id order applied to a live card set) and the notch top-N slice. UI (drag,
//  animation) is verified live, not here.
//

import Defaults
import XCTest
@testable import Ghostwire

final class FeedCardStoreTests: XCTestCase {

    private func card(_ id: String) -> FeedCard {
        FeedCard(id: id, sourceId: "s", kind: .generic(title: id, subtitle: nil, value: nil), updatedAt: Date())
    }

    private func ids(_ cards: [FeedCard]) -> [String] { cards.map(\.id) }

    // MARK: - reconcile (pure)

    func testReconcileEmptyOrderKeepsIncomingOrder() {
        let cards = [card("a"), card("b"), card("c")]
        XCTAssertEqual(ids(FeedCardStore.reconcile(cards: cards, order: [])), ["a", "b", "c"])
    }

    func testReconcileAppliesSavedOrder() {
        let cards = [card("a"), card("b"), card("c")]
        XCTAssertEqual(ids(FeedCardStore.reconcile(cards: cards, order: ["c", "a", "b"])), ["c", "a", "b"])
    }

    func testReconcileAppendsNewIdsAfterOrdered() {
        // 'a' is saved; 'b','c' are new → keep a first, then new in incoming order.
        let cards = [card("a"), card("b"), card("c")]
        XCTAssertEqual(ids(FeedCardStore.reconcile(cards: cards, order: ["a"])), ["a", "b", "c"])
    }

    func testReconcileDropsVanishedIds() {
        // order references 'x' which no longer exists → dropped.
        let cards = [card("a"), card("b")]
        XCTAssertEqual(ids(FeedCardStore.reconcile(cards: cards, order: ["x", "b", "a"])), ["b", "a"])
    }

    func testReconcileNoDuplicatesFromRepeatedOrderIds() {
        let cards = [card("a"), card("b")]
        XCTAssertEqual(ids(FeedCardStore.reconcile(cards: cards, order: ["a", "a", "b"])), ["a", "b"])
    }

    // MARK: - store + notch slice (Defaults-backed, MainActor)

    @MainActor
    func testStoreAppliesAndPersistsReconciledOrder() {
        let savedOrder = Defaults[.feedCardOrder]
        defer { Defaults[.feedCardOrder] = savedOrder }

        // Saved order references a vanished id 'gone' — should be dropped, and
        // the persisted order rewritten to only live ids.
        Defaults[.feedCardOrder] = ["b", "gone", "a"]
        let store = FeedCardStore(cards: [card("a"), card("b"), card("c")])

        XCTAssertEqual(ids(store.orderedCards), ["b", "a", "c"])
        XCTAssertEqual(Defaults[.feedCardOrder], ["b", "a", "c"])  // 'gone' pruned, 'c' appended
    }

    @MainActor
    func testNotchCardsAreTopN() {
        let savedOrder = Defaults[.feedCardOrder]
        let savedCount = Defaults[.feedNotchVisibleCount]
        defer { Defaults[.feedCardOrder] = savedOrder; Defaults[.feedNotchVisibleCount] = savedCount }

        Defaults[.feedCardOrder] = []
        Defaults[.feedNotchVisibleCount] = 2
        let store = FeedCardStore(cards: [card("a"), card("b"), card("c")])

        XCTAssertEqual(ids(store.notchCards), ["a", "b"])
    }

    @MainActor
    func testNotchCardsSafeWhenFewerThanN() {
        let savedOrder = Defaults[.feedCardOrder]
        let savedCount = Defaults[.feedNotchVisibleCount]
        defer { Defaults[.feedCardOrder] = savedOrder; Defaults[.feedNotchVisibleCount] = savedCount }

        Defaults[.feedCardOrder] = []
        Defaults[.feedNotchVisibleCount] = 8
        let store = FeedCardStore(cards: [card("a")])

        XCTAssertEqual(ids(store.notchCards), ["a"])  // no out-of-range
    }

    @MainActor
    func testMoveReordersAndPersists() {
        let savedOrder = Defaults[.feedCardOrder]
        defer { Defaults[.feedCardOrder] = savedOrder }

        Defaults[.feedCardOrder] = []
        let store = FeedCardStore(cards: [card("a"), card("b"), card("c")])

        // Move 'c' (index 2) to the front.
        store.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        XCTAssertEqual(ids(store.orderedCards), ["c", "a", "b"])
        XCTAssertEqual(Defaults[.feedCardOrder], ["c", "a", "b"])
    }
}
