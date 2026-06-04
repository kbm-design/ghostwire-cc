//
//  AlertHistoryStoreTests.swift
//  GhostwireTests
//
//  GW-144: alert-history pruning (GW-139 spec: 100 entries / 7 days,
//  configurable). Pure helper only — recording/persistence are thin.
//

import XCTest
@testable import Ghostwire

final class AlertHistoryStoreTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func alert(ageSeconds: TimeInterval, kind: String = "permission") -> AgentAlert {
        AgentAlert(
            id: UUID(),
            date: now.addingTimeInterval(-ageSeconds),
            agent: "claude",
            sessionId: "s1",
            kind: kind,
            detail: nil
        )
    }

    func testDropsEntriesOlderThanMaxAge() {
        let fresh = alert(ageSeconds: 3_600)
        let stale = alert(ageSeconds: 8 * 86_400)

        let result = AlertHistoryStore.pruned(
            [stale, fresh], maxEntries: 100, maxAge: 7 * 86_400, now: now
        )

        XCTAssertEqual(result, [fresh])
    }

    func testCapsToNewestMaxEntries() {
        // 5 alerts, newest last after sorting; cap 3 keeps the 3 newest.
        let alerts = (0..<5).map { alert(ageSeconds: TimeInterval(100 - $0)) }

        let result = AlertHistoryStore.pruned(
            alerts, maxEntries: 3, maxAge: 7 * 86_400, now: now
        )

        XCTAssertEqual(result, Array(alerts.suffix(3)))
    }

    func testSortsOldestFirst() {
        let older = alert(ageSeconds: 500)
        let newer = alert(ageSeconds: 5)

        let result = AlertHistoryStore.pruned(
            [newer, older], maxEntries: 100, maxAge: 86_400, now: now
        )

        XCTAssertEqual(result, [older, newer])
    }

    func testBothLimitsApply() {
        let stale = alert(ageSeconds: 2 * 86_400)
        let alerts = [stale] + (0..<4).map { alert(ageSeconds: TimeInterval(50 - $0)) }

        // Age drops `stale`; entry cap then trims 4 → 2.
        let result = AlertHistoryStore.pruned(
            alerts, maxEntries: 2, maxAge: 86_400, now: now
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertFalse(result.contains(stale))
    }

    func testZeroOrNegativeMaxEntriesYieldsEmpty() {
        let alerts = [alert(ageSeconds: 10)]
        XCTAssertTrue(AlertHistoryStore.pruned(alerts, maxEntries: 0, maxAge: 86_400, now: now).isEmpty)
        XCTAssertTrue(AlertHistoryStore.pruned(alerts, maxEntries: -1, maxAge: 86_400, now: now).isEmpty)
    }
}
