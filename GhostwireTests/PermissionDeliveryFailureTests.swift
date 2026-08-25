//
//  PermissionDeliveryFailureTests.swift
//  GhostwireTests
//
//  GW-362 defect 2. A verdict that never reached the agent used to record as
//  approved: `ClaudeSessionMonitor` sent `.permissionApproved` unconditionally,
//  right after the socket write, outside the `wasDelivered` check that already
//  governed the history stamp. So a dead socket left `AlertHistoryStore` saying
//  `timedOut` and `SessionStore` saying approved about the same event — and
//  `.permissionApproved` clears `waitingForApproval`, tearing down the State
//  B/C bar and its failed/Terminal affordance on the one path that needs it.
//
//  The decided terminal state (GW-362): a failed delivery is NOT a resolution.
//  The phase is held at `waitingForApproval` so the bar stays up and says
//  "answer in the terminal", and it self-invalidates on the agent's next event
//  via the `mayExitWaitingForApproval` guard. Not retry — `sendPermissionResponse`
//  drops the pending entry and closes the fd even when the write fails, so
//  there is no socket left to retry against.
//

import XCTest
@testable import Ghostwire

final class PermissionDeliveryFailureTests: XCTestCase {

    // MARK: - Helpers

    private func makeEvent(
        sessionId: String,
        event: String,
        status: String,
        tool: String? = nil,
        toolUseId: String? = nil
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/gw362-tests",
            event: event,
            status: status,
            pid: nil,
            tty: nil,
            tool: tool,
            toolInput: nil,
            toolUseId: toolUseId,
            notificationType: nil,
            message: nil
        )
    }

    /// Drive a session into `waitingForApproval` on an `ExitPlanMode` gate —
    /// State C, the surface the defect was found on.
    private func setupPendingPlanReview(sessionId: String, toolUseId: String) async {
        await SessionStore.shared.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "PreToolUse", status: "running_tool",
            tool: "ExitPlanMode", toolUseId: toolUseId
        )))
        await SessionStore.shared.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "PermissionRequest", status: "waiting_for_approval",
            tool: "ExitPlanMode", toolUseId: toolUseId
        )))
    }

    private func phase(of sessionId: String) async -> SessionPhase? {
        await SessionStore.shared.session(for: sessionId)?.phase
    }

    /// The tool's status in chat history — the thing a stale verdict corrupts.
    /// Phase alone can't catch it: a stale event leaves the phase untouched and
    /// still walks a finished tool's status backwards.
    private func toolStatus(of sessionId: String, toolUseId: String) async -> ToolStatus? {
        guard let session = await SessionStore.shared.session(for: sessionId) else { return nil }
        for item in session.chatItems where item.id == toolUseId {
            if case .toolCall(let tool) = item.type { return tool.status }
        }
        return nil
    }

    /// Poll until `condition` holds or `timeout` elapses. The store mutates from
    /// its own Tasks, so a fixed sleep is a bet on scheduler latency (GW-444).
    private func waitUntil(
        timeout: TimeInterval = 5, _ condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, await !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// SessionStore is a shared singleton and one test shortens the undelivered-gate
    /// TTL, so every test that expects a gate to *stay* held pins the real value.
    override func setUp() async throws {
        try await super.setUp()
        await SessionStore.shared.setUndeliveredGateTTLForTesting(600)
    }

    // MARK: - The decided terminal state

    /// The regression: an undelivered verdict must not clear the gate.
    func testSocketFailureHoldsWaitingForApproval() async {
        let sessionId = "gw362-hold-\(UUID().uuidString)"
        let toolUseId = "toolu_gw362_hold"
        await setupPendingPlanReview(sessionId: sessionId, toolUseId: toolUseId)
        let initial = await phase(of: sessionId)
        XCTAssertTrue(initial?.isWaitingForApproval == true, "setup")

        await SessionStore.shared.process(
            .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
        )

        let after = await phase(of: sessionId)
        XCTAssertTrue(
            after?.isWaitingForApproval == true,
            """
            A verdict that never reached the agent cleared the gate anyway, so \
            the plan-review bar is torn down and the user is told nothing \
            (GW-362). Phase: \(String(describing: after))
            """
        )
    }

    /// …and the permission context survives, so the bar keeps rendering the
    /// same plan rather than falling back to the generic approval bar.
    func testSocketFailureKeepsTheSameActivePermission() async {
        let sessionId = "gw362-ctx-\(UUID().uuidString)"
        let toolUseId = "toolu_gw362_ctx"
        await setupPendingPlanReview(sessionId: sessionId, toolUseId: toolUseId)

        await SessionStore.shared.process(
            .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
        )

        let permission = await SessionStore.shared.session(for: sessionId)?.activePermission
        XCTAssertEqual(permission?.toolUseId, toolUseId)
        XCTAssertEqual(permission?.toolName, "ExitPlanMode")
    }

    /// The held phase must not be a dead end. `mayExitWaitingForApproval`
    /// releases on a matching PostToolUse, which is what happens when the user
    /// answers the plan in the terminal instead — spec §5 self-invalidation.
    func testTerminalAnsweringStillReleasesTheHeldPhase() async {
        let sessionId = "gw362-release-\(UUID().uuidString)"
        let toolUseId = "toolu_gw362_release"
        await setupPendingPlanReview(sessionId: sessionId, toolUseId: toolUseId)
        await SessionStore.shared.process(
            .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
        )

        await SessionStore.shared.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "PostToolUse", status: "running_tool",
            tool: "ExitPlanMode", toolUseId: toolUseId
        )))

        let after = await phase(of: sessionId)
        XCTAssertFalse(
            after?.isWaitingForApproval == true,
            "A held gate must clear when the agent moves on, or it is stuck forever. Phase: \(String(describing: after))"
        )
    }

    /// The success path is unchanged — this fix must not make a delivered
    /// verdict stop resolving the gate.
    func testDeliveredApprovalStillClearsTheGate() async {
        let sessionId = "gw362-ok-\(UUID().uuidString)"
        let toolUseId = "toolu_gw362_ok"
        await setupPendingPlanReview(sessionId: sessionId, toolUseId: toolUseId)

        await SessionStore.shared.process(
            .permissionApproved(sessionId: sessionId, toolUseId: toolUseId)
        )

        let resolved = await phase(of: sessionId)
        XCTAssertFalse(resolved?.isWaitingForApproval == true)
    }

    // MARK: - Stale delivery completions (Codex review, finding 1)

    /// The delivery completion runs on the socket queue, unordered against the
    /// hook stream. If the user answers in the terminal first, `PostToolUse`
    /// resolves the gate — and a late socket-failure completion must not then
    /// mark that finished tool as failed.
    func testLateSocketFailureDoesNotFailATerminalResolvedTool() async {
        let sessionId = "gw362-stale-fail-\(UUID().uuidString)"
        let toolUseId = "toolu_gw362_stalefail"
        await setupPendingPlanReview(sessionId: sessionId, toolUseId: toolUseId)

        // The terminal answers first.
        await SessionStore.shared.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "PostToolUse", status: "running_tool",
            tool: "ExitPlanMode", toolUseId: toolUseId
        )))
        let resolvedPhase = await phase(of: sessionId)
        XCTAssertFalse(resolvedPhase?.isWaitingForApproval == true, "setup: terminal resolved it")
        let resolvedStatus = await toolStatus(of: sessionId, toolUseId: toolUseId)
        XCTAssertEqual(resolvedStatus, .success, "setup: PostToolUse marks the tool succeeded")

        // …then the stale completion lands.
        await SessionStore.shared.process(
            .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
        )

        let after = await toolStatus(of: sessionId, toolUseId: toolUseId)
        XCTAssertEqual(
            after, .success,
            """
            A stale socket-failure walked a terminal-resolved tool back to \
            \(String(describing: after)), so a plan the user actually approved \
            renders as failed (GW-362 review finding 1).
            """
        )
    }

    /// Same hole on the success side: a late allow must not walk a completed
    /// tool back to running.
    func testLateApprovalDoesNotReopenATerminalResolvedGate() async {
        let sessionId = "gw362-stale-ok-\(UUID().uuidString)"
        let toolUseId = "toolu_gw362_staleok"
        await setupPendingPlanReview(sessionId: sessionId, toolUseId: toolUseId)

        await SessionStore.shared.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "PostToolUse", status: "running_tool",
            tool: "ExitPlanMode", toolUseId: toolUseId
        )))
        await SessionStore.shared.process(
            .permissionApproved(sessionId: sessionId, toolUseId: toolUseId)
        )

        let after = await toolStatus(of: sessionId, toolUseId: toolUseId)
        XCTAssertEqual(
            after, .success,
            """
            A stale allow walked a completed tool back to \(String(describing: after)) \
            — a finished plan would show as still running (GW-362 review finding 1).
            """
        )
    }

    // MARK: - The held gate is bounded (Codex review, finding 2)

    /// Holding `waitingForApproval` relies on a later hook event to release it,
    /// and a dead socket is exactly when that event may never arrive. If the
    /// user never answers in the terminal, the sweep must release the gate so
    /// the session stops demanding attention it cannot act on.
    func testUnansweredGateIsReleasedAfterTheTTL() async {
        let sessionId = "gw362-ttl-\(UUID().uuidString)"
        let toolUseId = "toolu_gw362_ttl"
        await SessionStore.shared.setUndeliveredGateTTLForTesting(0.2)

        await setupPendingPlanReview(sessionId: sessionId, toolUseId: toolUseId)
        await SessionStore.shared.process(
            .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
        )

        // Still held immediately after — the user gets a window to go answer.
        let immediately = await phase(of: sessionId)
        XCTAssertTrue(immediately?.isWaitingForApproval == true, "must not yank the bar away instantly")

        await waitUntil { await self.phase(of: sessionId)?.isWaitingForApproval != true }

        let afterTTL = await phase(of: sessionId)
        XCTAssertFalse(
            afterTTL?.isWaitingForApproval == true,
            """
            An undelivered gate stayed in waitingForApproval past its TTL, so the \
            session glows forever for a gate nothing can answer (GW-362 review \
            finding 2). Phase: \(String(describing: afterTTL))
            """
        )

        // SessionStore is a shared singleton — put the real TTL back so test
        // order can't decide whether another test's gate survives.
        await SessionStore.shared.setUndeliveredGateTTLForTesting(600)
    }

    /// And if the agent is already gone, don't make the user wait out the TTL —
    /// a gate with no process behind it can never be answered.
    func testGateForADeadAgentIsReleasedImmediately() async {
        let sessionId = "gw362-deadpid-\(UUID().uuidString)"
        let toolUseId = "toolu_gw362_deadpid"

        // pid 0 is never a live agent, so the liveness check fails closed.
        await SessionStore.shared.process(.hookReceived(HookEvent(
            sessionId: sessionId, cwd: "/tmp/gw362-tests", event: "PreToolUse",
            status: "running_tool", pid: 0, tty: nil, tool: "ExitPlanMode",
            toolInput: nil, toolUseId: toolUseId, notificationType: nil, message: nil
        )))
        await SessionStore.shared.process(.hookReceived(HookEvent(
            sessionId: sessionId, cwd: "/tmp/gw362-tests", event: "PermissionRequest",
            status: "waiting_for_approval", pid: 0, tty: nil, tool: "ExitPlanMode",
            toolInput: nil, toolUseId: toolUseId, notificationType: nil, message: nil
        )))
        let pending = await phase(of: sessionId)
        XCTAssertTrue(pending?.isWaitingForApproval == true, "setup")

        await SessionStore.shared.process(
            .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
        )

        let after = await phase(of: sessionId)
        XCTAssertFalse(
            after?.isWaitingForApproval == true,
            "A gate whose agent is dead should release at once, not after the TTL. Phase: \(String(describing: after))"
        )
    }

    // MARK: - Through the real monitor path

    /// End-to-end over the code that actually had the bug. There is no pending
    /// permission registered with `HookSocketServer` for this toolUseId, which
    /// is one of the two real dead-socket cases (`sendPermissionResponse`'s
    /// `guard let pending = removeValue(…) else { return false }`), so the write
    /// reports undelivered — and the gate must survive it.
    @MainActor
    func testApproveWithNoHeldSocketReportsUndeliveredAndHoldsTheGate() async {
        let sessionId = "gw362-monitor-\(UUID().uuidString)"
        let toolUseId = "toolu_gw362_monitor"
        await setupPendingPlanReview(sessionId: sessionId, toolUseId: toolUseId)

        let monitor = ClaudeSessionMonitor()
        let reported = expectation(description: "delivery reported")
        let delivered = UncheckedBox<Bool?>(nil)

        monitor.approvePermission(sessionId: sessionId) { wasDelivered in
            delivered.value = wasDelivered
            reported.fulfill()
        }
        await fulfillment(of: [reported], timeout: 5)

        XCTAssertEqual(delivered.value, false, "no held socket, so nothing was delivered")

        // The event is emitted from inside the completion, so let the store's
        // Task land before reading it back.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let after = await phase(of: sessionId)
        XCTAssertTrue(
            after?.isWaitingForApproval == true,
            """
            approvePermission recorded an approval for a verdict that never \
            reached the agent (GW-362). Phase: \(String(describing: after))
            """
        )
    }

    /// Deny carries State B's Choice answer and State C's Revise, so the same
    /// hole there is the wider one — it spans States A, B and C.
    @MainActor
    func testDenyWithNoHeldSocketAlsoHoldsTheGate() async {
        let sessionId = "gw362-deny-\(UUID().uuidString)"
        let toolUseId = "toolu_gw362_deny"
        await setupPendingPlanReview(sessionId: sessionId, toolUseId: toolUseId)

        let monitor = ClaudeSessionMonitor()
        let reported = expectation(description: "delivery reported")
        let delivered = UncheckedBox<Bool?>(nil)

        monitor.denyPermission(sessionId: sessionId, reason: "Revise: use a smaller diff") { wasDelivered in
            delivered.value = wasDelivered
            reported.fulfill()
        }
        await fulfillment(of: [reported], timeout: 5)

        XCTAssertEqual(delivered.value, false)

        try? await Task.sleep(nanoseconds: 300_000_000)
        let after = await phase(of: sessionId)
        XCTAssertTrue(
            after?.isWaitingForApproval == true,
            """
            denyPermission recorded a denial for feedback that never reached the \
            agent (GW-362). Phase: \(String(describing: after))
            """
        )
    }
}

/// Minimal mutable box for capturing a value out of a `@Sendable` completion.
private final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
