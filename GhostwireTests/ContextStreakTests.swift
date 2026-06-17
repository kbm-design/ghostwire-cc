//
//  ContextStreakTests.swift
//  GhostwireTests
//
//  GW-172 — the honesty rules of the ambient spine: capture filtering and
//  streak folding (extend-don't-append + max-gap). Pure, no AppKit/Defaults.
//

import XCTest
@testable import Ghostwire

final class ContextStreakTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    private func snap(_ bundleID: String, at offset: TimeInterval, idle: TimeInterval = 0) -> ContextSnapshot {
        ContextSnapshot(
            bundleID: bundleID,
            appName: bundleID,
            idleSeconds: idle,
            capturedAt: t0.addingTimeInterval(offset)
        )
    }

    // MARK: - Capture filter

    func testShouldCaptureRejectsEmptyLoginWindowAndDenylist() {
        XCTAssertFalse(ContextStreak.shouldCapture(bundleID: "", denylist: []))
        XCTAssertFalse(ContextStreak.shouldCapture(bundleID: "com.apple.loginwindow", denylist: []))
        XCTAssertFalse(ContextStreak.shouldCapture(bundleID: "com.apple.SecurityAgent", denylist: []))
        XCTAssertFalse(ContextStreak.shouldCapture(bundleID: "com.acme.app", denylist: ["com.acme.app"]))
        XCTAssertTrue(ContextStreak.shouldCapture(bundleID: "com.apple.dt.Xcode", denylist: ["com.acme.app"]))
    }

    // MARK: - Folding

    func testMatchingFingerprintExtendsInPlace() {
        var events = ContextStreak.folding([], with: snap("a", at: 0, idle: 1), maxGap: 180)
        events = ContextStreak.folding(events, with: snap("a", at: 90, idle: 5), maxGap: 180)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].start, t0)
        XCTAssertEqual(events[0].end, t0.addingTimeInterval(90))
        XCTAssertEqual(events[0].idleAtEnd, 5)
        XCTAssertEqual(events[0].wallSeconds, 90)
    }

    func testDifferentFingerprintStartsNewStreak() {
        var events = ContextStreak.folding([], with: snap("a", at: 0), maxGap: 180)
        events = ContextStreak.folding(events, with: snap("b", at: 30), maxGap: 180)

        XCTAssertEqual(events.map(\.bundleID), ["a", "b"])
    }

    func testSwitchClosesOutDepartingStreakToSwitchMoment() {
        // P2: a switch before the backstop tick must not record the departing
        // app as ~zero seconds — its streak closes out at the switch timestamp.
        var events = ContextStreak.folding([], with: snap("a", at: 0, idle: 0), maxGap: 180)
        events = ContextStreak.folding(events, with: snap("b", at: 30, idle: 0), maxGap: 180)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].end, t0.addingTimeInterval(30))  // a ran until the switch
        XCTAssertEqual(events[0].wallSeconds, 30)
        XCTAssertEqual(events[1].start, t0.addingTimeInterval(30))
    }

    func testSwitchAcrossLargeGapDoesNotExtendDepartingStreak() {
        // After a lock/sleep gap, the departing app must NOT absorb the absence.
        var events = ContextStreak.folding([], with: snap("a", at: 0), maxGap: 180)
        events = ContextStreak.folding(events, with: snap("b", at: 3_600), maxGap: 180)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].end, t0)  // a stays closed at its last sample
        XCTAssertEqual(events[1].start, t0.addingTimeInterval(3_600))
    }

    func testGapBeyondMaxStartsFreshStreakEvenForSameApp() {
        // A lock/sleep gap (1h) must not silently extend the prior streak.
        var events = ContextStreak.folding([], with: snap("a", at: 0), maxGap: 180)
        events = ContextStreak.folding(events, with: snap("a", at: 3_600), maxGap: 180)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].end, t0)
        XCTAssertEqual(events[1].start, t0.addingTimeInterval(3_600))
    }

    func testOutOfOrderSampleStartsFreshStreakRatherThanRewinding() {
        var events = ContextStreak.folding([], with: snap("a", at: 100), maxGap: 180)
        events = ContextStreak.folding(events, with: snap("a", at: 50), maxGap: 180)

        XCTAssertEqual(events.count, 2)
    }

    // MARK: - Derived time

    func testActiveSecondsBacksOutClampedIdle() {
        var events = ContextStreak.folding([], with: snap("a", at: 0, idle: 0), maxGap: 180)
        events = ContextStreak.folding(events, with: snap("a", at: 100, idle: 40), maxGap: 180)
        XCTAssertEqual(events[0].activeSeconds, 60)

        // Idle larger than the streak's own wall span clamps to zero, never negative.
        var clamped = ContextStreak.folding([], with: snap("b", at: 0, idle: 0), maxGap: 180)
        clamped = ContextStreak.folding(clamped, with: snap("b", at: 10, idle: 9_999), maxGap: 180)
        XCTAssertEqual(clamped[0].activeSeconds, 0)
    }
}
