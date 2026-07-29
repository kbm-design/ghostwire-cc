//
//  HyperliquidFeedSource.swift
//  Ghostwire
//
//  GW-261. Crypto prices from Hyperliquid's public `info` endpoint — the first
//  `api` Source, and the reason the feed can ship useful on a fresh install:
//  keyless, no account, nothing for the user to connect.
//
//  Endpoint contract (verified live 2026-07-28):
//    POST https://api.hyperliquid.xyz/info   body {"type":"metaAndAssetCtxs"}
//    → a TWO-ELEMENT heterogeneous array: [meta, contexts], index-aligned —
//      meta.universe[i].name names the asset whose numbers are contexts[i].
//    → every numeric field arrives as a STRING ("63693.0"), never a JSON number.
//
//  Why not `allMids`, which looks simpler: half its keys are bare numeric ids
//  ("#5090") with no names attached, so it can't be mapped back to symbols on
//  its own. metaAndAssetCtxs gets name + price + 24h reference in one request.
//

import Foundation
import os

struct HyperliquidFeedSource: FeedSource {
    let id = "api.hyperliquid"
    let displayName = "Crypto prices"
    let refreshInterval: TimeInterval = 60

    /// GW-182. Prices earn the notch when the user is already looking at
    /// markets; everywhere else they're ambient texture and should sit where the
    /// user put them.
    let affinity: [AppCategory: Double] = [.finance: 1.0]

    /// Which assets to surface, in card order. Uppercase Hyperliquid symbols.
    var symbols: [String]

    private static let endpoint = URL(string: "https://api.hyperliquid.xyz/info")!
    private static let logger = os.Logger(subsystem: "com.ghostwire.notch", category: "HyperliquidFeedSource")

    init(symbols: [String] = ["BTC", "ETH", "SOL"]) {
        self.symbols = symbols
    }

    func fetch() async throws -> [FeedCard] {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["type": "metaAndAssetCtxs"])
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedSourceError.badStatus(http.statusCode)
        }
        let payload = try JSONDecoder().decode(HyperliquidAssetContexts.self, from: data)
        return Self.cards(from: payload, symbols: symbols, sourceId: id, now: Date())
    }

    /// Pure mapping, split out so the wire format is testable from a fixture.
    /// A symbol the exchange doesn't list is skipped rather than rendered empty;
    /// a symbol with no usable price is skipped for the same reason.
    static func cards(
        from payload: HyperliquidAssetContexts,
        symbols: [String],
        sourceId: String,
        now: Date
    ) -> [FeedCard] {
        let names = payload.meta.universe.map(\.name)
        return symbols.compactMap { symbol in
            guard let index = names.firstIndex(of: symbol),
                  index < payload.contexts.count else {
                logger.debug("symbol not listed on Hyperliquid: \(symbol, privacy: .public)")
                return nil
            }
            let context = payload.contexts[index]
            // markPx is the canonical price; midPx is the book-derived fallback
            // for a market that hasn't marked yet.
            guard let price = Double(context.markPx ?? context.midPx ?? "") else { return nil }
            let previous = context.prevDayPx.flatMap(Double.init)

            return FeedCard(
                id: "\(sourceId).\(symbol)",
                sourceId: sourceId,
                kind: .data(
                    label: symbol,
                    value: FeedValueFormatter.price(price),
                    delta: FeedValueFormatter.percentDelta(current: price, previous: previous)
                ),
                updatedAt: now
            )
        }
    }
}

// MARK: - Wire format

/// `[meta, contexts]` — a heterogeneous JSON array, so this decodes through an
/// unkeyed container rather than synthesized Codable.
struct HyperliquidAssetContexts: Decodable, Sendable {
    struct Meta: Decodable, Sendable {
        struct Asset: Decodable, Sendable { let name: String }
        let universe: [Asset]
    }

    /// Numbers arrive as strings; every field is optional because a newly listed
    /// market can be missing a mark or a previous-day reference.
    struct Context: Decodable, Sendable {
        let markPx: String?
        let midPx: String?
        let prevDayPx: String?
    }

    let meta: Meta
    let contexts: [Context]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        meta = try container.decode(Meta.self)
        contexts = try container.decode([Context].self)
    }
}

enum FeedSourceError: Error, Equatable {
    case badStatus(Int)
    case malformedFeed
}
