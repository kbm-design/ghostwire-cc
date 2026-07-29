//
//  ContextProfileTests.swift
//  GhostwireTests
//
//  GW-182 — deriving "what is the user doing" from the GW-172 streak log. Pure:
//  no AppKit, no Defaults, no clock. Each test pins one of the three rules that
//  exist to prevent a specific wrong answer (dwell over visits, recency decay,
//  settle before believing a switch).
//

import XCTest
@testable import Ghostwire

final class ContextProfileTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    // Symbolic bundle IDs + a stub classifier. The profile rules must be
    // provable without depending on which apps are installed on the machine
    // running the tests — Safari, for instance, declares `productivity` and so
    // resolves to `.other` in real life.
    private let xcode = "test.editor"
    private let safari = "test.reader"
    private let slack = "test.chat"
    private let tradingView = "test.charts"

    private func stub(_ bundleID: String) -> AppCategory {
        switch bundleID {
        case "test.editor": return .coding
        case "test.reader": return .research
        case "test.chat": return .comms
        case "test.charts": return .finance
        default: return .other
        }
    }

    private func event(
        _ bundleID: String,
        from: TimeInterval,
        to: TimeInterval,
        idle: TimeInterval = 0
    ) -> ContextEvent {
        ContextEvent(
            id: UUID(),
            bundleID: bundleID,
            appName: bundleID,
            start: t0.addingTimeInterval(from),
            end: t0.addingTimeInterval(to),
            idleAtEnd: idle
        )
    }

    private func now(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

    // MARK: - Category map (pure: Apple's constant → ours)

    func testDeclaredCategoriesMapToOurs() {
        XCTAssertEqual(AppCategoryMap.category(forDeclaredType: "public.app-category.developer-tools"), .coding)
        XCTAssertEqual(AppCategoryMap.category(forDeclaredType: "public.app-category.finance"), .finance)
        XCTAssertEqual(AppCategoryMap.category(forDeclaredType: "public.app-category.graphics-design"), .design)
        XCTAssertEqual(AppCategoryMap.category(forDeclaredType: "public.app-category.social-networking"), .comms)
        XCTAssertEqual(AppCategoryMap.category(forDeclaredType: "public.app-category.news"), .research)
        XCTAssertEqual(AppCategoryMap.category(forDeclaredType: "public.app-category.music"), .entertainment)
    }

    func testUndeclaredOrJunkDrawerCategoriesYieldNoOpinion() {
        // The two biggest buckets on a real Mac hold everything from a browser
        // to a menu-bar toggle — Safari itself declares `productivity`. Mapping
        // them would manufacture confidence we don't have.
        XCTAssertEqual(AppCategoryMap.category(forDeclaredType: "public.app-category.productivity"), .other)
        XCTAssertEqual(AppCategoryMap.category(forDeclaredType: "public.app-category.utilities"), .other)
        XCTAssertEqual(AppCategoryMap.category(forDeclaredType: "public.app-category.business"), .other)
        XCTAssertEqual(AppCategoryMap.category(forDeclaredType: "public.app-category.somethingNew"), .other)
        XCTAssertEqual(AppCategoryMap.category(forDeclaredType: nil), .other)
    }

    func testBareCategoryNameWithoutApplePrefixStillMaps() {
        XCTAssertEqual(AppCategoryMap.category(forDeclaredType: "developer-tools"), .coding)
    }

    func testLookupOfAnUninstalledBundleIDIsSilent() {
        XCTAssertEqual(AppCategoryMap.category(for: "com.acme.definitely-not-installed"), .other)
        XCTAssertEqual(AppCategoryMap.category(for: ""), .other)
    }

    // MARK: - Dwell over visits

    func testLongDwellOutweighsRepeatedShortVisits() {
        // 30 min in Xcode vs three 20-second bounces through Slack, all recent.
        let events = [
            event(xcode, from: 0, to: 1_800),
            event(slack, from: 1_800, to: 1_820),
            event(xcode, from: 1_820, to: 1_840),
            event(slack, from: 1_840, to: 1_860),
            event(xcode, from: 1_860, to: 1_880),
            event(slack, from: 1_880, to: 1_900),
        ]
        let profile = ContextProfile.build(events: events, now: now(1_900), categorize: stub)
        XCTAssertGreaterThan(profile.weights[.coding] ?? 0, profile.weights[.comms] ?? 0)
    }

    func testIdleTimeIsBackedOutOfDwell() {
        // Two equal-length streaks; the second was mostly AFK, so it must weigh
        // less despite ending more recently.
        let active = ContextProfile.build(
            events: [event(xcode, from: 0, to: 600, idle: 0)], now: now(600), categorize: stub
        )
        let afk = ContextProfile.build(
            events: [event(xcode, from: 0, to: 600, idle: 590)], now: now(600), categorize: stub
        )
        // Both normalize to 1.0 in isolation — compare them competing instead.
        XCTAssertEqual(active.weights[.coding] ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(afk.weights[.coding] ?? 0, 1, accuracy: 0.0001)

        let mixed = ContextProfile.build(
            events: [
                event(safari, from: 0, to: 600, idle: 0),      // 600s active
                event(xcode, from: 600, to: 1_200, idle: 590), // 10s active
            ],
            now: now(1_200),
            categorize: stub,
            frontmostBoost: 0  // isolate dwell from the frontmost term
        )
        XCTAssertGreaterThan(mixed.weights[.research] ?? 0, mixed.weights[.coding] ?? 0)
    }

    // MARK: - Recency decay

    func testRecentStreakOutweighsAnEqualOlderOne() {
        // Equal 5-minute streaks, one 25 minutes ago and one just now.
        let events = [
            event(safari, from: 0, to: 300),
            event(xcode, from: 1_500, to: 1_800),
        ]
        let profile = ContextProfile.build(events: events, now: now(1_800), categorize: stub, frontmostBoost: 0)
        XCTAssertGreaterThan(profile.weights[.coding] ?? 0, profile.weights[.research] ?? 0)
    }

    func testEventsOutsideTheLookbackWindowAreIgnored() {
        // A long yesterday-ish streak entirely before the window start.
        let events = [
            event(slack, from: 0, to: 3_000),
            event(xcode, from: 5_400, to: 5_500),
        ]
        let profile = ContextProfile.build(events: events, now: now(5_500), categorize: stub, lookback: 1_800)
        XCTAssertNil(profile.weights[.comms])
        XCTAssertEqual(profile.weights[.coding] ?? 0, 1, accuracy: 0.0001)
    }

    // MARK: - Settle

    func testFreshSwitchDoesNotImmediatelyBecomeTheSettledApp() {
        // 30 min in Xcode, then 5 seconds in Slack — well under the settle
        // window. The user has not "switched to Slack" in any meaningful sense.
        let events = [
            event(xcode, from: 0, to: 1_800),
            event(slack, from: 1_800, to: 1_805),
        ]
        let profile = ContextProfile.build(events: events, now: now(1_805), categorize: stub)
        XCTAssertEqual(profile.settledBundleID, xcode)
    }

    func testAppBecomesSettledOnceItHoldsFocusLongEnough() {
        let events = [
            event(xcode, from: 0, to: 1_800),
            event(slack, from: 1_800, to: 1_830),  // 30s ≥ 20s settle
        ]
        let profile = ContextProfile.build(events: events, now: now(1_830), categorize: stub)
        XCTAssertEqual(profile.settledBundleID, slack)
    }

    // MARK: - The live streak (Codex review, medium #2)
    //
    // `ContextStreak.folding` records a brand-new streak with `start == end`,
    // and only the next capture — an app switch, or the observer's 90s backstop
    // — advances that `end`. Every test above hand-builds streaks with a
    // realistic span, which is exactly the shape a live app switch does NOT
    // have, so none of them could catch this.

    func testJustSwitchedAppSettlesOnTimeWithoutWaitingForTheBackstop() {
        // Slack activated 25s ago and nothing has extended its streak yet.
        // Settle is 20s, so it must already count as the user's context — not
        // wait up to 90s for a backstop tick.
        let events = [
            event(xcode, from: 0, to: 1_800),
            event(slack, from: 1_800, to: 1_800),  // zero-length: just activated
        ]
        let profile = ContextProfile.build(events: events, now: now(1_825), categorize: stub)
        XCTAssertEqual(profile.settledBundleID, slack)
    }

    func testLiveStreakStillRespectsTheSettleWindow() {
        // Same shape, only 5s in — the settle window must still hold the
        // previous app, or this fix would have traded one bug for churn.
        let events = [
            event(xcode, from: 0, to: 1_800),
            event(slack, from: 1_800, to: 1_800),
        ]
        let profile = ContextProfile.build(events: events, now: now(1_805), categorize: stub)
        XCTAssertEqual(profile.settledBundleID, xcode)
    }

    func testLiveStreakAccruesDwellBeforeTheBackstopLands() {
        // A zero-length trailing streak used to contribute no dwell at all, so
        // the app the user is in right now was invisible to the profile.
        let events = [event(xcode, from: 0, to: 0)]
        let profile = ContextProfile.build(
            events: events, now: now(120), categorize: stub, frontmostBoost: 0
        )
        XCTAssertEqual(profile.weights[.coding] ?? 0, 1, accuracy: 0.0001)
    }

    func testOnlyTheNewestStreakGetsALiveEdge() {
        // An older streak is closed — extending it would invent dwell that
        // never happened.
        let closed = event(xcode, from: 0, to: 100)
        XCTAssertEqual(
            ContextProfile.effectiveEnd(of: closed, isNewest: false, now: now(150), maxGap: 180),
            closed.end
        )
        XCTAssertEqual(
            ContextProfile.effectiveEnd(of: closed, isNewest: true, now: now(150), maxGap: 180),
            now(150)
        )
    }

    func testALiveEdgeIsNotExtendedPastMaxGap() {
        // Beyond max-gap the log has stopped; we don't get to claim the user
        // has been sitting in that app the whole time.
        let stale = event(xcode, from: 0, to: 100)
        XCTAssertEqual(
            ContextProfile.effectiveEnd(of: stale, isNewest: true, now: now(1_000), maxGap: 180),
            stale.end
        )
    }

    func testSettledAppIsNilWhenTheLogHasGoneStale() {
        // Nothing captured for an hour — asleep, away, or capture disabled. We
        // don't get to claim knowledge of the present.
        let events = [event(xcode, from: 0, to: 1_800)]
        let profile = ContextProfile.build(events: events, now: now(5_400), categorize: stub)
        XCTAssertNil(profile.settledBundleID)
    }

    func testFrontmostBoostLiftsTheSettledAppsCategory() {
        // Equal dwell in both; the settled one must come out ahead.
        let events = [
            event(safari, from: 0, to: 600),
            event(xcode, from: 600, to: 1_200),
        ]
        let withoutBoost = ContextProfile.build(
            events: events, now: now(1_200), categorize: stub, halfLife: .greatestFiniteMagnitude, frontmostBoost: 0
        )
        XCTAssertEqual(withoutBoost.weights[.coding] ?? 0, withoutBoost.weights[.research] ?? 0,
                       accuracy: 0.0001)

        let withBoost = ContextProfile.build(
            events: events, now: now(1_200), categorize: stub, halfLife: .greatestFiniteMagnitude
        )
        XCTAssertGreaterThan(withBoost.weights[.coding] ?? 0, withBoost.weights[.research] ?? 0)
    }

    // MARK: - Return from away

    func testReturnFromAwayFiresAfterAGapBeyondMaxGap() {
        let events = [
            event(xcode, from: 0, to: 1_000),
            event(safari, from: 2_000, to: 2_010),  // 1000s gap ≫ maxGap
        ]
        let profile = ContextProfile.build(events: events, now: now(2_010), categorize: stub)
        XCTAssertTrue(profile.returningFromAway)
    }

    func testContiguousSwitchIsNotAReturnFromAway() {
        let events = [
            event(xcode, from: 0, to: 1_000),
            event(safari, from: 1_000, to: 1_010),
        ]
        let profile = ContextProfile.build(events: events, now: now(1_010), categorize: stub)
        XCTAssertFalse(profile.returningFromAway)
    }

    func testReturnFromAwayExpiresOnceTheUserHasSettledBackIn() {
        let events = [
            event(xcode, from: 0, to: 1_000),
            event(safari, from: 2_000, to: 2_800),
        ]
        // The gap qualifies, but the streak started 800s ago — they're back.
        let profile = ContextProfile.build(events: events, now: now(2_800), categorize: stub)
        XCTAssertFalse(profile.returningFromAway)
    }

    func testFirstEverStreakCountsAsAFreshSession() {
        let profile = ContextProfile.build(
            events: [event(xcode, from: 0, to: 10)], now: now(10), categorize: stub
        )
        XCTAssertTrue(profile.returningFromAway)
    }

    // MARK: - Degradation

    func testEmptyLogYieldsNoSignal() {
        let profile = ContextProfile.build(events: [], now: now(0), categorize: stub)
        XCTAssertFalse(profile.hasSignal)
        XCTAssertNil(profile.settledBundleID)
        XCTAssertEqual(profile.match([.coding: 1]), 0)
    }

    func testUnmappedAppsProduceNoSignal() {
        // An app we've never categorised must not invent an opinion.
        let events = [event("com.acme.unknown", from: 0, to: 1_800)]
        let profile = ContextProfile.build(events: events, now: now(1_800), categorize: stub)
        XCTAssertFalse(profile.hasSignal)
        XCTAssertEqual(profile.settledBundleID, "com.acme.unknown")
    }

    func testWeightsAreNormalised() {
        let events = [
            event(xcode, from: 0, to: 600),
            event(safari, from: 600, to: 900),
            event(slack, from: 900, to: 1_000),
        ]
        let profile = ContextProfile.build(events: events, now: now(1_000), categorize: stub)
        XCTAssertEqual(profile.weights.values.reduce(0, +), 1, accuracy: 0.0001)
    }

    // MARK: - Matching

    func testMatchIsTheDotProductOfTheTwoDistributions() {
        let events = [event(xcode, from: 0, to: 1_800)]
        let profile = ContextProfile.build(events: events, now: now(1_800), categorize: stub)
        XCTAssertEqual(profile.match([.coding: 1.0]), 1, accuracy: 0.0001)
        XCTAssertEqual(profile.match([.coding: 0.5]), 0.5, accuracy: 0.0001)
        XCTAssertEqual(profile.match([.finance: 1.0]), 0, accuracy: 0.0001)
        XCTAssertEqual(profile.match([:]), 0, accuracy: 0.0001)
    }
}
