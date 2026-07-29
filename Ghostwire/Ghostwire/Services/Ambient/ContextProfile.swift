//
//  ContextProfile.swift
//  Ghostwire
//
//  GW-182 — "what is the user doing", derived from the GW-172 streak log. Pure:
//  a `[ContextEvent]` in, a normalized category distribution out, no AppKit and
//  no clock of its own, so every rule below is unit-testable.
//
//  Three rules do the work, and each exists to stop a specific wrong answer:
//
//   • Dwell, not visits. Weight is `activeSeconds` within the lookback window
//     (idle backed out, the same approximation `ContextEvent.activeSeconds`
//     makes), so forty minutes in an editor outweighs six bounces through Slack.
//   • Recency decay. A 10-minute half-life on each streak's trailing edge, so
//     "this morning" fades under "the last ten minutes" without a hard cutoff.
//   • Settle. A just-switched-to app does NOT get the frontmost boost until it
//     has held focus for `settle` seconds; until then the previous streak keeps
//     it. Without this, alt-tabbing through three apps would reshuffle the notch
//     three times in two seconds — motion in peripheral vision with no meaning
//     behind it, which is the exact failure calm tech is defined against.
//
//  "Derive the flow, don't replay the log": callers get this aggregate, never
//  raw events. Local-only, like everything else on this spine.
//

import Foundation

/// A normalized read of the user's current working context.
struct ContextProfile: Equatable, Sendable {

    /// The app considered "what the user is in" — nil when the log has gone
    /// stale (asleep, away, capture disabled). Held through the settle window,
    /// so this is not simply the newest streak.
    let settledBundleID: String?

    /// Category shares, summing to 1. Empty when there is no usable signal.
    let weights: [AppCategory: Double]

    /// The max-gap rule just fired on a fresh streak — the user stepped away and
    /// came back. Ranking reads this as "tell me what changed while I was gone".
    let returningFromAway: Bool

    /// No signal: unknown context, no affinity, ranking falls back to user order.
    static let empty = ContextProfile(settledBundleID: nil, weights: [:], returningFromAway: false)

    /// Whether this profile carries enough to say anything at all.
    var hasSignal: Bool { !weights.isEmpty }

    /// How well a Source's declared affinity matches the current context: the
    /// dot product of the two distributions. 0…1, since `weights` sums to 1 and
    /// affinity values are themselves 0…1.
    func match(_ affinity: [AppCategory: Double]) -> Double {
        guard !affinity.isEmpty else { return 0 }
        let sum = weights.reduce(0.0) { total, entry in
            total + entry.value * (affinity[entry.key] ?? 0)
        }
        return min(1, max(0, sum))
    }

    // MARK: - Derivation

    /// Default lookback — long enough to know what the session is about, short
    /// enough that yesterday's work never colours today's notch.
    static let defaultLookback: TimeInterval = 1_800

    /// Half-life of a streak's contribution, measured from its trailing edge.
    static let defaultHalfLife: TimeInterval = 600

    /// How long a newly-activated app must hold focus before it counts as the
    /// user's context. Below the observer's 90s backstop on purpose — this
    /// filters alt-tab noise, it doesn't wait for a poll.
    static let defaultSettle: TimeInterval = 20

    /// Share added to the settled app's category before re-normalizing. Being in
    /// an app right now matters beyond the seconds banked in it — otherwise a
    /// freshly-opened app could never outrank the morning's long streak.
    static let defaultFrontmostBoost: Double = 0.35

    /// A streak younger than this can still count as a return from away.
    static let defaultAwayWindow: TimeInterval = 300

    /// Mirrors `ContextStore.maxGap` — kept as a parameter rather than a
    /// reference because that constant is main-actor isolated and this is not.
    static let defaultMaxGap: TimeInterval = 180

    /// Build a profile from the streak log (oldest-first, as `ContextStore`
    /// keeps it). Pure — both `now` and the classifier are injected, so the
    /// rules below are exercisable without depending on which apps happen to be
    /// installed on the machine running the tests.
    static func build(
        events: [ContextEvent],
        now: Date,
        categorize: (String) -> AppCategory = AppCategoryMap.category(for:),
        lookback: TimeInterval = defaultLookback,
        halfLife: TimeInterval = defaultHalfLife,
        settle: TimeInterval = defaultSettle,
        frontmostBoost: Double = defaultFrontmostBoost,
        awayWindow: TimeInterval = defaultAwayWindow,
        maxGap: TimeInterval = defaultMaxGap
    ) -> ContextProfile {
        let settled = resolveSettledBundleID(events: events, now: now, settle: settle, maxGap: maxGap)
        let away = detectReturnFromAway(events: events, now: now, awayWindow: awayWindow, maxGap: maxGap)

        var raw: [AppCategory: Double] = [:]
        let windowStart = now.addingTimeInterval(-lookback)
        let newestIndex = events.count - 1
        for (index, event) in events.enumerated() {
            // The live streak's edge is `now`, not its recorded `end` — see
            // `effectiveEnd`. Without this the app the user is in right now
            // contributes zero dwell until a backstop tick lands.
            let end = Self.effectiveEnd(
                of: event, isNewest: index == newestIndex, now: now, maxGap: maxGap
            )
            let from = max(event.start, windowStart)
            let to = min(end, now)
            let overlap = to.timeIntervalSince(from)
            guard overlap > 0 else { continue }
            // Same idle approximation as ContextEvent.activeSeconds, applied to
            // the windowed slice: the trailing idle sample can't exceed it.
            let active = overlap - min(event.idleAtEnd, overlap)
            guard active > 0 else { continue }
            let decay = pow(0.5, max(0, now.timeIntervalSince(end)) / halfLife)
            let category = categorize(event.bundleID)
            guard category != .other else { continue }  // unmapped apps stay silent
            raw[category, default: 0] += active * decay
        }

        let total = raw.values.reduce(0, +)
        guard total > 0 else {
            // No dwell to speak of. A settled app still says something on its
            // own — a fresh launch into Xcode is context even with zero banked
            // seconds — so give its category the floor rather than nothing.
            let category = settled.map(categorize) ?? .other
            guard category != .other else {
                return ContextProfile(
                    settledBundleID: settled, weights: [:], returningFromAway: away
                )
            }
            return ContextProfile(
                settledBundleID: settled, weights: [category: 1], returningFromAway: away
            )
        }

        var weights = raw.mapValues { $0 / total }
        if let settled {
            let category = categorize(settled)
            if category != .other { weights[category, default: 0] += frontmostBoost }
        }
        let boosted = weights.values.reduce(0, +)
        weights = weights.mapValues { $0 / boosted }

        return ContextProfile(settledBundleID: settled, weights: weights, returningFromAway: away)
    }

    // MARK: - Rules (pure, exercised directly by tests)

    /// The trailing edge to reason about for a streak, which is NOT always its
    /// recorded `end`.
    ///
    /// `ContextStreak.folding` creates a new streak with `start == end`, and
    /// that `end` only advances on the next capture — the next app switch, or
    /// the observer's 90s backstop. Taking `end` literally means a
    /// just-switched-to app has zero wall time and zero dwell until a backstop
    /// tick lands, so a 20s settle window could not actually fire for up to 90
    /// seconds and the profile would keep naming the app the user just left.
    ///
    /// So for the NEWEST streak, while it's still current (not past `maxGap`,
    /// which is the store's own "this log is still live" test), the effective
    /// edge is `now`. Older streaks are closed and keep their recorded `end`.
    ///
    /// `idleAtEnd` is deliberately not re-derived: it was sampled at `end`, and
    /// the same choice is made in `ContextStreak.folding` when it closes a
    /// departing streak. Extending the edge without touching idle can only
    /// credit the streak with active time it may not have had, bounded by
    /// `maxGap`.
    static func effectiveEnd(
        of event: ContextEvent, isNewest: Bool, now: Date, maxGap: TimeInterval
    ) -> Date {
        guard isNewest, now >= event.end, now.timeIntervalSince(event.end) <= maxGap else {
            return event.end
        }
        return now
    }

    /// The app the user is considered to be in. Nil when the newest streak is
    /// older than `maxGap` — the log has stopped, so we don't get to claim
    /// knowledge of the present. During the settle window the PREVIOUS streak
    /// holds, so a passing alt-tab never becomes "the user's context".
    static func resolveSettledBundleID(
        events: [ContextEvent], now: Date, settle: TimeInterval, maxGap: TimeInterval
    ) -> String? {
        guard let last = events.last else { return nil }
        // Staleness uses the RECORDED end — "has anything been captured lately"
        // is exactly what `end` answers, and extending it here would claim the
        // log is live when it has stopped.
        guard now.timeIntervalSince(last.end) <= maxGap else { return nil }
        // Settle uses the EFFECTIVE end, so a still-running streak accrues wall
        // time in real time rather than in 90-second backstop jumps.
        let held = effectiveEnd(of: last, isNewest: true, now: now, maxGap: maxGap)
            .timeIntervalSince(last.start)
        if held >= settle { return last.bundleID }
        // Not settled yet — hold the app it was switched away from, but only if
        // that switch was contiguous (otherwise there is nothing to hold).
        if let previous = events.dropLast().last,
           last.start.timeIntervalSince(previous.end) <= maxGap {
            return previous.bundleID
        }
        return last.bundleID
    }

    /// True when the newest streak is young AND the gap before it exceeded
    /// max-gap — i.e. the store's own definition of an absence just ended. An
    /// empty log with a young streak counts too: that's a fresh session.
    static func detectReturnFromAway(
        events: [ContextEvent], now: Date, awayWindow: TimeInterval, maxGap: TimeInterval
    ) -> Bool {
        guard let last = events.last else { return false }
        guard now.timeIntervalSince(last.start) <= awayWindow else { return false }
        guard let previous = events.dropLast().last else { return true }
        return last.start.timeIntervalSince(previous.end) > maxGap
    }
}
