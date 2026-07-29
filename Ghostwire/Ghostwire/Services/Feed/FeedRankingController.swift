//
//  FeedRankingController.swift
//  Ghostwire
//
//  GW-182 — the stateful shell around the pure `FeedRanker`. Owns the three
//  things a pure function can't: when to re-rank, what the previous ranking was,
//  and when the user last looked.
//
//  WHAT IT RANKS: the notch's top-N row, and only that. `FeedCardStore` stays
//  the user's curated order and the detached window grid renders it untouched —
//  the notch is the scarce, glanceable space worth arbitrating over, and the
//  window is where curation has to stay stable enough to be worth doing.
//
//  WHEN IT RE-RANKS — triggers, not a poll (architecture §4.2):
//   • the card set changed (a Source refreshed)
//   • the user's context changed (an app switch landed on the ambient spine)
//   • a surface opened (also marks "the user has now seen this")
//   • a slow tick, so recency decay and a settling app take effect on their own
//
//  Every pass ends in `FeedRanker`, which returns the user's order untouched
//  unless something clears the confidence floor. The common case is no change,
//  and no change means no animation — which is the point.
//

import Combine
import Defaults
import Foundation
import Observation

@Observable
@MainActor
final class FeedRankingController {
    static let shared = FeedRankingController()

    /// Exactly what the notch row renders. Ranked when ranking is on and has an
    /// opinion; otherwise the store's own top-N, unchanged.
    private(set) var notchCards: [FeedCard] = []

    /// Slow tick — lets recency decay and the settle window take effect without
    /// an app switch. Long on purpose: this is a correction, not a heartbeat.
    static let tickInterval: TimeInterval = 60

    private let store: FeedCardStore
    private let contextStore: ContextStore
    private let coordinator: FeedSourceCoordinator

    /// Card ids of the last emitted ranking — the incumbency prior that keeps a
    /// near-tie from swapping positions under the user's eyes.
    private var previousOrder: [String] = []
    /// When a feed surface was last open. Nil until they've actually looked.
    private var lastViewedAt: Date?

    private var eventsCancellable: AnyCancellable?
    private var enabledCancellable: AnyCancellable?
    private var timer: Timer?

    init(
        store: FeedCardStore = .shared,
        contextStore: ContextStore = .shared,
        coordinator: FeedSourceCoordinator = .shared
    ) {
        self.store = store
        self.contextStore = contextStore
        self.coordinator = coordinator
    }

    // MARK: - Lifecycle

    /// Begin following the card set, the ambient spine and the ranking toggle.
    func start() {
        observeCards()
        eventsCancellable = contextStore.$events
            .sink { [weak self] _ in
                Task { @MainActor in
                    // An app switch only matters to a mode that reads context.
                    guard Defaults[.feedRankingMode].allowsContext else { return }
                    self?.recompute()
                }
            }
        enabledCancellable = Defaults.publisher(.feedRankingMode)
            .sink { [weak self] _ in
                Task { @MainActor in
                    // A toggle is an explicit choice: drop the incumbency prior
                    // so the new mode takes effect at once rather than being
                    // held back by the order the old one produced.
                    self?.previousOrder = []
                    self?.recompute()
                }
            }
        startTimer()
        recompute()
    }

    func stop() {
        eventsCancellable = nil
        enabledCancellable = nil
        timer?.invalidate()
        timer = nil
    }

    /// A feed surface opened. Marks everything currently shown as seen (so it
    /// stops counting as novel) and re-ranks against fresh context.
    ///
    /// Ordering matters: rank FIRST against the old `lastViewedAt` so cards that
    /// changed while the surface was shut still get their novelty boost on the
    /// pass the user is about to look at, and only then mark them seen.
    func surfaceDidOpen(now: Date = Date()) {
        recompute(now: now)
        lastViewedAt = now
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Re-arm on the next `orderedCards` mutation. `@Observable` has no
    /// publisher, so tracking is re-registered after each change.
    private func observeCards() {
        withObservationTracking {
            _ = store.orderedCards
        } onChange: { [weak self] in
            Task { @MainActor in
                // Re-arm BEFORE recomputing: a Source landing mid-pass would
                // otherwise fall into the gap and not re-rank until the tick.
                self?.observeCards()
                self?.recompute()
            }
        }
    }

    // MARK: - Ranking pass

    func recompute(now: Date = Date()) {
        let cards = store.orderedCards
        let limit = store.notchVisibleCount

        let mode = Defaults[.feedRankingMode]
        guard mode != .fixed else {
            previousOrder = []
            publish(Array(cards.prefix(limit)))
            return
        }

        let ranked = FeedRanker.ranked(cards, inputs: inputs(now: now, mode: mode), mode: mode)
        // Track the full ranking, not just the visible slice: a card that just
        // fell off the end is still an incumbent, and forgetting it would let it
        // bounce back in on the next near-tie.
        previousOrder = ranked.map(\.id)
        publish(Array(ranked.prefix(limit)))
    }

    /// Assign only on a real change. Observation doesn't diff, so publishing an
    /// identical result would redraw the row on every 60s tick for nothing —
    /// and the quiet case, where ranking changes nothing, is the common one.
    private func publish(_ cards: [FeedCard]) {
        guard cards != notchCards else { return }
        notchCards = cards
    }

    private func inputs(now: Date, mode: FeedRankingMode) -> FeedRanker.Inputs {
        // Don't even derive a profile unless the mode will use it — under
        // `.alerts` (the default) the ambient spine is not consulted at all.
        let profile = mode.allowsContext && Defaults[.ambientCaptureEnabled]
            ? ContextProfile.build(events: contextStore.events, now: now)
            : .empty
        return FeedRanker.Inputs(
            profile: profile,
            affinities: coordinator.affinities,
            contentChangedAt: store.contentChangedAt,
            lastViewedAt: lastViewedAt,
            previousOrder: previousOrder
        )
    }
}
