//
//  IdleStateRuleTests.swift
//  GhostwireTests
//
//  GW-199: idle home state. Both agents inactive 5h+ AND no live session →
//  idle (notch opens on Home; meter row dims). Any live session or activity
//  within the trailing 5H window keeps us Active.
//

import XCTest
@testable import Ghostwire

final class IdleStateRuleTests: XCTestCase {

    /// Fixed "now": 2026-06-04 12:00:00 UTC
    private let now = ISO8601DateFormatter().date(from: "2026-06-04T12:00:00Z")!

    private func ago(_ interval: TimeInterval) -> Date {
        now.addingTimeInterval(-interval)
    }

    private let hour: TimeInterval = 3600

    // MARK: - Active (not idle)

    func testLiveSessionIsActiveEvenWithoutActivityDates() {
        XCTAssertFalse(IdleStateRule.isIdle(
            now: now,
            claudeLastActivity: nil,
            codexLastActivity: nil,
            hasLiveSessions: true
        ))
    }

    func testLiveSessionIsActiveEvenWhenActivityIsStale() {
        XCTAssertFalse(IdleStateRule.isIdle(
            now: now,
            claudeLastActivity: ago(10 * hour),
            codexLastActivity: ago(10 * hour),
            hasLiveSessions: true
        ))
    }

    func testRecentClaudeActivityIsActive() {
        XCTAssertFalse(IdleStateRule.isIdle(
            now: now,
            claudeLastActivity: ago(1 * hour),
            codexLastActivity: nil,
            hasLiveSessions: false
        ))
    }

    func testRecentCodexActivityIsActive() {
        XCTAssertFalse(IdleStateRule.isIdle(
            now: now,
            claudeLastActivity: nil,
            codexLastActivity: ago(1 * hour),
            hasLiveSessions: false
        ))
    }

    func testActivityJustInsideWindowIsActive() {
        // 4h59m ago → still inside the 5H window
        XCTAssertFalse(IdleStateRule.isIdle(
            now: now,
            claudeLastActivity: ago(5 * hour - 60),
            codexLastActivity: nil,
            hasLiveSessions: false
        ))
    }

    // MARK: - Idle

    func testNoActivityNoSessionsIsIdle() {
        XCTAssertTrue(IdleStateRule.isIdle(
            now: now,
            claudeLastActivity: nil,
            codexLastActivity: nil,
            hasLiveSessions: false
        ))
    }

    func testBothAgentsStaleIsIdle() {
        XCTAssertTrue(IdleStateRule.isIdle(
            now: now,
            claudeLastActivity: ago(6 * hour),
            codexLastActivity: ago(8 * hour),
            hasLiveSessions: false
        ))
    }

    func testActivityExactlyAtThresholdIsIdle() {
        // exactly 5h ago → at the boundary, the window has elapsed
        XCTAssertTrue(IdleStateRule.isIdle(
            now: now,
            claudeLastActivity: ago(5 * hour),
            codexLastActivity: ago(5 * hour),
            hasLiveSessions: false
        ))
    }

    func testOneStaleOneRecentIsActive() {
        // Codex stale, Claude recent → still active (either agent keeps us up)
        XCTAssertFalse(IdleStateRule.isIdle(
            now: now,
            claudeLastActivity: ago(2 * hour),
            codexLastActivity: ago(9 * hour),
            hasLiveSessions: false
        ))
    }
}
