//
//  FeedRankerTests.swift
//  GhostwireTests
//
//  GW-182 — the ranking policy. Pure in, pure out: cards + a ContextProfile,
//  a reordered list back. The behaviours worth pinning are the restraints as
//  much as the ranking — the confidence floor, the incumbency margin, and the
//  refusal to read `updatedAt` as novelty.
//

import XCTest
@testable import Ghostwire

final class FeedRankerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)
    // Symbolic, with a stub classifier — ranking behaviour must not depend on
    // which apps happen to be installed where the tests run.
    private let xcode = "test.editor"
    private let tradingView = "test.charts"

    private func stub(_ bundleID: String) -> AppCategory {
        bundleID == "test.editor" ? .coding : (bundleID == "test.charts" ? .finance : .other)
    }

    private func card(
        _ id: String,
        source: String = "s",
        urgency: FeedCardUrgency = .info,
        value: String = "v"
    ) -> FeedCard {
        FeedCard(
            id: id,
            sourceId: source,
            kind: .data(label: id, value: value, delta: nil),
            updatedAt: t0,
            urgency: urgency
        )
    }

    private func profile(_ bundleID: String, minutes: TimeInterval = 30) -> ContextProfile {
        let event = ContextEvent(
            id: UUID(), bundleID: bundleID, appName: bundleID,
            start: t0, end: t0.addingTimeInterval(minutes * 60), idleAtEnd: 0
        )
        return ContextProfile.build(
            events: [event], now: t0.addingTimeInterval(minutes * 60), categorize: stub
        )
    }

    private func ids(_ cards: [FeedCard]) -> [String] { cards.map(\.id) }

    // MARK: - Modes — what is allowed to move a card

    func testFixedModeNeverReordersEvenForAWaitingAgent() {
        // The strongest possible signal, explicitly opted out of. "Fixed" has to
        // mean fixed or the setting is a lie.
        let cards = [card("a"), card("b"), card("agents", urgency: .critical)]
        let inputs = FeedRanker.Inputs(
            profile: profile(xcode),
            affinities: ["s": [.coding: 1.0]],
            contentChangedAt: ["a": t0.addingTimeInterval(100)],
            lastViewedAt: t0
        )
        XCTAssertEqual(ids(FeedRanker.ranked(cards, inputs: inputs, mode: .fixed)), ["a", "b", "agents"])
    }

    func testAlertsModeIgnoresContextEntirely() {
        // Deep in TradingView with crypto cards last in the user's order. Under
        // the default mode nothing moves: topical relevance is not a reason.
        let cards = [
            card("quota", source: "local"),
            card("btc", source: "crypto"),
            card("eth", source: "crypto"),
        ]
        let inputs = FeedRanker.Inputs(
            profile: profile(tradingView),
            affinities: ["local": [.coding: 1.0], "crypto": [.finance: 1.0]]
        )
        XCTAssertEqual(ids(FeedRanker.ranked(cards, inputs: inputs, mode: .alerts)),
                       ["quota", "btc", "eth"])
    }

    func testAlertsModeIgnoresNovelty() {
        let cards = [card("a"), card("b")]
        let inputs = FeedRanker.Inputs(
            contentChangedAt: ["b": t0.addingTimeInterval(100)],
            lastViewedAt: t0
        )
        XCTAssertEqual(ids(FeedRanker.ranked(cards, inputs: inputs, mode: .alerts)), ["a", "b"])
    }

    func testAlertsModeStillPromotesAWaitingCard() {
        let cards = [card("a"), card("b"), card("agents", urgency: .attention)]
        XCTAssertEqual(FeedRanker.ranked(cards, inputs: .init(), mode: .alerts).first?.id, "agents")
    }

    func testContextModeIsTheOnlyOneThatUsesAffinity() {
        let cards = [card("quota", source: "local"), card("btc", source: "crypto")]
        let inputs = FeedRanker.Inputs(
            profile: profile(tradingView),
            affinities: ["local": [.coding: 1.0], "crypto": [.finance: 1.0]]
        )
        XCTAssertEqual(ids(FeedRanker.ranked(cards, inputs: inputs, mode: .context)), ["btc", "quota"])
        XCTAssertEqual(ids(FeedRanker.ranked(cards, inputs: inputs, mode: .alerts)), ["quota", "btc"])
    }

    func testModeCapabilitiesAreConsistent() {
        XCTAssertFalse(FeedRankingMode.fixed.allowsUrgency)
        XCTAssertFalse(FeedRankingMode.fixed.allowsContext)
        XCTAssertTrue(FeedRankingMode.alerts.allowsUrgency)
        XCTAssertFalse(FeedRankingMode.alerts.allowsContext)
        XCTAssertTrue(FeedRankingMode.context.allowsUrgency)
        XCTAssertTrue(FeedRankingMode.context.allowsContext)
    }

    // MARK: - The confidence floor

    func testNoSignalLeavesTheUsersOrderUntouched() {
        // A fresh machine: no context, no urgency, no affinity declared.
        let cards = [card("a"), card("b"), card("c")]
        let ranked = FeedRanker.ranked(cards, inputs: .init())
        XCTAssertEqual(ids(ranked), ["a", "b", "c"])
    }

    func testContextThatMatchesNothingLeavesTheUsersOrderUntouched() {
        // The user is deep in Xcode, but every card is from a finance Source —
        // relevant to nothing they're doing. Silence is the right answer.
        let cards = [card("a", source: "crypto"), card("b", source: "crypto")]
        let ranked = FeedRanker.ranked(cards, inputs: .init(
            profile: profile(xcode),
            affinities: ["crypto": [.finance: 1.0]]
        ), mode: .context)
        XCTAssertEqual(ids(ranked), ["a", "b"])
    }

    func testOrderPriorAloneCannotClearTheFloor() {
        // Position and incumbency are restatements of the existing order — if
        // they could clear the floor, the floor would mean nothing.
        let cards = [card("a"), card("b"), card("c")]
        let scores = FeedRanker.score(cards, inputs: .init(previousOrder: ["c", "b", "a"]))
        XCTAssertFalse(FeedRanker.clearsFloor(scores, weights: .default))
    }

    // MARK: - Urgency

    func testABlockedAgentCardIsPromotedFromTheBottom() {
        // The agents card sits last in the user's order until something waits on
        // them. No ambient capture involved — this is the Tier-A path.
        let cards = [card("a"), card("b"), card("agents", urgency: .attention)]
        let ranked = FeedRanker.ranked(cards, inputs: .init())
        XCTAssertEqual(ranked.first?.id, "agents")
    }

    func testOrdinaryCardsCarryNoUrgencySignal() {
        // .info is the resting level: a Source must escalate to be heard.
        XCTAssertEqual(FeedCardUrgency.info.escalation, 0)
        XCTAssertEqual(FeedCardUrgency.ambient.escalation, 0)
        XCTAssertGreaterThan(FeedCardUrgency.attention.escalation, 0)
        XCTAssertGreaterThan(FeedCardUrgency.critical.escalation, FeedCardUrgency.attention.escalation)
    }

    func testCriticalOutranksAttention() {
        let cards = [card("attn", urgency: .attention), card("crit", urgency: .critical)]
        let ranked = FeedRanker.ranked(cards, inputs: .init())
        XCTAssertEqual(ids(ranked), ["crit", "attn"])
    }

    // MARK: - Context affinity

    func testCardsMatchingTheCurrentAppRiseAboveOnesThatDont() {
        // In TradingView: the crypto cards should lead, even though the user's
        // saved order puts the local ones first.
        let cards = [
            card("quota", source: "local"),
            card("agents", source: "local"),
            card("btc", source: "crypto"),
            card("eth", source: "crypto"),
        ]
        let ranked = FeedRanker.ranked(cards, inputs: .init(
            profile: profile(tradingView),
            affinities: ["local": [.coding: 1.0], "crypto": [.finance: 1.0]]
        ), mode: .context)
        XCTAssertEqual(Set(ids(ranked).prefix(2)), ["btc", "eth"])
    }

    func testTheSameFeedRanksDifferentlyInADifferentApp() {
        let cards = [
            card("btc", source: "crypto"),
            card("quota", source: "local"),
        ]
        let affinities: [String: [AppCategory: Double]] = [
            "local": [.coding: 1.0], "crypto": [.finance: 1.0],
        ]
        let inXcode = FeedRanker.ranked(cards, inputs: .init(
            profile: profile(xcode), affinities: affinities
        ), mode: .context)
        let inTradingView = FeedRanker.ranked(cards, inputs: .init(
            profile: profile(tradingView), affinities: affinities
        ), mode: .context)
        XCTAssertEqual(inXcode.first?.id, "quota")
        XCTAssertEqual(inTradingView.first?.id, "btc")
    }

    func testAWaitingAgentOutranksACardThatMatchesTheCurrentApp() {
        // The tier at work: waiting on the user beats being topically relevant,
        // even when the relevant card also sits first in the user's own order.
        let cards = [
            card("btc", source: "crypto"),
            card("agents", source: "local", urgency: .attention),
        ]
        let ranked = FeedRanker.ranked(cards, inputs: .init(
            profile: profile(tradingView),
            affinities: ["local": [.coding: 1.0], "crypto": [.finance: 1.0]]
        ), mode: .context)
        XCTAssertEqual(ranked.first?.id, "agents")
    }

    // MARK: - Novelty

    func testACardIsNotNovelUntilTheUserHasLookedAtLeastOnce() {
        // At launch every card is "new" to the change log. That must not read as
        // news, or the first paint would arrive pre-shuffled.
        let cards = [card("a"), card("b")]
        let inputs = FeedRanker.Inputs(
            contentChangedAt: ["a": t0, "b": t0],
            lastViewedAt: nil
        )
        XCTAssertFalse(FeedRanker.isNovel(cards[0], inputs: inputs))
    }

    func testContentChangedSinceLastViewedCountsAsNovel() {
        let inputs = FeedRanker.Inputs(
            contentChangedAt: ["a": t0.addingTimeInterval(100)],
            lastViewedAt: t0
        )
        XCTAssertTrue(FeedRanker.isNovel(card("a"), inputs: inputs))
    }

    func testUnchangedContentIsNotNovelEvenAfterARefresh() {
        let inputs = FeedRanker.Inputs(
            contentChangedAt: ["a": t0.addingTimeInterval(-100)],
            lastViewedAt: t0
        )
        XCTAssertFalse(FeedRanker.isNovel(card("a"), inputs: inputs))
    }

    // MARK: - Hysteresis

    func testASlightAffinityEdgeDoesNotDisturbTheUsersOrder() {
        // 's2' is marginally more relevant, but not enough to be worth moving a
        // card under the user's eyes. The order + incumbency priors absorb it.
        let cards = [card("a", source: "s1"), card("b", source: "s2")]
        let inputs = FeedRanker.Inputs(
            profile: profile(xcode),
            affinities: ["s1": [.coding: 0.5], "s2": [.coding: 0.6]],
            previousOrder: ["a", "b"]
        )
        XCTAssertEqual(ids(FeedRanker.ranked(cards, inputs: inputs, mode: .context)), ["a", "b"])
    }

    func testADecisiveAffinityEdgeDoesReorder() {
        let cards = [card("a", source: "s1"), card("b", source: "s2")]
        let inputs = FeedRanker.Inputs(
            profile: profile(xcode),
            affinities: ["s1": [.coding: 0.1], "s2": [.coding: 1.0]],
            previousOrder: ["a", "b"]
        )
        XCTAssertEqual(ids(FeedRanker.ranked(cards, inputs: inputs, mode: .context)), ["b", "a"])
    }

    func testIncumbencyFavoursWhateverWasShownLastTime() {
        // Direct on the term: the previous ranking, not the user's order, is
        // what incumbency rewards — that's what makes near-ties stop flickering.
        let cards = [card("a"), card("b")]
        let scores = FeedRanker.score(cards, inputs: .init(previousOrder: ["b", "a"]))
        XCTAssertEqual(scores[0].incumbency, 0)   // 'a' was shown second
        XCTAssertEqual(scores[1].incumbency, 1)   // 'b' was shown first
    }

    func testCardsAbsentFromThePreviousRankingGetNoIncumbency() {
        let scores = FeedRanker.score([card("new")], inputs: .init(previousOrder: ["a", "b"]))
        XCTAssertEqual(scores[0].incumbency, 0)
    }

    // MARK: - Stability

    func testTiedScoresKeepTheUsersOrder() {
        // Identical cards from the same Source: nothing distinguishes them, so
        // the user's order must survive rather than the sort's whim.
        let cards = [card("a"), card("b"), card("c"), card("urgent", urgency: .attention)]
        let ranked = FeedRanker.ranked(cards, inputs: .init())
        XCTAssertEqual(ids(ranked), ["urgent", "a", "b", "c"])
    }

    func testRankingIsIdempotentOnItsOwnOutput() {
        let cards = [card("a"), card("b"), card("agents", urgency: .attention)]
        let inputs = FeedRanker.Inputs(profile: profile(xcode))
        let once = FeedRanker.ranked(cards, inputs: inputs, mode: .context)
        let twice = FeedRanker.ranked(once, inputs: .init(
            profile: inputs.profile, previousOrder: once.map(\.id)
        ), mode: .context)
        XCTAssertEqual(ids(once), ids(twice))
    }

    func testSingleCardAndEmptyListAreReturnedUnchanged() {
        XCTAssertEqual(FeedRanker.ranked([], inputs: .init()).count, 0)
        XCTAssertEqual(ids(FeedRanker.ranked([card("a")], inputs: .init())), ["a"])
    }

    // MARK: - Novelty tracking (FeedNovelty)

    func testTrackingStampsNewCardsAndPreservesUnchangedOnes() {
        let old = [card("a", value: "1")]
        let new = [card("a", value: "1"), card("b", value: "9")]
        let tracked = FeedNovelty.tracking(
            previous: ["a": t0], oldCards: old, newCards: new, now: t0.addingTimeInterval(100)
        )
        XCTAssertEqual(tracked["a"], t0)                            // unchanged content
        XCTAssertEqual(tracked["b"], t0.addingTimeInterval(100))    // brand new
    }

    func testTrackingRestampsWhenContentActuallyChanges() {
        let old = [card("a", value: "1")]
        let new = [card("a", value: "2")]
        let tracked = FeedNovelty.tracking(
            previous: ["a": t0], oldCards: old, newCards: new, now: t0.addingTimeInterval(100)
        )
        XCTAssertEqual(tracked["a"], t0.addingTimeInterval(100))
    }

    func testTrackingIgnoresUpdatedAtChurn() {
        // The failure this whole mechanism exists for: every Source stamps
        // `updatedAt` on every refresh, so a same-value refresh must NOT read as
        // a content change.
        let old = [card("a", value: "1")]
        let refreshed = [FeedCard(
            id: "a", sourceId: "s",
            kind: .data(label: "a", value: "1", delta: nil),
            updatedAt: t0.addingTimeInterval(600)   // refreshed, identical value
        )]
        let tracked = FeedNovelty.tracking(
            previous: ["a": t0], oldCards: old, newCards: refreshed, now: t0.addingTimeInterval(600)
        )
        XCTAssertEqual(tracked["a"], t0)
    }

    func testTrackingDropsVanishedCards() {
        let tracked = FeedNovelty.tracking(
            previous: ["a": t0, "gone": t0],
            oldCards: [card("a"), card("gone")],
            newCards: [card("a")],
            now: t0
        )
        XCTAssertNil(tracked["gone"])
        XCTAssertEqual(tracked.count, 1)
    }

    // MARK: - Built-in Source affinities

    func testBuiltInSourcesDeclareTheAffinitiesTheRankerNeeds() {
        XCTAssertEqual(LocalStatsFeedSource().affinity[.coding], 1.0)
        XCTAssertEqual(HyperliquidFeedSource(symbols: ["BTC"]).affinity[.finance], 1.0)
        XCTAssertEqual(RSSFeedSource(feeds: []).affinity[.research], 1.0)
    }
}
