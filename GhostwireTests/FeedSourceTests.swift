//
//  FeedSourceTests.swift
//  GhostwireTests
//
//  GW-261. Covers the two things that actually break in a Source: the wire
//  format (Hyperliquid's string-typed numbers and index-aligned arrays) and the
//  parser (RSS vs Atom). Both are pure functions over fixtures — no network.
//

import XCTest
@testable import Ghostwire

final class HyperliquidFeedSourceTests: XCTestCase {
    /// Trimmed from a live response (2026-07-28). Note every number is a STRING
    /// and the two arrays are index-aligned by position, not by key.
    private let fixture = Data("""
    [
      {"universe": [{"name": "BTC"}, {"name": "ETH"}, {"name": "SOL"}]},
      [
        {"markPx": "63693.0", "midPx": "63692.5", "prevDayPx": "64925.0"},
        {"markPx": "1908.9", "midPx": "1908.95", "prevDayPx": "1940.5"},
        {"markPx": "73.851", "midPx": "73.8505", "prevDayPx": "75.741"}
      ]
    ]
    """.utf8)

    private func decode() throws -> HyperliquidAssetContexts {
        try JSONDecoder().decode(HyperliquidAssetContexts.self, from: fixture)
    }

    func testDecodesHeterogeneousArray() throws {
        let payload = try decode()
        XCTAssertEqual(payload.meta.universe.map(\.name), ["BTC", "ETH", "SOL"])
        XCTAssertEqual(payload.contexts.count, 3)
        XCTAssertEqual(payload.contexts[0].markPx, "63693.0")
    }

    func testMapsSymbolsToDataCards() throws {
        let cards = HyperliquidFeedSource.cards(
            from: try decode(), symbols: ["BTC", "SOL"], sourceId: "api.hyperliquid", now: Date()
        )
        XCTAssertEqual(cards.count, 2)
        guard case let .data(label, value, delta) = cards[0].kind else {
            return XCTFail("expected a .data card, got \(cards[0].kind)")
        }
        XCTAssertEqual(label, "BTC")
        XCTAssertEqual(value, "$63,693")          // >= 1000 → no decimals, grouped
        XCTAssertEqual(delta, "-1.90%")           // (63693 - 64925) / 64925
    }

    func testCardIdsAreStableAcrossRefreshes() throws {
        let payload = try decode()
        let first = HyperliquidFeedSource.cards(from: payload, symbols: ["BTC"], sourceId: "api.hyperliquid", now: Date())
        let second = HyperliquidFeedSource.cards(from: payload, symbols: ["BTC"], sourceId: "api.hyperliquid", now: Date().addingTimeInterval(60))
        // Stable ids are what let a card update in place and keep its position
        // in the user's persisted order.
        XCTAssertEqual(first[0].id, second[0].id)
        XCTAssertEqual(first[0].id, "api.hyperliquid.BTC")
    }

    func testUnlistedSymbolIsSkippedNotRenderedEmpty() throws {
        let cards = HyperliquidFeedSource.cards(
            from: try decode(), symbols: ["BTC", "DOESNOTEXIST"], sourceId: "api.hyperliquid", now: Date()
        )
        XCTAssertEqual(cards.map(\.id), ["api.hyperliquid.BTC"])
    }

    func testMissingMarkPriceFallsBackToMid() throws {
        let data = Data("""
        [{"universe": [{"name": "BTC"}]}, [{"midPx": "100.5", "prevDayPx": "100.0"}]]
        """.utf8)
        let payload = try JSONDecoder().decode(HyperliquidAssetContexts.self, from: data)
        let cards = HyperliquidFeedSource.cards(from: payload, symbols: ["BTC"], sourceId: "s", now: Date())
        guard case let .data(_, value, _) = cards[0].kind else { return XCTFail("expected .data") }
        XCTAssertEqual(value, "$100.50")
    }

    func testUnpricedAssetIsSkipped() throws {
        let data = Data("""
        [{"universe": [{"name": "NEW"}]}, [{"prevDayPx": "1.0"}]]
        """.utf8)
        let payload = try JSONDecoder().decode(HyperliquidAssetContexts.self, from: data)
        XCTAssertTrue(HyperliquidFeedSource.cards(from: payload, symbols: ["NEW"], sourceId: "s", now: Date()).isEmpty)
    }
}

final class FeedValueFormatterTests: XCTestCase {
    func testPrecisionScalesWithMagnitude() {
        XCTAssertEqual(FeedValueFormatter.price(63693.0), "$63,693")
        XCTAssertEqual(FeedValueFormatter.price(73.851), "$73.85")
        XCTAssertEqual(FeedValueFormatter.price(0.0432), "$0.0432")
    }

    func testDeltaCarriesItsSign() {
        XCTAssertEqual(FeedValueFormatter.percentDelta(current: 110, previous: 100), "+10.00%")
        XCTAssertEqual(FeedValueFormatter.percentDelta(current: 90, previous: 100), "-10.00%")
    }

    func testUnknowableDeltaIsOmittedNotZero() {
        XCTAssertNil(FeedValueFormatter.percentDelta(current: 100, previous: nil))
        XCTAssertNil(FeedValueFormatter.percentDelta(current: 100, previous: 0))
    }
}

final class RSSFeedParserTests: XCTestCase {
    func testParsesRSS2WithLinkAsElementText() throws {
        let xml = Data("""
        <?xml version="1.0"?>
        <rss version="2.0"><channel>
          <title>Hacker News</title>
          <link>https://news.ycombinator.com/</link>
          <item><title>First story</title><link>https://example.com/1</link></item>
          <item><title>Second story</title><link>https://example.com/2</link></item>
        </channel></rss>
        """.utf8)
        let parsed = try RSSFeedParser.parse(xml)
        XCTAssertEqual(parsed.title, "Hacker News")
        XCTAssertEqual(parsed.link?.absoluteString, "https://news.ycombinator.com/")
        XCTAssertEqual(parsed.entries.map(\.title), ["First story", "Second story"])
        XCTAssertEqual(parsed.entries[0].link?.absoluteString, "https://example.com/1")
    }

    func testParsesAtomWithLinkAsHrefAttribute() throws {
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Release notes</title>
          <link rel="self" href="https://example.com/feed.atom"/>
          <link rel="alternate" href="https://example.com/releases"/>
          <entry><title>v1.2.0</title><link href="https://example.com/v1.2.0"/></entry>
          <entry><title>v1.1.0</title><link href="https://example.com/v1.1.0"/></entry>
        </feed>
        """.utf8)
        let parsed = try RSSFeedParser.parse(xml)
        XCTAssertEqual(parsed.title, "Release notes")
        // rel="self" points at the feed itself, so the alternate wins.
        XCTAssertEqual(parsed.link?.absoluteString, "https://example.com/releases")
        XCTAssertEqual(parsed.entries.map(\.title), ["v1.2.0", "v1.1.0"])
    }

    func testCDATATitlesSurvive() throws {
        let xml = Data("""
        <rss version="2.0"><channel><title>Blog</title>
          <item><title><![CDATA[Why <braces> break parsers]]></title></item>
        </channel></rss>
        """.utf8)
        let parsed = try RSSFeedParser.parse(xml)
        XCTAssertEqual(parsed.entries.map(\.title), ["Why <braces> break parsers"])
    }

    func testHTMLServedWith200IsRejected() {
        // The common failure: a host returns an error page with a 200 status.
        // Well-formed XML, zero feed content — must throw, not yield a blank card.
        let html = Data("<html><body><p>Not found</p></body></html>".utf8)
        XCTAssertThrowsError(try RSSFeedParser.parse(html))
    }

    func testMalformedXMLThrows() {
        XCTAssertThrowsError(try RSSFeedParser.parse(Data("<rss><channel>".utf8)))
    }

    // MARK: - Top-story card shape

    private func parsed(entries: [(String, String?)], feedTitle: String = "Hacker News") -> RSSFeedParser.Parsed {
        RSSFeedParser.Parsed(
            title: feedTitle,
            link: URL(string: "https://news.ycombinator.com/"),
            entries: entries.map { RSSFeedParser.Entry(title: $0.0, link: $0.1.flatMap(URL.init(string:))) }
        )
    }

    private func card(_ parsed: RSSFeedParser.Parsed) -> FeedCard {
        RSSFeedSource.topStoryCard(
            from: parsed,
            feedURL: URL(string: "https://news.ycombinator.com/rss")!,
            id: "api.rss.abc", sourceId: "api.rss", now: Date()
        )
    }

    func testTopStoryIsTheHeadlineAndLinksToTheStoryNotTheHomepage() {
        let result = card(parsed(entries: [
            ("7.1 Earthquake in Japan", "https://example.com/quake"),
            ("Second", "https://example.com/2"),
            ("Third", "https://example.com/3"),
        ]))
        guard case let .generic(title, subtitle, value) = result.kind else {
            return XCTFail("expected .generic, got \(result.kind)")
        }
        XCTAssertEqual(title, "7.1 Earthquake in Japan")
        XCTAssertEqual(subtitle, "Hacker News · 2 more")
        // No big number: the headline is the content.
        XCTAssertNil(value)
        // The one action opens the story itself — the old .list card could only
        // ever reach the feed's homepage.
        XCTAssertEqual(result.link?.absoluteString, "https://example.com/quake")
    }

    func testSingleEntryOmitsTheMoreCount() {
        let result = card(parsed(entries: [("Only story", "https://example.com/1")]))
        guard case let .generic(_, subtitle, _) = result.kind else { return XCTFail("expected .generic") }
        XCTAssertEqual(subtitle, "Hacker News")
    }

    func testEmptyFeedStillRendersRatherThanVanishing() {
        let result = card(parsed(entries: []))
        guard case let .generic(title, subtitle, _) = result.kind else { return XCTFail("expected .generic") }
        XCTAssertEqual(title, "Hacker News")
        XCTAssertEqual(subtitle, "No entries")
        XCTAssertEqual(result.link?.absoluteString, "https://news.ycombinator.com/")
    }

    func testStoryWithoutItsOwnLinkFallsBackToTheFeedSite() {
        let result = card(parsed(entries: [("Linkless story", nil)]))
        XCTAssertEqual(result.link?.absoluteString, "https://news.ycombinator.com/")
    }

    func testStableKeyIsDeterministicAndURLSpecific() {
        let a = URL(string: "https://news.ycombinator.com/rss")!
        let b = URL(string: "https://example.com/feed.xml")!
        XCTAssertEqual(RSSFeedSource.stableKey(for: a), RSSFeedSource.stableKey(for: a))
        XCTAssertNotEqual(RSSFeedSource.stableKey(for: a), RSSFeedSource.stableKey(for: b))
    }
}
