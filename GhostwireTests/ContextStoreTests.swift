//
//  ContextStoreTests.swift
//  GhostwireTests
//
//  GW-172 — context store: pure retention pruning + persistence behavior
//  (per-day shards, salvage-on-load, defensive loginwindow filter, session-only
//  RAM-only).
//

import Defaults
import XCTest
@testable import Ghostwire

// MARK: - Pure pruning

final class ContextStorePruneTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func event(startAgo: TimeInterval, durationSeconds: TimeInterval = 60) -> ContextEvent {
        let start = now.addingTimeInterval(-startAgo)
        return ContextEvent(
            id: UUID(), bundleID: "com.acme.app", appName: "Acme",
            start: start, end: start.addingTimeInterval(durationSeconds), idleAtEnd: 0
        )
    }

    func testDropsStreaksOlderThanMaxAge() {
        let fresh = event(startAgo: 3_600)
        let stale = event(startAgo: 40 * 86_400)
        let result = ContextStore.pruned([stale, fresh], maxAge: 30 * 86_400, maxCount: 2_000, now: now)
        XCTAssertEqual(result, [fresh])
    }

    func testKeepsOngoingStreakWhoseEndIsInWindow() {
        // start is just outside the window, but its trailing edge is inside.
        let cutoff = 86_400.0
        let ongoing = ContextEvent(
            id: UUID(), bundleID: "com.acme.app", appName: "Acme",
            start: now.addingTimeInterval(-cutoff - 100),
            end: now.addingTimeInterval(-10), idleAtEnd: 0
        )
        let result = ContextStore.pruned([ongoing], maxAge: cutoff, maxCount: 2_000, now: now)
        XCTAssertEqual(result, [ongoing])
    }

    func testForeverKeepsEverythingButRingCapApplies() {
        let events = (0..<10).map { event(startAgo: TimeInterval(10 - $0)) }
        let kept = ContextStore.pruned(events, maxAge: nil, maxCount: 3, now: now)
        XCTAssertEqual(kept, Array(events.suffix(3)))
    }
}

// MARK: - Persistence

@MainActor
final class ContextStorePersistenceTests: XCTestCase {

    private var tempDir: URL!
    private var savedRetention: AmbientRetention!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambient-tests-\(UUID().uuidString)", isDirectory: true)
        savedRetention = Defaults[.ambientRetention]
        Defaults[.ambientRetention] = .days30
    }

    override func tearDown() {
        Defaults[.ambientRetention] = savedRetention
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func snap(_ bundleID: String, at date: Date, idle: TimeInterval = 0) -> ContextSnapshot {
        ContextSnapshot(bundleID: bundleID, appName: bundleID, idleSeconds: idle, capturedAt: date)
    }

    func testRecordPersistsAndReloads() {
        let store = ContextStore(directory: tempDir)
        store.record(snap("com.acme.app", at: Date()))
        ContextStore.ioQueue.sync {}

        let reloaded = ContextStore(directory: tempDir)
        XCTAssertEqual(reloaded.events.count, 1)
        XCTAssertEqual(reloaded.events.first?.bundleID, "com.acme.app")
    }

    func testLoadFiltersLoginWindowDefensively() throws {
        // A shard that somehow contains a loginwindow event must not surface it.
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter().string(from: Date())
        let json = """
        [{"id":"\(UUID().uuidString)","bundleID":"com.apple.loginwindow","appName":"login",\
        "start":"\(iso)","end":"\(iso)","idleAtEnd":0}]
        """
        let url = tempDir.appendingPathComponent("2099-01-01.json")
        try json.data(using: .utf8)!.write(to: url)

        let store = ContextStore(directory: tempDir)
        XCTAssertTrue(store.events.isEmpty)
    }

    func testSessionOnlyKeepsInMemoryButWritesNothing() {
        Defaults[.ambientRetention] = .sessionOnly
        let store = ContextStore(directory: tempDir)
        store.record(snap("com.acme.app", at: Date()))
        ContextStore.ioQueue.sync {}

        XCTAssertEqual(store.events.count, 1)  // RAM has it
        let shards = (try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(shards.filter { $0.pathExtension == "json" }.isEmpty)  // disk does not
    }

    func testDeleteAllDataClearsMemoryAndDisk() {
        let store = ContextStore(directory: tempDir)
        store.record(snap("com.acme.app", at: Date()))
        ContextStore.ioQueue.sync {}

        store.deleteAllData()
        ContextStore.ioQueue.sync {}

        XCTAssertTrue(store.events.isEmpty)
        let shards = (try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(shards.filter { $0.pathExtension == "json" }.isEmpty)
    }
}
