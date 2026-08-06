//
//  SessionApprovalPhaseTests.swift
//  GhostwireTests
//
//  GW-192: a pending approval must never vanish from the notch while the
//  agent is still blocked on it. Concurrent subagent hook events (PreToolUse/
//  PostToolUse with the same session_id) must not stomp waitingForApproval.
//

import XCTest
@testable import Ghostwire

final class SessionApprovalPhaseTests: XCTestCase {

    // MARK: - Helpers

    private func makeEvent(
        sessionId: String,
        event: String,
        status: String,
        tool: String? = nil,
        toolInput: [String: AnyCodable]? = nil,
        toolUseId: String? = nil
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/gw192-tests",
            event: event,
            status: status,
            pid: nil,
            tty: nil,
            tool: tool,
            toolInput: toolInput,
            toolUseId: toolUseId,
            notificationType: nil,
            message: nil
        )
    }

    /// Drive a session into waitingForApproval for a Bash tool
    private func setupPendingApproval(sessionId: String, toolUseId: String) async {
        // Parent PreToolUse for the gated tool
        await SessionStore.shared.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "PreToolUse", status: "running_tool",
            tool: "Bash", toolUseId: toolUseId
        )))
        // PermissionRequest (toolUseId already resolved by HookSocketServer correlation)
        await SessionStore.shared.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "PermissionRequest", status: "waiting_for_approval",
            tool: "Bash", toolUseId: toolUseId
        )))
    }

    private func phase(of sessionId: String) async -> SessionPhase? {
        await SessionStore.shared.session(for: sessionId)?.phase
    }

    // MARK: - Baseline

    func testPermissionRequestEntersWaitingForApproval() async {
        let sessionId = "gw192-baseline-\(UUID().uuidString)"
        await setupPendingApproval(sessionId: sessionId, toolUseId: "toolu_parent_bash")

        let phase = await phase(of: sessionId)
        XCTAssertEqual(phase?.isWaitingForApproval, true)
        XCTAssertEqual(phase?.approvalToolName, "Bash")
    }

    // MARK: - GW-192 regression: unrelated events must NOT clear the approval

    func testUnrelatedPostToolUseDoesNotClearApproval() async {
        let sessionId = "gw192-posttool-\(UUID().uuidString)"
        await setupPendingApproval(sessionId: sessionId, toolUseId: "toolu_parent_bash")

        // A concurrent subagent's tool completes (same session_id, different toolUseId)
        await SessionStore.shared.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "PostToolUse", status: "processing",
            tool: "Read", toolUseId: "toolu_subagent_read"
        )))

        let phase = await phase(of: sessionId)
        XCTAssertEqual(phase?.isWaitingForApproval, true,
                       "Approval vanished: subagent PostToolUse stomped waitingForApproval while the agent was still blocked")
    }

    func testUnrelatedPreToolUseDoesNotClearApproval() async {
        let sessionId = "gw192-pretool-\(UUID().uuidString)"
        await setupPendingApproval(sessionId: sessionId, toolUseId: "toolu_parent_bash")

        // A concurrent subagent starts another tool
        await SessionStore.shared.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "PreToolUse", status: "running_tool",
            tool: "Grep", toolUseId: "toolu_subagent_grep"
        )))

        let phase = await phase(of: sessionId)
        XCTAssertEqual(phase?.isWaitingForApproval, true,
                       "Approval vanished: subagent PreToolUse stomped waitingForApproval while the agent was still blocked")
    }

    func testIdleNotificationDoesNotClearApproval() async {
        let sessionId = "gw192-idle-\(UUID().uuidString)"
        await setupPendingApproval(sessionId: sessionId, toolUseId: "toolu_parent_bash")

        await SessionStore.shared.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "Notification", status: "notification"
        )))

        let phase = await phase(of: sessionId)
        XCTAssertEqual(phase?.isWaitingForApproval, true)
    }

    // MARK: - Legitimate exits must still work

    func testMatchingPostToolUseResolvesApproval() async {
        // User approved in the terminal -> the gated tool itself runs -> PostToolUse with the SAME toolUseId
        let sessionId = "gw192-resolve-\(UUID().uuidString)"
        await setupPendingApproval(sessionId: sessionId, toolUseId: "toolu_parent_bash")

        await SessionStore.shared.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "PostToolUse", status: "processing",
            tool: "Bash", toolUseId: "toolu_parent_bash"
        )))

        let phase = await phase(of: sessionId)
        XCTAssertEqual(phase?.isWaitingForApproval, false,
                       "Terminal-approved tool ran but phase stayed waitingForApproval")
    }

    func testStopExitsApproval() async {
        // Turn ended (e.g. denied in terminal) -> Stop must clear the approval phase
        let sessionId = "gw192-stop-\(UUID().uuidString)"
        await setupPendingApproval(sessionId: sessionId, toolUseId: "toolu_parent_bash")

        await SessionStore.shared.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "Stop", status: "waiting_for_input"
        )))

        let phase = await phase(of: sessionId)
        XCTAssertEqual(phase?.isWaitingForApproval, false)
    }

    func testNewPermissionRequestReplacesContext() async {
        // A second permission request may take over the phase context (queueing behavior)
        let sessionId = "gw192-second-\(UUID().uuidString)"
        await setupPendingApproval(sessionId: sessionId, toolUseId: "toolu_parent_bash")

        await SessionStore.shared.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "PreToolUse", status: "running_tool",
            tool: "Write", toolUseId: "toolu_parent_write"
        )))
        await SessionStore.shared.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "PermissionRequest", status: "waiting_for_approval",
            tool: "Write", toolUseId: "toolu_parent_write"
        )))

        let phase = await phase(of: sessionId)
        XCTAssertEqual(phase?.isWaitingForApproval, true)
        XCTAssertEqual(phase?.approvalToolName, "Write")
    }

    func testUserApprovalFromNotchStillResolves() async {
        let sessionId = "gw192-notch-approve-\(UUID().uuidString)"
        await setupPendingApproval(sessionId: sessionId, toolUseId: "toolu_parent_bash")

        await SessionStore.shared.process(
            .permissionApproved(sessionId: sessionId, toolUseId: "toolu_parent_bash")
        )

        let phase = await phase(of: sessionId)
        XCTAssertEqual(phase?.isWaitingForApproval, false)
        let session = await SessionStore.shared.session(for: sessionId)
        XCTAssertEqual(session?.pendingPermissions.isEmpty, true)
    }

    func testTerminalApprovalClearsPendingPermissionQueue() async {
        let sessionId = "audit-terminal-approve-\(UUID().uuidString)"
        await setupPendingApproval(sessionId: sessionId, toolUseId: "toolu_parent_bash")

        await SessionStore.shared.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "PostToolUse", status: "processing",
            tool: "Bash", toolUseId: "toolu_parent_bash"
        )))

        let session = await SessionStore.shared.session(for: sessionId)
        XCTAssertEqual(session?.phase.isWaitingForApproval, false)
        XCTAssertEqual(session?.pendingPermissions.isEmpty, true)
    }

    // MARK: - Provisional gates (GW-413)
    //
    // A gate the server could not correlate is now held on an id Ghostwire
    // minted, rather than denied. That id means nothing to the agent, so the
    // real PostToolUse can never match it — release falls back on tool name,
    // and only when exactly one gate is in play.

    private func provisionalGate(sessionId: String, toolUseId: String, tool: String = "Bash") -> HookEvent {
        HookEvent(
            sessionId: sessionId, cwd: "/tmp/gw413-tests", event: "PermissionRequest",
            status: "waiting_for_approval", pid: nil, tty: nil, tool: tool,
            toolInput: nil, toolUseId: toolUseId, notificationType: nil, message: nil,
            toolUseIdIsProvisional: true
        )
    }

    func testProvisionalGatePresentsAnActionableApprovalBar() async {
        let sessionId = "gw413-actionable-\(UUID().uuidString)"

        await SessionStore.shared.process(.hookReceived(provisionalGate(
            sessionId: sessionId, toolUseId: "gw-gate-abc123"
        )))

        let session = await SessionStore.shared.session(for: sessionId)
        XCTAssertEqual(session?.phase.isWaitingForApproval, true,
                       "The whole point of GW-413: an uncorrelatable gate is still shown, not denied")
        XCTAssertEqual(session?.pendingPermissions.count, 1)
    }

    func testRealPostToolUseReleasesALoneProvisionalGate() async {
        let sessionId = "gw413-release-\(UUID().uuidString)"
        await SessionStore.shared.process(.hookReceived(provisionalGate(
            sessionId: sessionId, toolUseId: "gw-gate-lone"
        )))

        // The agent's own id — it cannot equal the one we minted.
        await SessionStore.shared.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "PostToolUse", status: "processing",
            tool: "Bash", toolUseId: "toolu_real_and_different"
        )))

        let session = await SessionStore.shared.session(for: sessionId)
        XCTAssertEqual(session?.phase.isWaitingForApproval, false,
                       "Without the tool-name fallback the bar sticks until Stop over a tool that already ran")
        XCTAssertEqual(session?.pendingPermissions.isEmpty, true,
                       "The queue has to drop it too, or isUnansweredGate keeps answering true for a ghost")
    }

    /// Subagents share a session_id, so two concurrent same-tool gates is a real
    /// shape. Guessing between them would release the one the user is looking at.
    func testTwoProvisionalGatesAreNotGuessedBetween() async {
        let sessionId = "gw413-ambiguous-\(UUID().uuidString)"
        await SessionStore.shared.process(.hookReceived(provisionalGate(
            sessionId: sessionId, toolUseId: "gw-gate-one"
        )))
        await SessionStore.shared.process(.hookReceived(provisionalGate(
            sessionId: sessionId, toolUseId: "gw-gate-two"
        )))

        await SessionStore.shared.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "PostToolUse", status: "processing",
            tool: "Bash", toolUseId: "toolu_real"
        )))

        let session = await SessionStore.shared.session(for: sessionId)
        XCTAssertEqual(session?.pendingPermissions.count, 2,
                       "Ambiguity must abstain — Stop hands both back at turn end, which is safe")
    }

    func testUnrelatedToolDoesNotReleaseAProvisionalGate() async {
        let sessionId = "gw413-unrelated-\(UUID().uuidString)"
        await SessionStore.shared.process(.hookReceived(provisionalGate(
            sessionId: sessionId, toolUseId: "gw-gate-bash"
        )))

        await SessionStore.shared.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "PostToolUse", status: "processing",
            tool: "Write", toolUseId: "toolu_write"
        )))

        let session = await SessionStore.shared.session(for: sessionId)
        XCTAssertEqual(session?.pendingPermissions.count, 1,
                       "A different tool finishing says nothing about this gate")
    }
}
