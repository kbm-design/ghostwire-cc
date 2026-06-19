//
//  ToolUsageStoreTests.swift
//  GhostwireTests
//
//  GW-184: the gateway logs each tool call's recency+frequency so the working
//  set can be recomputed. These tests drive the persisted store directly via a
//  temp file — no gateway, no transport.
//

import XCTest

@testable import Ghostwire

final class ToolUsageStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostwire-tool-usage-\(UUID().uuidString).json")
    }

    func testRecordIncrementsCountAndSetsLastUsed() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let t0 = Date(timeIntervalSince1970: 1000)
        let store = ToolUsageStore(storeURL: url, now: { t0 })

        await store.record("linear_create_issue")
        await store.record("linear_create_issue")

        let snap = await store.snapshot()
        XCTAssertEqual(snap["linear_create_issue"]?.count, 2)
        XCTAssertEqual(snap["linear_create_issue"]?.lastUsedAt, t0)
    }

    func testLastUsedAtAdvancesWithClock() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var clock = Date(timeIntervalSince1970: 1000)
        let store = ToolUsageStore(storeURL: url, now: { clock })

        await store.record("a")
        clock = Date(timeIntervalSince1970: 2000)
        await store.record("a")

        let snap = await store.snapshot()
        XCTAssertEqual(snap["a"]?.lastUsedAt, Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(snap["a"]?.count, 2)
    }

    func testPersistsAcrossInstances() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let t0 = Date(timeIntervalSince1970: 1000)

        let writer = ToolUsageStore(storeURL: url, now: { t0 })
        await writer.record("github_search")
        await writer.record("github_search")
        await writer.record("linear_list")

        let reader = ToolUsageStore(storeURL: url, now: { t0 })
        let snap = await reader.snapshot()
        XCTAssertEqual(snap["github_search"]?.count, 2)
        XCTAssertEqual(snap["linear_list"]?.count, 1)
    }

    func testSalvagesCorruptStoreToEmpty() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try? "{not valid json".data(using: .utf8)!.write(to: url)

        let store = ToolUsageStore(storeURL: url, now: { Date() })
        let snap = await store.snapshot()
        XCTAssertTrue(snap.isEmpty)

        // A corrupt file must not block new writes.
        await store.record("recovered")
        let after = await store.snapshot()
        XCTAssertEqual(after["recovered"]?.count, 1)
    }
}
