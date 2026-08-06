//
//  RSSFeedSource.swift
//  Ghostwire
//
//  GW-261. The generalist keyless Source: anything that publishes RSS or Atom.
//  One engine covers Hacker News, GitHub releases (`<repo>/releases.atom`),
//  changelogs and blogs — which is why the built-in catalog is two engines and
//  not five, and why a user can extend the feed themselves by pasting a URL
//  instead of waiting for us to write an integration.
//
//  Emits ONE card per feed, showing the TOP STORY only — headline, which feed
//  it came from, and how many newer entries are behind it. Not a list.
//
//  Why not a list: a card has room for one question and one action. A list of
//  five headlines answers none of them — the rows can't be individually clicked
//  at this size, so "+N more" becomes a dead end and the card degrades into
//  decoration. One headline you can actually open beats five you can't.
//

import CryptoKit
import Foundation
import os

struct RSSFeedSource: FeedSource {
    let id = "api.rss"
    let displayName = "RSS & Atom feeds"
    /// Feeds move on a human cadence, not a market one — 15 minutes is well
    /// inside "fresh" for news and releases, and stays polite to the hosts.
    let refreshInterval: TimeInterval = 900

    /// GW-182. Headlines are for reading time, not mid-build. Note that browsers
    /// don't declare a usable category (Safari says "productivity", Chrome
    /// declares nothing), so in practice this matches news/reference apps rather
    /// than the browser itself — see `AppCategoryMap`.
    let affinity: [AppCategory: Double] = [.research: 1.0]

    /// Feed URLs, in card order.
    var feeds: [URL]

    private static let logger = os.Logger(subsystem: "com.ghostwire.notch", category: "RSSFeedSource")

    init(feeds: [URL] = RSSFeedSource.defaultFeeds) {
        self.feeds = feeds
    }

    /// The opinionated starter set: dev-relevant, keyless, no account. Users can
    /// remove or add to these in Settings.
    static var defaultFeeds: [URL] {
        [
            URL(string: "https://news.ycombinator.com/rss")!,
            URL(string: "https://github.com/anthropics/claude-code/releases.atom")!,
        ]
    }

    func fetch() async throws -> [FeedCard] {
        let now = Date()
        var cards: [FeedCard] = []
        // Sequential, not concurrent: a handful of feeds every 15 minutes isn't
        // worth a task group, and staggering the requests is gentler on hosts.
        for url in feeds {
            do {
                cards.append(try await Self.card(for: url, sourceId: id, now: now))
            } catch {
                // One dead feed must not take the others down with it — the
                // coordinator keeps this source's previous cards for the gap.
                Self.logger.warning("feed failed \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return cards
    }

    private static func card(for url: URL, sourceId: String, now: Date) async throws -> FeedCard {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // Some hosts 403 a request with no UA.
        request.setValue("Ghostwire/1.0 (+https://github.com/Ghostwire-Design)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedSourceError.badStatus(http.statusCode)
        }
        let parsed = try RSSFeedParser.parse(data)
        return topStoryCard(
            from: parsed,
            feedURL: url,
            id: "\(sourceId).\(stableKey(for: url))",
            sourceId: sourceId,
            now: now
        )
    }

    /// Pure: the top story as a summary card. The headline is the focus, the
    /// feed name attributes it, and the card's link is the STORY's URL — so the
    /// one available action opens the thing you just read, not a homepage.
    ///
    /// A feed with no entries still renders (feed name as the headline, link to
    /// the site) rather than vanishing — an empty feed is information too.
    static func topStoryCard(
        from parsed: RSSFeedParser.Parsed,
        feedURL: URL,
        id: String,
        sourceId: String,
        now: Date
    ) -> FeedCard {
        let feedName = parsed.title ?? feedURL.host ?? "Feed"
        guard let top = parsed.entries.first else {
            return FeedCard(
                id: id, sourceId: sourceId,
                kind: .generic(title: feedName, subtitle: "No entries", value: nil),
                updatedAt: now, link: parsed.link ?? feedURL
            )
        }
        let newer = parsed.entries.count - 1
        return FeedCard(
            id: id,
            sourceId: sourceId,
            kind: .generic(
                title: top.title,
                subtitle: newer > 0 ? "\(feedName) · \(newer) more" : feedName,
                // No big number here: the headline is the content, and .generic
                // renders `value` as the dominant element.
                value: nil
            ),
            updatedAt: now,
            link: top.link ?? parsed.link ?? feedURL
        )
    }

    /// Stable across launches, unlike `String.hashValue` (seeded per-process, so
    /// using it here would reshuffle every card's identity on every restart and
    /// wipe the user's persisted order).
    static func stableKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Parsing

/// Minimal RSS 2.0 + Atom reader. Both dialects in one delegate because they
/// differ in exactly two places that matter here: the item element
/// (`item` vs `entry`) and where the link lives (element text vs an `href`
/// attribute).
final class RSSFeedParser: NSObject, XMLParserDelegate {
    struct Entry: Equatable, Sendable {
        let title: String
        let link: URL?
    }

    struct Parsed: Equatable, Sendable {
        let title: String?
        let link: URL?
        let entries: [Entry]
    }

    private var feedTitle: String?
    private var feedLink: URL?
    private var entries: [Entry] = []

    private var insideEntry = false
    private var currentElement = ""
    private var textBuffer = ""
    private var entryTitle: String?
    private var entryLink: URL?

    /// Synchronous by design: XMLParser and its delegate are not Sendable, so
    /// the whole parse stays inside one non-suspending scope.
    static func parse(_ data: Data) throws -> Parsed {
        let delegate = RSSFeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw FeedSourceError.malformedFeed }
        // A document that parsed as XML but yielded nothing is not a feed —
        // usually an HTML error page served with a 200.
        guard !delegate.entries.isEmpty || delegate.feedTitle != nil else {
            throw FeedSourceError.malformedFeed
        }
        return Parsed(title: delegate.feedTitle, link: delegate.feedLink, entries: delegate.entries)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes attributeDict: [String: String]
    ) {
        currentElement = elementName
        textBuffer = ""

        switch elementName {
        case "item", "entry":
            insideEntry = true
            entryTitle = nil
            entryLink = nil
        case "link":
            // Atom puts the URL in an attribute and self-closes the element, so
            // there is no character data to wait for. Skip `rel="self"`, which
            // points at the feed rather than the page.
            if let href = attributeDict["href"], attributeDict["rel"] != "self" {
                let url = URL(string: href)
                if insideEntry {
                    if entryLink == nil { entryLink = url }
                } else if feedLink == nil {
                    feedLink = url
                }
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        textBuffer += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        textBuffer = ""

        switch elementName {
        case "title":
            if insideEntry {
                if entryTitle == nil, !text.isEmpty { entryTitle = text }
            } else if feedTitle == nil, !text.isEmpty {
                feedTitle = text
            }
        case "link":
            // RSS 2.0 carries the URL as element text.
            if !text.isEmpty {
                if insideEntry {
                    if entryLink == nil { entryLink = URL(string: text) }
                } else if feedLink == nil {
                    feedLink = URL(string: text)
                }
            }
        case "item", "entry":
            if let title = entryTitle {
                entries.append(Entry(title: title, link: entryLink))
            }
            insideEntry = false
        default:
            break
        }
    }
}
