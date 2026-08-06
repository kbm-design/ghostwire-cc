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
                    HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
                }
            },
            onPermissionFailure: { sessionId, toolUseId in
                // GW-207: a held permission socket that can no longer be written
                // (hook process gone / its wait elapsed) is the provable
                // "timed out" signal. Stamp the matching history alert. Pending
                // permissions cleared by a plain Stop with no verdict carry no
                // such signal — they stay unanswered (the absence state).
                Task { @MainActor in
                    AlertHistoryStore.shared.markPermissionOutcome(
                        sessionId: sessionId,
                        toolUseId: toolUseId,
                        outcome: "timedOut"
                    )
                }
                Task {
                    await SessionStore.shared.process(
                        .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
            }
        )
    }

    func stopMonitoring() {
        HookSocketServer.shared.stop()
    }

    // MARK: - Permission Handling

    func approvePermission(sessionId: String, toolUseId: String) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  session.pendingPermissions.contains(where: { $0.toolUseId == toolUseId })
                    || session.activePermission?.toolUseId == toolUseId else {
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
            }

            await SessionStore.shared.process(
                .permissionApproved(sessionId: sessionId, toolUseId: toolUseId)
            )
        }
    }

    func denyPermission(sessionId: String, toolUseId: String, reason: String?) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  session.pendingPermissions.contains(where: { $0.toolUseId == toolUseId })
                    || session.activePermission?.toolUseId == toolUseId else {
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
            }

            await SessionStore.shared.process(
                .permissionDenied(sessionId: sessionId, toolUseId: toolUseId, reason: reason)
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
