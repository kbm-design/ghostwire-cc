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
    }
}
