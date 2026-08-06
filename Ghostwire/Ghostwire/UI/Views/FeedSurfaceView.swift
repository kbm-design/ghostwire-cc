//
//  FeedSurfaceView.swift
//  Ghostwire
//
//  GW-259. The two presentations of the Dashboard feed, both reading the shared
//  FeedCardStore:
//    • notch  → a compact horizontal row of the top-N cards (its own notch tab).
//    • window → a multi-column grid of all cards (3–4 across), no media controls.
//  The surface is chosen by the `ghostwireSurface` environment flag (GW-223).
//
//  Note (GW-259): the window is a grid, not a List, so native drag-reorder + the
//  "top-N divider" don't apply here — order comes from the store as-is and the
//  notch shows its top-N. Curation/reorder is deferred to the feed redesign.
//

import SwiftUI

/// Picks the right feed presentation for the current surface.
struct FeedSurfaceView: View {
    @Environment(\.ghostwireSurface) private var surface

    var body: some View {
        Group {
            if surface == .window {
                FeedGridView()
            } else {
                FeedCardRowView()
            }
        }
        // GW-182: "seen" belongs to the feed actually being drawn, not to the
        // notch opening. The notch's `open()` fires for every tab, so marking
        // novelty there cleared cards the user never looked at. Re-ranks against
        // current context first, then records the view.
        .onAppear { FeedRankingController.shared.surfaceDidOpen() }
    }
}

// MARK: - Notch: compact horizontal top-N row

struct FeedCardRowView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // GW-182: the notch row reads the RANKED top-N, not the store's raw prefix.
    // The controller falls back to the store's order whenever ranking has no
    // confident opinion, so this is the same thing on a quiet machine.
    private let ranking = FeedRankingController.shared

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(ranking.notchCards) { card in
                    FeedCardView(card: card, isStale: false)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Reshuffle: animate position changes when the order changes — unless
        // the user prefers reduced motion.
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8),
                   value: ranking.notchCards.map(\.id))
    }
}

// MARK: - Window: multi-column card grid (3–4 across)

struct FeedGridView: View {
    private let store = FeedCardStore.shared

    // Adaptive so the column count tracks the window width: each cell is one
    // FeedCardView (176pt wide) → ~3–4 across in the detached window.
    private let columns = [GridItem(.adaptive(minimum: 176, maximum: 220), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(store.orderedCards) { card in
                    FeedCardView(card: card)
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
