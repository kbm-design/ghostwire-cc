//
//  GateCorrelationRecoveryTests.swift
//  GhostwireTests
//
//  GW-413: `PermissionRequest` carries no `tool_use_id`, so it has to be
//  correlated back to the `PreToolUse` that preceded it. When that failed, the
//  server denied — measured 27 times in one week, every one a tool blocked with
//  nobody looking at it.
//
//  It now resolves in three tiers: exact cache hit, then a relaxed
//  (session, tool) hit that recovers the agent's *real* id after the input
//  renderings disagreed, then a provisional id we mint ourselves and hold the
//  socket on. Never a deny.
//
//  The relaxed tier is the one that matters: GW-408's diagnosis was that a miss
//  means PreToolUse and PermissionRequest disagreed about `tool_input`, which
//  means the real id is usually sitting one cache key over. Minting instead of
//  recovering would throw that away.
//

import XCTest
@testable import Ghostwire

final class GateCorrelationRecoveryTests: XCTestCase {

    private var server: HookSocketServer { HookSocketServer.shared }

    private func session() -> String { "gw413-\(UUID().uuidString)" }

    /// Unique per call. `HookSocketServer.shared` is process-wide and
    /// `evictCachedToolUseId` matches by id across EVERY session's queue, so a
    /// literal like "toolu_b" is shared state with every other test class that
    /// drives the singleton (GW-444: `HookSocketServerCacheTests` evicting its
    /// "toolu_b" deleted this file's, or vice versa, by dictionary order).
    private func uniqueToolUseId(_ name: String) -> String {
        "toolu_\(name)_\(UUID().uuidString)"
    }

    private func preToolUse(
        sessionId: String,
        tool: String = "Bash",
        input: [String: AnyCodable],
        toolUseId: String
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId, cwd: "/tmp/gw413", event: "PreToolUse",
            status: "running_tool", pid: nil, tty: nil, tool: tool,
            toolInput: input, toolUseId: toolUseId,
            notificationType: nil, message: nil, source: "claude"
        )
    }

    private func gate(
        sessionId: String,
        tool: String? = "Bash",
        input: [String: AnyCodable]?
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId, cwd: "/tmp/gw413", event: "PermissionRequest",
            status: "waiting_for_approval", pid: nil, tty: nil, tool: tool,
            toolInput: input, toolUseId: nil,
            notificationType: nil, message: nil, source: "claude"
        )
    }

    // MARK: - Tier 2: recovering the real id

    /// The exact failure GW-408 diagnosed: PreToolUse cached under `{command}`,
    /// the gate arrives carrying `{command, description}`. Same call, different
    /// rendering. The real id is right there.
    func testRelaxedMatchRecoversTheRealIdWhenInputShapesDisagree() {
        let s = session()
        let real = uniqueToolUseId("real")
        server.cacheToolUseId(event: preToolUse(
            sessionId: s, input: ["command": AnyCodable("ls")], toolUseId: real
        ))

        let resolved = server.resolveGateId(for: gate(
            sessionId: s,
            input: ["command": AnyCodable("ls"), "description": AnyCodable("list files")]
        ))

        XCTAssertEqual(resolved.id, real,
                       "The agent's own id was in the cache — minting one instead discards it")
        XCTAssertEqual(resolved.correlation, .inferred)
    }

    func testRelaxedMatchAbstainsWhenTwoCallsAreOutstanding() {
        let s = session()
        let a = uniqueToolUseId("a")
        let b = uniqueToolUseId("b")
        server.cacheToolUseId(event: preToolUse(
            sessionId: s, input: ["command": AnyCodable("ls")], toolUseId: a
        ))
        server.cacheToolUseId(event: preToolUse(
            sessionId: s, input: ["command": AnyCodable("pwd")], toolUseId: b
        ))

        let resolved = server.resolveGateId(for: gate(
            sessionId: s, input: ["command": AnyCodable("whoami")]
        ))

        XCTAssertEqual(resolved.correlation, .provisional,
                       "Two candidates must not be guessed between — a wrong id releases the wrong gate later")
    }

    func testRelaxedMatchIgnoresOtherSessionsAndOtherTools() {
        let s = session()
        let otherSession = uniqueToolUseId("otherSession")
        let otherTool = uniqueToolUseId("otherTool")
        server.cacheToolUseId(event: preToolUse(
            sessionId: session(), input: ["command": AnyCodable("ls")], toolUseId: otherSession
        ))
        server.cacheToolUseId(event: preToolUse(
            sessionId: s, tool: "Write", input: ["file_path": AnyCodable("/x")], toolUseId: otherTool
        ))

        let resolved = server.resolveGateId(for: gate(sessionId: s, input: ["command": AnyCodable("ls")]))

        XCTAssertEqual(resolved.correlation, .provisional)
        XCTAssertNotEqual(resolved.id, otherSession)
        XCTAssertNotEqual(resolved.id, otherTool)
    }

    func testRelaxedMatchConsumesTheIdSoASecondGateCannotReuseIt() {
        let s = session()
        let once = uniqueToolUseId("once")
        server.cacheToolUseId(event: preToolUse(
            sessionId: s, input: ["command": AnyCodable("ls")], toolUseId: once
        ))

        let first = server.resolveGateId(for: gate(sessionId: s, input: ["command": AnyCodable("ls -la")]))
        let second = server.resolveGateId(for: gate(sessionId: s, input: ["command": AnyCodable("ls -la")]))

        XCTAssertEqual(first.id, once)
        XCTAssertEqual(second.correlation, .provisional,
                       "One PreToolUse is one call — two gates must not correlate to the same id")
    }

    func testRelaxedMatchExcludesIdsAlreadyHeldAsPendingGates() {
        let s = session()
        let held = uniqueToolUseId("held")
        server.cacheToolUseId(event: preToolUse(
            sessionId: s, input: ["command": AnyCodable("ls")], toolUseId: held
        ))

        let heldIds: Set<String> = [held]
        XCTAssertNil(
            server.popRelaxedCachedToolUseId(event: gate(sessionId: s, input: ["command": AnyCodable("x")]), excluding: heldIds),
            "An id already gating something is not a candidate for a second gate"
        )
    }

    // MARK: - Tier 1 stays first (GW-192)

    /// The exact path is what GW-192's eviction ordering depends on. The relaxed
    /// lookup must never pre-empt it, or a stale id at the head of a FIFO could
    /// be adopted ahead of the correct one.
    func testExactHitResolvesCachedNeverInferred() {
        let s = session()
        let exact = uniqueToolUseId("exact")
        let input: [String: AnyCodable] = ["command": AnyCodable("ls")]
        server.cacheToolUseId(event: preToolUse(sessionId: s, input: input, toolUseId: exact))

        let resolved = server.resolveGateId(for: gate(sessionId: s, input: input))

        XCTAssertEqual(resolved.id, exact)
        XCTAssertEqual(resolved.correlation, .cached)
    }

    func testRequestCarryingItsOwnIdResolvesDirect() {
        let s = session()
        let carried = uniqueToolUseId("carried")
        var event = gate(sessionId: s, input: ["command": AnyCodable("ls")])
        event = HookEvent(
            sessionId: event.sessionId, cwd: event.cwd, event: event.event, status: event.status,
            pid: nil, tty: nil, tool: event.tool, toolInput: event.toolInput,
            toolUseId: carried, notificationType: nil, message: nil, source: "claude"
        )

        let resolved = server.resolveGateId(for: event)

        XCTAssertEqual(resolved.id, carried)
        XCTAssertEqual(resolved.correlation, .direct)
    }

    // MARK: - Tier 3: provisional

    func testEmptyCacheYieldsAProvisionalIdRatherThanFailing() {
        let resolved = server.resolveGateId(for: gate(sessionId: session(), input: ["command": AnyCodable("ls")]))

        XCTAssertEqual(resolved.correlation, .provisional)
        XCTAssertTrue(resolved.id.hasPrefix("gw-gate-"),
                      "A minted id must be unmistakable for an agent id — nothing may correlate on it by accident")
    }

    /// The point of the whole change: resolution cannot fail, so the gate is
    /// always showable, so there is never a reason to deny one.
    func testResolutionAlwaysProducesAnIdEvenWithNoToolAtAll() {
        let resolved = server.resolveGateId(for: gate(sessionId: session(), tool: nil, input: nil))

        XCTAssertFalse(resolved.id.isEmpty)
        XCTAssertEqual(resolved.correlation, .provisional)
    }
}
