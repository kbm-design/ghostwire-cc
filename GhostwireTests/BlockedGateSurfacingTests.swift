//
//  BlockedGateSurfacingTests.swift
//  GhostwireTests
//
//  GW-408: PR #77 made an uncorrelatable or undecodable PermissionRequest
//  deny instead of falling through to the terminal, and told nobody — it
//  removed `eventHandler?(event)` from the cache-miss branch, so a blocked
//  tool left no trace anywhere in the app: no session row, no chat item, no
//  alert history, no signal. Measured live: the deny went out on the socket
//  and the `Session` log category stayed empty.
//
//  GW-413 narrowed what reaches here. An *uncorrelatable* gate is no longer
//  refused at all — it is held on a provisional id and shown normally (see
//  GateCorrelationRecoveryTests + SessionApprovalPhaseTests). What remains is
//  the one gate Ghostwire genuinely cannot render: a payload that would not
//  decode, so there is no tool name or input to put in front of anyone.
//
//  That gate is now handed back to the terminal (`ask`) rather than denied.
//  These tests lock in the half that did not change and matters most: it must
//  still be *visible*, because a Ghostwire that has quietly stopped gating
//  looks exactly like one that is working. And it must never be mistaken for a
//  live gate — the socket is already released, so an actionable approval bar
//  would offer a button that reaches nothing.
//

import XCTest
@testable import Ghostwire

final class BlockedGateSurfacingTests: XCTestCase {

    private func gateEvent(
        sessionId: String,
        tool: String? = "Bash",
        toolInput: [String: AnyCodable]? = ["command": AnyCodable("echo blocked")]
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/gw408-tests",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            pid: nil,
            tty: nil,
            tool: tool,
            toolInput: toolInput,
            toolUseId: nil,
            notificationType: nil,
            message: nil,
            source: "codex"
        )
    }

    private let reason = "Ghostwire could not match this Bash request to the tool call it belongs to."

    // MARK: - The regression itself

    func testBlockedGateCreatesAVisibleSessionRow() async {
        let sessionId = "gw408-visible-\(UUID().uuidString)"

        await SessionStore.shared.process(
            .permissionBlocked(event: gateEvent(sessionId: sessionId), reason: reason)
        )

        let session = await SessionStore.shared.session(for: sessionId)
        XCTAssertNotNil(
            session,
            "A blocked gate produced no session at all — this is the GW-408 regression: the tool was denied and the app showed nothing"
        )
    }

    func testBlockedGateRecordsTheReasonOnAnErroredToolRow() async {
        let sessionId = "gw408-reason-\(UUID().uuidString)"

        await SessionStore.shared.process(
            .permissionBlocked(event: gateEvent(sessionId: sessionId), reason: reason)
        )

        let session = await SessionStore.shared.session(for: sessionId)
        let blockedRow = session?.chatItems.compactMap { item -> ToolCallItem? in
            guard case .toolCall(let tool) = item.type else { return nil }
            return tool
        }.first

        XCTAssertEqual(blockedRow?.name, "Bash")
        XCTAssertEqual(blockedRow?.status, .error,
                       "A blocked tool must read as failed, not running or awaiting approval")
        XCTAssertEqual(blockedRow?.result, reason,
                       "The user has to be able to see *why* it was blocked, not just that it was")
    }

    func testBlockedGateDoesNotPresentAnActionableApprovalBar() async {
        let sessionId = "gw408-not-actionable-\(UUID().uuidString)"

        await SessionStore.shared.process(
            .permissionBlocked(event: gateEvent(sessionId: sessionId), reason: reason)
        )

        let session = await SessionStore.shared.session(for: sessionId)
        XCTAssertNotEqual(
            session?.phase.isWaitingForApproval, true,
            "The socket is already released — an Allow/Deny bar here reaches a dead fd and lies to the user"
        )
        XCTAssertTrue(session?.pendingPermissions.isEmpty ?? false,
                      "This gate is finished in Ghostwire's hands, so it must not queue as pending")
    }

    // MARK: - Degraded payloads

    /// The decode-failure path salvages what it can from raw bytes, so tool
    /// and input are routinely nil. Surfacing must survive that — a partial
    /// record is the entire point, since the alternative is the silent drop.
    func testBlockedGateSurvivesAPayloadWithNoToolOrInput() async {
        let sessionId = "gw408-degraded-\(UUID().uuidString)"

        await SessionStore.shared.process(.permissionBlocked(
            event: gateEvent(sessionId: sessionId, tool: nil, toolInput: nil),
            reason: reason
        ))

        let session = await SessionStore.shared.session(for: sessionId)
        let blockedRow = session?.chatItems.compactMap { item -> ToolCallItem? in
            guard case .toolCall(let tool) = item.type else { return nil }
            return tool
        }.first

        XCTAssertNotNil(session, "A degraded payload must still surface something")
        XCTAssertEqual(blockedRow?.name, "unknown")
        XCTAssertEqual(blockedRow?.status, .error)
    }

    func testBlockedGateAdoptsTheAgentFromTheEventSource() async {
        let sessionId = "gw408-agent-\(UUID().uuidString)"

        await SessionStore.shared.process(
            .permissionBlocked(event: gateEvent(sessionId: sessionId), reason: reason)
        )

        let session = await SessionStore.shared.session(for: sessionId)
        XCTAssertEqual(session?.agent, "codex",
                       "Identity comes from the payload — a blocked Codex gate must not be filed under claude")
    }

    /// Two blocked gates are two separate events. They must not collapse onto
    /// one row: there is no tool_use_id to correlate them, which is exactly why
    /// they were blocked in the first place.
    func testTwoBlockedGatesProduceTwoRows() async {
        let sessionId = "gw408-two-\(UUID().uuidString)"

        await SessionStore.shared.process(
            .permissionBlocked(event: gateEvent(sessionId: sessionId), reason: reason)
        )
        await SessionStore.shared.process(
            .permissionBlocked(event: gateEvent(sessionId: sessionId), reason: reason)
        )

        let session = await SessionStore.shared.session(for: sessionId)
        let toolRows = session?.chatItems.filter {
            if case .toolCall = $0.type { return true }
            return false
        }
        XCTAssertEqual(toolRows?.count, 2)
    }
}
