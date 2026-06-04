//
//  AlertHistoryStoreTests.swift
//  GhostwireTests
//
//  GW-144: alert-history pruning (GW-139 spec: 100 entries / 7 days,
//  configurable). Pure helper only — recording/persistence are thin.
//

import Defaults
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

/// Persistence behavior (review F6/F7): load salvages corrupt items and
/// writes the enforced limits back to disk.
@MainActor
final class AlertHistoryStorePersistenceTests: XCTestCase {

    private var tempURL: URL!
    private var savedMaxEntries: Int!
    private var savedMaxAgeDays: Int!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alert-history-tests-\(UUID().uuidString)")
            .appendingPathComponent("alert-history.json")
        savedMaxEntries = Defaults[.alertHistoryMaxEntries]
        savedMaxAgeDays = Defaults[.alertHistoryMaxAgeDays]
    }

    override func tearDown() {
        Defaults[.alertHistoryMaxEntries] = savedMaxEntries
        Defaults[.alertHistoryMaxAgeDays] = savedMaxAgeDays
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
        super.tearDown()
    }

    private func write(_ json: String) throws {
        try FileManager.default.createDirectory(
            at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try json.data(using: .utf8)!.write(to: tempURL)
    }

    private func alertJSON(id: UUID = UUID(), date: Date) -> String {
        let iso = ISO8601DateFormatter().string(from: date)
        return #"{"id":"\#(id.uuidString)","date":"\#(iso)","agent":"claude","sessionId":"s1","kind":"permission","detail":null}"#
    }

    func testLoadSalvagesCorruptItems() throws {
        // One well-formed entry, one wrong-shape object: load keeps the
        // good one instead of discarding the whole file (F7).
        try write("[\(alertJSON(date: Date())),{\"bogus\":true}]")

        let store = AlertHistoryStore(fileURL: tempURL)

        XCTAssertEqual(store.alerts.count, 1)
        XCTAssertEqual(store.alerts.first?.kind, "permission")
    }

    func testLoadWritesEnforcedCapBackToDisk() throws {
        // Three entries on disk, cap of 25 by age leaves only the fresh one
        // (two are 8 days old, default max age 7d): the pruned file must be
        // persisted even with no subsequent record() (F6).
        Defaults[.alertHistoryMaxEntries] = 25
        Defaults[.alertHistoryMaxAgeDays] = 7
        let stale = Date().addingTimeInterval(-8 * 86_400)
        try write("[\(alertJSON(date: stale)),\(alertJSON(date: stale)),\(alertJSON(date: Date()))]")

        let store = AlertHistoryStore(fileURL: tempURL)
        AlertHistoryStore.ioQueue.sync {}  // drain the async write

        XCTAssertEqual(store.alerts.count, 1)
        let onDisk = try Data(contentsOf: tempURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode([AgentAlert].self, from: onDisk).count, 1)
    }

    func testRecordPersistsAtomicallyOrderedWrites() throws {
        Defaults[.alertHistoryMaxEntries] = 25
        Defaults[.alertHistoryMaxAgeDays] = 7
        let store = AlertHistoryStore(fileURL: tempURL)

        store.record(agent: "codex", sessionId: "s2", kind: "ready")
        store.record(agent: "claude", sessionId: "s3", kind: "permission", detail: "Bash")
        AlertHistoryStore.ioQueue.sync {}

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let onDisk = try decoder.decode([AgentAlert].self, from: Data(contentsOf: tempURL))
        XCTAssertEqual(onDisk.map(\.kind), ["ready", "permission"])
    }
}
