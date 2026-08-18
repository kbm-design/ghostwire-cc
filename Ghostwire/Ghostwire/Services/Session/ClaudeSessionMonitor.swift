//
//  ClaudeSessionMonitor.swift
//  Ghostwire
//
//  MainActor wrapper around SessionStore for UI binding.
//  Publishes SessionState arrays for SwiftUI observation.
//

import AppKit
import Combine
import Foundation

@MainActor
class ClaudeSessionMonitor: ObservableObject {
    @Published var instances: [SessionState] = []
    @Published var pendingInstances: [SessionState] = []

    private var cancellables = Set<AnyCancellable>()

    init() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)

        InterruptWatcherManager.shared.delegate = self
    }

    // MARK: - Monitoring Lifecycle

    func startMonitoring() {
        HookSocketServer.shared.start(
            onEvent: { event in
                Task {
                    await SessionStore.shared.process(.hookReceived(event))
                }

                // The interrupt watcher reads ~/.claude/projects/<…>.jsonl, which only exists
                // for Claude. Skip it for Codex to avoid failing file-opens / error spam (GW-138).
                // Codex transcript support is deferred to the session-observability work.
                if event.sessionPhase == .processing, event.source != "codex" {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.startWatching(
                            sessionId: event.sessionId,
                            cwd: event.cwd,
                            transcriptPath: event.transcriptPath
                        )
                    }
                }

                if event.status == "ended" {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.stopWatching(sessionId: event.sessionId)
                    }
                }

                if event.event == "Stop" {
                    HookSocketServer.shared.cancelPendingPermissions(sessionId: event.sessionId)
                }

                if event.event == "PostToolUse", let toolUseId = event.toolUseId {
                    Task { @MainActor in
                        AlertHistoryStore.shared.markPermissionOutcome(
                            sessionId: event.sessionId,
                            toolUseId: toolUseId,
                            outcome: "allowed"
                        )
                    }
                    // GW-413: session + tool let this also release a gate held on
                    // a provisional id, which the real toolUseId can never match.
                    HookSocketServer.shared.cancelPendingPermission(
                        toolUseId: toolUseId,
                        sessionId: event.sessionId,
                        toolName: event.tool
                    )
                }
            },
            // GW-408: a gate the server refused outright. It never becomes a
            // pending permission, so it has no other route into the app.
            onGateBlocked: { event, reason in
                Task {
                    await SessionStore.shared.process(.permissionBlocked(event: event, reason: reason))
                }
            }
        )
    }

    func stopMonitoring() {
        HookSocketServer.shared.stop()
    }

    // MARK: - Permission Handling

    /// The specific pending permission (active or queued).
    private static func gateContext(_ session: SessionState, toolUseId: String) -> PermissionContext? {
        if let active = session.activePermission, active.toolUseId == toolUseId {
            return active
        }
        return session.pendingPermissions.first { $0.toolUseId == toolUseId }
    }

    private enum NativeAnswer { case approve, deny }

    /// Answer Codex's native terminal prompt on the user's behalf.
    /// `.terminalFirst` gates have an addressable pane by construction (the
    /// mode is only assigned to cmux/tmux sessions); `.handedOff` gates never
    /// do — the UI offers a terminal jump instead, so reaching here with one
    /// is a guard failure, not an injection attempt.
    private static func answerNativeCodexPrompt(
        _ answer: NativeAnswer, session: SessionState, gate: PermissionContext
    ) async -> Bool {
        guard gate.gateMode == .terminalFirst else { return false }
        let target: TmuxTarget?
        switch MultiplexerTargetResolver.resolve(session: session) {
        case .cmux(let workspace, let surface):
            target = .cmux(workspace: workspace, surface: surface)
        case .tmuxTty(let tty):
            target = await TmuxTargetFinder.shared.findTarget(forTty: tty)
        case .unresolvable:
            target = nil
        }
        guard let target else { return false }
        switch answer {
        case .approve:
            return await ToolApprovalHandler.shared.codexApproveNative(
                target: target, toolName: gate.toolName)
        case .deny:
            return await ToolApprovalHandler.shared.codexDenyNative(target: target)
        }
    }

    func approvePermission(sessionId: String,
                           toolUseId: String,
                           delivered: (@Sendable (Bool) -> Void)? = nil) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  session.pendingPermissions.contains(where: { $0.toolUseId == toolUseId })
                    || session.activePermission?.toolUseId == toolUseId else {
                delivered?(false)
                return
            }

            // Codex adaptive flow: the socket for this gate was already
            // released so the native prompt could render — the verdict rides
            // a keystroke into the session's pane instead.
            //
            // Resolves on transport success (instant-clear, matching Claude's
            // feel). OWNER DECISION 2026-08-18, overriding the adversarial
            // review's finding #1: transport success is not proof Codex
            // consumed the key, so a missed key (remapped bindings, unknown
            // menu variant) clears the card while the terminal still waits.
            // Keelan accepted that occasional silent miss over an
            // acknowledgment state that made every click read as lag. The
            // per-menu key map ('y' exec / '1' list widgets, Esc deny) keeps
            // the known miss sources closed.
            if let gate = Self.gateContext(session, toolUseId: toolUseId), gate.gateMode != .held {
                let ok = await Self.answerNativeCodexPrompt(.approve, session: session, gate: gate)
                if ok {
                    Task { @MainActor in
                        AlertHistoryStore.shared.markPermissionOutcome(
                            sessionId: sessionId, toolUseId: toolUseId, outcome: "allowed")
                    }
                    await SessionStore.shared.process(
                        .permissionApproved(sessionId: sessionId, toolUseId: toolUseId))
                }
                delivered?(ok)
                return
            }

            HookSocketServer.shared.respondToPermission(
                toolUseId: toolUseId,
                decision: "allow"
            ) { wasDelivered in
                // GW-207 (review P2): stamp history per the actual write
                // result - a stale socket means the agent never got the
                // verdict, so that's a timeout, not an approval.
                Task { @MainActor in
                    AlertHistoryStore.shared.markPermissionOutcome(
                        sessionId: sessionId,
                        toolUseId: toolUseId,
                        outcome: wasDelivered ? "allowed" : "timedOut"
                    )
                }
                Task {
                    await SessionStore.shared.process(
                        wasDelivered
                            ? .permissionApproved(sessionId: sessionId, toolUseId: toolUseId)
                            : .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
                delivered?(wasDelivered)
            }
        }
    }

    /// Compatibility wrapper for non-row call sites; UI gate bars should pass
    /// their visible toolUseId to avoid verdict drift across back-to-back gates.
    func approvePermission(sessionId: String,
                           delivered: (@Sendable (Bool) -> Void)? = nil) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                delivered?(false)
                return
            }
            approvePermission(sessionId: sessionId, toolUseId: permission.toolUseId, delivered: delivered)
        }
    }

    func denyPermission(sessionId: String,
                        toolUseId: String,
                        reason: String?,
                        delivered: (@Sendable (Bool) -> Void)? = nil) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  session.pendingPermissions.contains(where: { $0.toolUseId == toolUseId })
                    || session.activePermission?.toolUseId == toolUseId else {
                delivered?(false)
                return
            }

            // Codex adaptive flow — see approvePermission (same owner
            // decision: instant-clear on transport success).
            if let gate = Self.gateContext(session, toolUseId: toolUseId), gate.gateMode != .held {
                let ok = await Self.answerNativeCodexPrompt(.deny, session: session, gate: gate)
                if ok {
                    Task { @MainActor in
                        AlertHistoryStore.shared.markPermissionOutcome(
                            sessionId: sessionId, toolUseId: toolUseId, outcome: "denied")
                    }
                    await SessionStore.shared.process(
                        .permissionDenied(sessionId: sessionId, toolUseId: toolUseId, reason: reason))
                }
                delivered?(ok)
                return
            }

            HookSocketServer.shared.respondToPermission(
                toolUseId: toolUseId,
                decision: "deny",
                reason: reason
            ) { wasDelivered in
                // GW-207 (review P2): see approvePermission - write result
                // decides the recorded outcome.
                Task { @MainActor in
                    AlertHistoryStore.shared.markPermissionOutcome(
                        sessionId: sessionId,
                        toolUseId: toolUseId,
                        outcome: wasDelivered ? "denied" : "timedOut"
                    )
                }
                Task {
                    await SessionStore.shared.process(
                        wasDelivered
                            ? .permissionDenied(sessionId: sessionId,
                                                toolUseId: toolUseId,
                                                reason: reason)
                            : .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
                delivered?(wasDelivered)
            }
        }
    }

    /// Compatibility wrapper for non-row call sites; UI gate bars should pass
    /// their visible toolUseId to avoid verdict drift across back-to-back gates.
    func denyPermission(sessionId: String, reason: String?,
                        delivered: (@Sendable (Bool) -> Void)? = nil) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                delivered?(false)
                return
            }
            denyPermission(
                sessionId: sessionId,
                toolUseId: permission.toolUseId,
                reason: reason,
                delivered: delivered
            )
        }
    }

    /// Archive (remove) a session from the instances list
    func archiveSession(sessionId: String) {
        Task {
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        }
    }

    // MARK: - State Update

    private func updateFromSessions(_ sessions: [SessionState]) {
        instances = sessions
        pendingInstances = sessions.filter { $0.needsAttention }
    }

    // MARK: - History Loading (for UI)

    /// Request history load for a session
    func loadHistory(sessionId: String, cwd: String) {
        Task {
            await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
        }
    }
}

// MARK: - Interrupt Watcher Delegate

extension ClaudeSessionMonitor: JSONLInterruptWatcherDelegate {
    nonisolated func didDetectInterrupt(sessionId: String) {
        Task {
            await SessionStore.shared.process(.interruptDetected(sessionId: sessionId))
        }

        Task { @MainActor in
            InterruptWatcherManager.shared.stopWatching(sessionId: sessionId)
        }
    }
}
