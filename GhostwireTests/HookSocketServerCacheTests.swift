//
//  HookSocketServerCacheTests.swift
//  GhostwireTests
//
//  GW-192 part 2: the PreToolUse -> PermissionRequest correlation cache.
//  PermissionRequest carries no tool_use_id, so it's resolved FIFO from ids
//  cached at PreToolUse, keyed by (session, tool, sorted input). Ids of tools
//  that already ran (PostToolUse) must be evicted, or auto-approved tools with
//  identical input poison the head of the queue and the PermissionRequest
//  correlates to the wrong tool.
//

import XCTest
@testable import Ghostwire

final class HookSocketServerCacheTests: XCTestCase {

    /// Unique per call. `HookSocketServer.shared` is a process-wide singleton and
    /// `evictCachedToolUseId` scans EVERY cache key, returning on the first entry
    /// whose id matches — correct in production, where a tool_use_id is globally
    /// unique, but it means a literal id here is shared state with every other
    /// test file. `GateCorrelationRecoveryTests` caches a "toolu_b" of its own and
    /// never pops it, so eviction here would delete whichever of the two
    /// dictionary iteration reached first: a flake that passes or fails by hash
    /// order, with nothing in the diff to explain it. Session ids in these tests
    /// were already unique for the same reason; the tool ids have to be too.
    private func uniqueToolUseId(_ name: String) -> String {
        "toolu_\(name)_\(UUID().uuidString)"
    }

    private func makeEvent(
        sessionId: String,
        event: String,
        tool: String = "Bash",
        toolInput: [String: AnyCodable]? = nil,
        toolUseId: String? = nil
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/gw192-tests",
            event: event,
            status: event == "PermissionRequest" ? "waiting_for_approval" : "running_tool",
            pid: nil,
            tty: nil,
            tool: tool,
            toolInput: toolInput ?? ["command": AnyCodable("cd /tmp/repo")],
            toolUseId: toolUseId,
            notificationType: nil,
            message: nil
        )
    }

    func testPopReturnsCachedIdFIFO() {
        let sessionId = "gw192-cache-fifo-\(UUID().uuidString)"
        let server = HookSocketServer.shared

        let first = uniqueToolUseId("1")

        server.cacheToolUseId(event: makeEvent(sessionId: sessionId, event: "PreToolUse", toolUseId: first))

        let popped = server.popCachedToolUseId(event: makeEvent(sessionId: sessionId, event: "PermissionRequest"))
        XCTAssertEqual(popped, first)
    }

    func testExecutedToolIdIsEvictedFromCache() {
        // Two identical Bash calls (e.g. concurrent subagents running the same cd).
        // The first is auto-approved and runs (PostToolUse); the second needs
        // permission. The PermissionRequest must correlate to the second id.
        let sessionId = "gw192-cache-evict-\(UUID().uuidString)"
        let server = HookSocketServer.shared

        let ran = uniqueToolUseId("ran")
        let pending = uniqueToolUseId("pending")

        server.cacheToolUseId(event: makeEvent(sessionId: sessionId, event: "PreToolUse", toolUseId: ran))
        server.cacheToolUseId(event: makeEvent(sessionId: sessionId, event: "PreToolUse", toolUseId: pending))

        // `ran` executed without needing permission
        server.evictCachedToolUseId(ran)

        let popped = server.popCachedToolUseId(event: makeEvent(sessionId: sessionId, event: "PermissionRequest"))
        XCTAssertEqual(popped, pending,
                       "PermissionRequest correlated to an already-executed tool's id")
    }

    func testEvictionRemovesOnlyTargetId() {
        let sessionId = "gw192-cache-target-\(UUID().uuidString)"
        let server = HookSocketServer.shared

        let a = uniqueToolUseId("a")
        let b = uniqueToolUseId("b")
        let c = uniqueToolUseId("c")

        server.cacheToolUseId(event: makeEvent(sessionId: sessionId, event: "PreToolUse", toolUseId: a))
        server.cacheToolUseId(event: makeEvent(sessionId: sessionId, event: "PreToolUse", toolUseId: b))
        server.cacheToolUseId(event: makeEvent(sessionId: sessionId, event: "PreToolUse", toolUseId: c))

        server.evictCachedToolUseId(b)

        let first = server.popCachedToolUseId(event: makeEvent(sessionId: sessionId, event: "PermissionRequest"))
        let second = server.popCachedToolUseId(event: makeEvent(sessionId: sessionId, event: "PermissionRequest"))
        XCTAssertEqual(first, a)
        XCTAssertEqual(second, c)
    }

    func testEvictingUnknownIdIsHarmless() {
        let sessionId = "gw192-cache-unknown-\(UUID().uuidString)"
        let server = HookSocketServer.shared

        let x = uniqueToolUseId("x")

        server.cacheToolUseId(event: makeEvent(sessionId: sessionId, event: "PreToolUse", toolUseId: x))
        server.evictCachedToolUseId(uniqueToolUseId("never_cached"))

        let popped = server.popCachedToolUseId(event: makeEvent(sessionId: sessionId, event: "PermissionRequest"))
        XCTAssertEqual(popped, x)
    }

    func testNestedToolInputKeyOrderIsCanonical() {
        let sessionId = "audit-nested-cache-\(UUID().uuidString)"
        let server = HookSocketServer.shared
        let nested = uniqueToolUseId("nested")

        let preInput: [String: AnyCodable] = [
            "question": AnyCodable([
                "beta": "2",
                "alpha": "1",
                "nested": ["z": "last", "a": "first"],
            ] as [String: Any])
        ]
        let permissionInput: [String: AnyCodable] = [
            "question": AnyCodable([
                "nested": ["a": "first", "z": "last"],
                "alpha": "1",
                "beta": "2",
            ] as [String: Any])
        ]

        server.cacheToolUseId(event: makeEvent(
            sessionId: sessionId,
            event: "PreToolUse",
            tool: "AskUserQuestion",
            toolInput: preInput,
            toolUseId: nested
        ))

        let popped = server.popCachedToolUseId(event: makeEvent(
            sessionId: sessionId,
            event: "PermissionRequest",
            tool: "AskUserQuestion",
            toolInput: permissionInput
        ))

        XCTAssertEqual(popped, nested)
    }
}
