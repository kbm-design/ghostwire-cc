//
//  FeedSource.swift
//  Ghostwire
//
//  GW-261. The producer half of the GW-259 feed: a Source owns a backend (a
//  keyless REST API, an MCP server, a local app) and hands back finished
//  `FeedCard`s. The card layer never learns which backend produced a card —
//  that seam is described in FeedCard.swift's header and this is the protocol
//  that finally implements it.
//
//  Sendable + a nonisolated async `fetch()` so refreshes run off the main actor;
//  only FeedSourceCoordinator's store write hops back to @MainActor.
//

import Foundation

protocol FeedSource: Sendable {
    /// Stable across launches: namespaces this source's card ids and keys its
    /// enabled toggle in Defaults. Changing it orphans a user's card order.
    var id: String { get }

    /// Shown in Settings.
    var displayName: String { get }

    /// How often the coordinator refreshes this source. Also the input to
    /// `FeedCard.isStale(refreshInterval:)`, so cards dim on their own if a
    /// source's refreshes stop landing.
    var refreshInterval: TimeInterval { get }

    /// One refresh. Throwing leaves the source's previous cards in place —
    /// a flaky network dims cards rather than blanking the feed.
    func fetch() async throws -> [FeedCard]
}

// MARK: - Shared formatting

/// Number formatting shared by the numeric sources. Pure and static so the
/// rules are unit-testable without a network round trip.
enum FeedValueFormatter {
    /// Price with a currency prefix, precision scaled to magnitude: a
    /// four-figure asset doesn't need cents, a sub-dollar one needs four
    /// decimals or it renders as "$0.00".
    static func price(_ value: Double, currency: String = "$") -> String {
        currency + number(value)
    }

    /// The same magnitude-scaled precision without a currency prefix — used by
    /// any Source with an unlabelled measurement (GW-214's MCP results, where the
    /// payload rarely says what unit it's in).
    static func number(_ value: Double) -> String {
        let decimals: Int
        switch abs(value) {
        case 1000...: decimals = 0
        case 1...: decimals = 2
        default: decimals = 4
        }
        return grouped(value, minimumFractionDigits: decimals, maximumFractionDigits: decimals)
    }

    /// A whole number: grouped, never given decimals. Counts are the one numeric
    /// case where `number()`'s magnitude rule is wrong — "12.00 issues" is noise.
    static func count(_ value: Int) -> String {
        grouped(Double(value), minimumFractionDigits: 0, maximumFractionDigits: 0)
    }

    private static func grouped(
        _ value: Double, minimumFractionDigits: Int, maximumFractionDigits: Int
    ) -> String {
        // Built per call rather than cached: NumberFormatter isn't Sendable, and
        // these run a handful of times per refresh.
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Signed percentage change, always carrying its sign so the delta reads as
    /// a direction rather than a bare number. Nil when the reference price is
    /// zero or missing — an unknowable delta is omitted, never rendered as 0%.
    static func percentDelta(current: Double, previous: Double?) -> String? {
        guard let previous, previous != 0 else { return nil }
        let change = (current - previous) / previous * 100
        let sign = change >= 0 ? "+" : "-"
        return String(format: "%@%.2f%%", sign, abs(change))
    }
}
