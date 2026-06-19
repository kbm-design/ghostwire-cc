//
//  FeedCardTests.swift
//  GhostwireTests
//
//  GW-259: the feed card-rendering layer's pure model logic — the copy/send
//  text representation, the staleness verdict, and the link affordance. The
//  per-kind view dispatch is compile-enforced (the switch has no default), so
//  there's nothing to assert there.
//

import XCTest
@testable import Ghostwire

final class FeedCardTests: XCTestCase {

    private func card(_ kind: FeedCardKind, updatedAt: Date = Date(), link: URL? = nil) -> FeedCard {
        FeedCard(id: "t", sourceId: "s", kind: kind, updatedAt: updatedAt, link: link)
    }

    // MARK: - plainText (copy / send-to-agent representation)

    func testPlainTextForText() {
        let c = card(.text(title: "Title", body: "Body line"))
        XCTAssertEqual(c.plainText, "Title\nBody line")
    }

    func testPlainTextForTextDropsEmptyTitle() {
        let c = card(.text(title: "", body: "Just body"))
        XCTAssertEqual(c.plainText, "Just body")
    }

    func testPlainTextForDataWithDelta() {
        let c = card(.data(label: "BTC", value: "$64,210", delta: "+2.4%"))
        XCTAssertEqual(c.plainText, "BTC: $64,210 (+2.4%)")
    }

    func testPlainTextForDataWithoutDelta() {
        let c = card(.data(label: "Open PRs", value: "12", delta: nil))
        XCTAssertEqual(c.plainText, "Open PRs: 12")
    }

    func testPlainTextForList() {
        let c = card(.list(title: "Todo", items: ["a", "b"]))
        XCTAssertEqual(c.plainText, "Todo\n- a\n- b")
    }

    func testPlainTextForGenericCompactsNils() {
        let c = card(.generic(title: "Title", subtitle: nil, value: "42"))
        XCTAssertEqual(c.plainText, "Title\n42")
    }

    // MARK: - Staleness (mirrors the usage-meter freshness check)

    func testFreshCardIsNotStale() {
        let now = Date()
        let c = card(.data(label: "x", value: "1", delta: nil), updatedAt: now)
        XCTAssertFalse(c.isStale(refreshInterval: 60, now: now))
    }

    func testCardGoesStalePastToleranceWindow() {
        let now = Date()
        // refreshInterval 60s, tolerance 2 → stale after 120s. 200s ago is stale.
        let c = card(.data(label: "x", value: "1", delta: nil), updatedAt: now.addingTimeInterval(-200))
        XCTAssertTrue(c.isStale(refreshInterval: 60, now: now))
    }

    func testCardWithinToleranceIsNotStale() {
        let now = Date()
        let c = card(.data(label: "x", value: "1", delta: nil), updatedAt: now.addingTimeInterval(-90))
        XCTAssertFalse(c.isStale(refreshInterval: 60, now: now))  // 90s < 120s window
    }

    func testZeroRefreshIntervalNeverStale() {
        let now = Date()
        let c = card(.text(title: "", body: "x"), updatedAt: now.addingTimeInterval(-10_000))
        XCTAssertFalse(c.isStale(refreshInterval: 0, now: now))
    }

    // MARK: - Link affordance

    func testLinkDefaultsToNil() {
        XCTAssertNil(card(.text(title: "", body: "x")).link)
    }

    func testLinkIsRetained() {
        let url = URL(string: "https://linear.app/ghostwire/issue/GW-259")!
        XCTAssertEqual(card(.text(title: "", body: "x"), link: url).link, url)
    }
}
