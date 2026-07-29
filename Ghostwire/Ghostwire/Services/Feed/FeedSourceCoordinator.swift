//
//  FeedSourceCoordinator.swift
//  Ghostwire
//
//  GW-261. Drives the registered `FeedSource`s and is the only writer into
//  `FeedCardStore` — one refresh loop per source, each on its own cadence, all
//  merged into the single ordered card set the notch row and the detached
//  window grid both read.
//
//  Failure policy: a source's last good cards SURVIVE a failed refresh. The
//  cards dim themselves via `FeedCard.isStale(refreshInterval:)` once refreshes
//  stop landing, so a flaky network degrades the feed instead of blanking it.
//
//  No pause-on-notch-closed: the detached window (GW-223) renders the same feed
//  while the notch is shut, so gating refreshes on notch state would silently
//  freeze that surface. Cadence is the throttle instead — 60s crypto, 15min
//  feeds — plus an immediate top-up when a surface opens onto stale cards.
//

import Combine
import Defaults
import Foundation
import Observation
import os

@Observable
@MainActor
final class FeedSourceCoordinator {
    static let shared = FeedSourceCoordinator()

    /// Last successful cards per source id. Merged in registration order so the
    /// feed's default layout is stable; the user's own order is layered on top
    /// by `FeedCardStore.reconcile`.
    private var cardsBySource: [String: [FeedCard]] = [:]
    private var sources: [any FeedSource] = []
    private var loops: [String: Task<Void, Never>] = [:]
    private var enabledCancellable: AnyCancellable?
    private var mcpConfigCancellable: AnyCancellable?

    private let store: FeedCardStore
    private let logger = os.Logger(subsystem: "com.ghostwire.notch", category: "FeedSourceCoordinator")

    init(store: FeedCardStore = .shared) {
        self.store = store
    }

    /// The built-in keyless catalog. Both are zero-setup and zero-permission,
    /// which is the whole point: a fresh install shows a real feed without the
    /// user connecting anything.
    static func builtInSources() -> [any FeedSource] {
        // Module master key (SettingsModule.feed) gates the whole catalog.
        guard Defaults[.feedSourcesEnabled] else { return [] }
        var built: [any FeedSource] = []
        // Local first: it needs nothing from the network, so it's the one source
        // guaranteed to have something to say.
        if Defaults[.feedLocalStatsSourceEnabled] { built.append(LocalStatsFeedSource()) }
        if Defaults[.feedCryptoSourceEnabled] {
            let symbols = Defaults[.feedCryptoSymbols]
            if !symbols.isEmpty { built.append(HyperliquidFeedSource(symbols: symbols)) }
        }
        if Defaults[.feedRSSSourceEnabled] {
            let feeds = Defaults[.feedRSSURLs].compactMap(URL.init(string:))
            if !feeds.isEmpty { built.append(RSSFeedSource(feeds: feeds)) }
        }
        return built
    }

    /// GW-214: one Source per MCP server that has at least one tool bound to the
    /// feed. Not "built-in" — these depend entirely on what the user connected
    /// and opted in, which is the point: this is the half of the feed that shows
    /// the user's OWN authenticated data rather than public numbers.
    ///
    /// A server with no bindings produces no Source at all, so a connected-but-
    /// unbound server never causes a background poll or a spawned subprocess.
    static func mcpSources(service: MCPClientService = .shared) -> [any FeedSource] {
        guard Defaults[.feedSourcesEnabled], Defaults[.feedMCPSourcesEnabled] else { return [] }
        let interval = TimeInterval(max(30, Defaults[.feedMCPRefreshSeconds]))
        return service.store.servers.compactMap { config -> (any FeedSource)? in
            guard config.isEnabled else { return nil }
            let bindings = config.feedBindings
            guard !bindings.isEmpty else { return nil }
            return MCPFeedSource(
                serverID: config.id,
                serverName: config.name,
                bindings: bindings,
                refreshInterval: interval,
                backend: service
            )
        }
    }

    /// Start (or restart) every enabled source. Safe to call again after a
    /// settings change — existing loops are cancelled first.
    /// `nil` resolves the built-in catalog plus the user's bound MCP servers —
    /// it can't be a default argument because that expression would be evaluated
    /// outside the actor.
    ///
    /// Also (re)binds the module master toggle, so flipping Feed off in the
    /// settings sidebar stops the loops immediately instead of at the next poll.
    func start(sources: [any FeedSource]? = nil) {
        if enabledCancellable == nil {
            // `dropFirst()`: Defaults.publisher emits the CURRENT value on
            // subscribe, so without it the first start() immediately re-entered
            // itself — every launch tore down the sources it had just created
            // and refetched them all. Only a real toggle should restart.
            enabledCancellable = Defaults.publisher(.feedSourcesEnabled)
                .dropFirst()
                .sink { [weak self] _ in
                    Task { @MainActor in self?.start() }
                }
        }
        // GW-214: rebuild when the MCP config changes. Sources are snapshotted
        // below, so without this a removed server leaves an orphan poll loop
        // publishing a "Not connected" card for something that no longer
        // exists, and an edited argument keeps calling with the old value.
        //
        // Debounced: the arguments field commits on focus loss as well as
        // Return, and add-then-connect fires twice in quick succession.
        if mcpConfigCancellable == nil {
            mcpConfigCancellable = MCPClientService.shared.feedConfigDidChange
                .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    Task { @MainActor in self?.start() }
                }
        }
        stop()
        let sources = sources ?? (Self.builtInSources() + Self.mcpSources())
        self.sources = sources
        // Every restart cancels in-flight fetches and re-runs them from scratch,
        // so a burst of restarts reads to the user as a feed stuck loading.
        logger.info(
            "start: \(sources.count) sources [\(sources.map(\.id).joined(separator: ", "), privacy: .public)]"
        )
        // Nothing enabled: drop the cards too, or the feed would keep showing
        // the values from just before the user switched the module off.
        if sources.isEmpty {
            cardsBySource.removeAll()
            publish()
            return
        }
        for source in sources {
            loops[source.id] = Task { [weak self] in
                await self?.runLoop(for: source)
            }
        }
    }

    func stop() {
        for loop in loops.values { loop.cancel() }
        loops.removeAll()
    }

    /// Refresh any source whose cards have gone stale. Called when a surface
    /// opens so the user isn't looking at a value from before the laptop slept.
    func refreshStaleSources(now: Date = Date()) {
        for source in sources {
            let cards = cardsBySource[source.id] ?? []
            let isStale = cards.isEmpty || cards.contains {
                $0.isStale(refreshInterval: source.refreshInterval, now: now)
            }
            guard isStale, loops["\(source.id).topup"] == nil else { continue }
            loops["\(source.id).topup"] = Task { [weak self] in
                await self?.refreshOnce(source)
                self?.loops["\(source.id).topup"] = nil
            }
        }
    }

    private func runLoop(for source: any FeedSource) async {
        while !Task.isCancelled {
            await refreshOnce(source)
            do {
                try await Task.sleep(for: .seconds(source.refreshInterval))
            } catch {
                return // cancelled
            }
        }
    }

    private func refreshOnce(_ source: any FeedSource) async {
        // Timed on the success path too. A polling subsystem that only logs
        // failures can't answer "why was the feed empty for two minutes" —
        // the interesting case is a refresh that SUCCEEDS but takes 90s.
        let started = Date()
        do {
            let cards = try await source.fetch()
            cardsBySource[source.id] = cards
            publish()
            logger.info(
                "source \(source.id, privacy: .public) refreshed in \(Int(Date().timeIntervalSince(started) * 1000))ms → \(cards.count) cards"
            )
        } catch {
            // Keep the previous cards; they'll dim on their own.
            logger.warning("source \(source.id, privacy: .public) refresh failed after \(Int(Date().timeIntervalSince(started) * 1000))ms: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func publish() {
        let merged = sources.flatMap { cardsBySource[$0.id] ?? [] }
        store.setCards(merged)
    }
}
