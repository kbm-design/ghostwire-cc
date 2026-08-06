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
                    HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
                }
            }
        )
    }

    func stopMonitoring() {
        HookSocketServer.shared.stop()
    }

    // MARK: - Permission Handling

    /// GW-322: `delivered` mirrors `denyPermission` — it reports whether the
    /// verdict actually reached the held hook socket, so an Accept can show
    /// sent/failed instead of assuming it landed.
    ///
    /// GW-362: the session event is emitted **from inside** that completion and
    /// branches on the write result. It used to be sent unconditionally right
    /// after the call, so a verdict that never reached the agent still recorded
    /// as an approval — `AlertHistoryStore` said `timedOut` while `SessionStore`
    /// said approved, about the same event. Worse, `.permissionApproved` clears
    /// `waitingForApproval`, which tears down the plan-review bar and takes its
    /// failed/Terminal affordance with it on the one path where it matters.
    func approvePermission(sessionId: String,
                           delivered: (@Sendable (Bool) -> Void)? = nil) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                delivered?(false)
                return
            }

            let toolUseId = permission.toolUseId
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

    /// GW-321: `delivered` reports whether the verdict actually reached the held
    /// hook socket, so a Choice answer can show sent/failed rather than assuming
    /// it landed. A stale socket means the agent never got it.
    ///
    /// GW-362: same conditional emit as `approvePermission`, and it matters more
    /// here — this one call is the transport for three affordances (plain Deny,
    /// State B's Choice answer, and State C's Revise), so the unconditional
    /// `.permissionDenied` was the same defect across A, B and C.
    func denyPermission(sessionId: String, reason: String?,
                        delivered: (@Sendable (Bool) -> Void)? = nil) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                delivered?(false)
                return
            }

            let toolUseId = permission.toolUseId
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
