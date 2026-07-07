//
//  WorkingSetSelectorTests.swift
//  GhostwireTests
//
//  GW-184: which downstream tools get exposed directly. Pure selection over a
//  usage snapshot + the ordered tool catalog — no store, no clock.
//

import XCTest

@testable import Ghostwire

final class WorkingSetSelectorTests: XCTestCase {
    private func tool(_ name: String, _ server: UUID) -> (name: String, serverID: UUID) {
        (name: name, serverID: server)
    }

    func testColdStartRoundRobinsAcrossServersUpToCap() {
        let a = UUID(), b = UUID()
        // Server A has 4 tools, server B has 2; cap 4 → expect interleave A,B,A,B.
        let catalog = [
            tool("a_one", a), tool("a_two", a), tool("a_three", a), tool("a_four", a),
            tool("b_one", b), tool("b_two", b),
        ]
        let config = WorkingSetConfig(recencyLimit: 15, frequencyLimit: 10, cap: 4, searchLimit: 10)

        let ws = WorkingSetSelector.select(catalog: catalog, usage: [:], config: config)

        XCTAssertEqual(ws, ["a_one", "b_one", "a_two", "b_two"])
    }

    func testColdStartReturnsAllWhenUnderCap() {
        let a = UUID()
        let catalog = [tool("a_one", a), tool("a_two", a)]
        let config = WorkingSetConfig(cap: 25)

        let ws = WorkingSetSelector.select(catalog: catalog, usage: [:], config: config)

        XCTAssertEqual(Set(ws), ["a_one", "a_two"])
    }

    func testWarmSelectsRecencyUnionFrequency() {
        let s = UUID()
        let catalog = (1...20).map { tool("t\($0)", s) }
        // t1..t12 each used once at increasing times → recency favors the latest.
        // t20 used 50 times long ago → frequency must still include it.
        var usage: [String: ToolUsage] = [:]
        for i in 1...12 {
            usage["t\(i)"] = ToolUsage(count: 1, lastUsedAt: Date(timeIntervalSince1970: Double(1000 + i)))
        }
        usage["t20"] = ToolUsage(count: 50, lastUsedAt: Date(timeIntervalSince1970: 1))
        let config = WorkingSetConfig(recencyLimit: 3, frequencyLimit: 1, cap: 25)

        let ws = WorkingSetSelector.select(catalog: catalog, usage: usage, config: config)

        // 3 most-recent = t12,t11,t10 ; top-1 frequent = t20.
        XCTAssertEqual(ws, ["t12", "t11", "t10", "t20"])
    }

    func testWarmDedupesToolThatIsBothRecentAndFrequent() {
        let s = UUID()
        let catalog = [tool("hot", s), tool("warm", s)]
        let usage: [String: ToolUsage] = [
            "hot": ToolUsage(count: 99, lastUsedAt: Date(timeIntervalSince1970: 5000)),
            "warm": ToolUsage(count: 1, lastUsedAt: Date(timeIntervalSince1970: 4000)),
        ]
        let config = WorkingSetConfig(recencyLimit: 2, frequencyLimit: 2, cap: 25)

        let ws = WorkingSetSelector.select(catalog: catalog, usage: usage, config: config)

        XCTAssertEqual(ws.filter { $0 == "hot" }.count, 1)  // appears once, not twice
        XCTAssertEqual(Set(ws), ["hot", "warm"])
    }

    func testWarmDropsUsageForToolsNoLongerInCatalog() {
        let s = UUID()
        let catalog = [tool("still_here", s)]
        let usage: [String: ToolUsage] = [
            "still_here": ToolUsage(count: 1, lastUsedAt: Date(timeIntervalSince1970: 2000)),
            "removed_server_tool": ToolUsage(count: 99, lastUsedAt: Date(timeIntervalSince1970: 9000)),
        ]
        let ws = WorkingSetSelector.select(catalog: catalog, usage: usage, config: .default)

        XCTAssertEqual(ws, ["still_here"])
    }
}
