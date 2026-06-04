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

        server.cacheToolUseId(event: makeEvent(sessionId: sessionId, event: "PreToolUse", toolUseId: "toolu_1"))

        let popped = server.popCachedToolUseId(event: makeEvent(sessionId: sessionId, event: "PermissionRequest"))
        XCTAssertEqual(popped, "toolu_1")
    }

    func testExecutedToolIdIsEvictedFromCache() {
        // Two identical Bash calls (e.g. concurrent subagents running the same cd).
        // The first is auto-approved and runs (PostToolUse); the second needs
        // permission. The PermissionRequest must correlate to the second id.
        let sessionId = "gw192-cache-evict-\(UUID().uuidString)"
        let server = HookSocketServer.shared

        server.cacheToolUseId(event: makeEvent(sessionId: sessionId, event: "PreToolUse", toolUseId: "toolu_ran"))
        server.cacheToolUseId(event: makeEvent(sessionId: sessionId, event: "PreToolUse", toolUseId: "toolu_pending"))

        // toolu_ran executed without needing permission
        server.evictCachedToolUseId("toolu_ran")

        let popped = server.popCachedToolUseId(event: makeEvent(sessionId: sessionId, event: "PermissionRequest"))
        XCTAssertEqual(popped, "toolu_pending",
                       "PermissionRequest correlated to an already-executed tool's id")
    }

    func testEvictionRemovesOnlyTargetId() {
        let sessionId = "gw192-cache-target-\(UUID().uuidString)"
        let server = HookSocketServer.shared

        server.cacheToolUseId(event: makeEvent(sessionId: sessionId, event: "PreToolUse", toolUseId: "toolu_a"))
        server.cacheToolUseId(event: makeEvent(sessionId: sessionId, event: "PreToolUse", toolUseId: "toolu_b"))
        server.cacheToolUseId(event: makeEvent(sessionId: sessionId, event: "PreToolUse", toolUseId: "toolu_c"))

        server.evictCachedToolUseId("toolu_b")

        let first = server.popCachedToolUseId(event: makeEvent(sessionId: sessionId, event: "PermissionRequest"))
        let second = server.popCachedToolUseId(event: makeEvent(sessionId: sessionId, event: "PermissionRequest"))
        XCTAssertEqual(first, "toolu_a")
        XCTAssertEqual(second, "toolu_c")
    }

    func testEvictingUnknownIdIsHarmless() {
        let sessionId = "gw192-cache-unknown-\(UUID().uuidString)"
        let server = HookSocketServer.shared

        server.cacheToolUseId(event: makeEvent(sessionId: sessionId, event: "PreToolUse", toolUseId: "toolu_x"))
        server.evictCachedToolUseId("toolu_never_cached")

        let popped = server.popCachedToolUseId(event: makeEvent(sessionId: sessionId, event: "PermissionRequest"))
        XCTAssertEqual(popped, "toolu_x")
    }
}
