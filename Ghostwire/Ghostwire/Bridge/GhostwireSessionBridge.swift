import AppKit
import Combine
import Defaults
import Foundation
import SwiftUI

@MainActor
final class GhostwireSessionBridge: ObservableObject {
    static let shared = GhostwireSessionBridge()

    let sessionMonitor = ClaudeSessionMonitor()
    let panelViewModel = AgentPanelViewModel()
    weak var ghostwireViewModel: GhostwireViewModel?

    /// Bumps to a new UUID each time a new pending permission arrives while the notch
    /// is closed and the terminal isn't visible. ContentView observes this to fire the
    /// passive edge-glow animation. Never opens the notch; never steals focus.
    @Published var passiveAlertPulse: UUID = UUID()

    /// Tint of the agent that raised the most recent pending permission — drives the
    /// edge-glow color so it reflects WHICH agent needs you (GW-138).
    @Published var passiveAlertTint: Color = AgentIdentity.claude

    private var cancellables = Set<AnyCancellable>()
    private var knownWaitingForInputSessionIDs = Set<String>()
    private var hasSeededWaitingForInputSessions = false
    private var knownPendingPermissionIDs = Set<String>()
    private var hasSeededPendingPermissions = false
    /// GW-207: last-seen user-message date per session, to detect a fresh user
    /// reply that should resolve a prior "ready" alert to "responded".
    private var lastUserMessageDates: [String: Date] = [:]
    private var hasSeededUserMessageDates = false

    private init() {
        panelViewModel.$contentType
            .sink { contentType in
                let height: CGFloat
                switch contentType {
                case .chat:
                    height = 500
                case .instances, .menu:
                    height = openNotchSize.height
                }

                if GhostwireViewCoordinator.shared.buddyPanelHeight != height {
                    GhostwireViewCoordinator.shared.buddyPanelHeight = height
                }
            }
            .store(in: &cancellables)

        sessionMonitor.$instances
            .sink { [weak self] (instances: [SessionState]) in
                self?.handleWaitingForInputSessions(instances)
                self?.handleUserRepliesForReadyAlerts(instances)
            }
            .store(in: &cancellables)

        sessionMonitor.$pendingInstances
            .sink { [weak self] (pendingInstances: [SessionState]) in
                self?.handlePendingPermissionSessions(pendingInstances)
            }
            .store(in: &cancellables)

        sessionMonitor.$instances
            .map { instances in
                instances.contains { $0.phase.isActive || $0.phase.needsAttention }
            }
            .removeDuplicates()
            .sink { hasActive in
                GhostwireViewCoordinator.shared.toggleExpandingView(
                    status: hasActive,
                    type: .buddy
                )
            }
            .store(in: &cancellables)
    }

    func startMonitoring() {
        // Don't bind the hook socket when running as a unit-test host — it would
        // unlink /tmp/com.ghostwire.notch.sock out from under a live Ghostwire instance.
        // (Also keeps test runs from scanning the dev machine's real transcript trees.)
        guard NSClassFromString("XCTestCase") == nil else { return }
        sessionMonitor.startMonitoring()
        // GW-194: register sessions that predate hook install or were idle at
        // launch — their transcripts are on disk even though no event will come
        Task { await SessionDiscoveryService.shared.start() }
    }

    func stopMonitoring() {
        sessionMonitor.stopMonitoring()
        Task { await SessionDiscoveryService.shared.stop() }
    }

    private func handleWaitingForInputSessions(_ instances: [SessionState]) {
        let waitingSessions = instances.filter { $0.phase == .waitingForInput }
        let currentWaitingSessionIDs = Set(waitingSessions.map { $0.sessionId })

        defer {
            knownWaitingForInputSessionIDs = currentWaitingSessionIDs
            hasSeededWaitingForInputSessions = true
        }

        guard hasSeededWaitingForInputSessions else { return }

        let newlyWaitingSessions = waitingSessions.filter {
            !knownWaitingForInputSessionIDs.contains($0.sessionId)
        }

        guard !newlyWaitingSessions.isEmpty else { return }

        Task { [weak self] in
            await self?.playWaitingForInputNotificationIfNeeded(for: newlyWaitingSessions)
        }
    }

    /// GW-207: when a session's last user-message date advances, the user
    /// replied — resolve any prior unanswered "ready" alert for it to
    /// "responded". The cheapest honest signal: conversationInfo already
    /// carries lastUserMessageDate, so this rides the existing instances feed
    /// with no new file watching. Seeds silently on the first emission so
    /// historical dates don't retroactively mark old alerts.
    private func handleUserRepliesForReadyAlerts(_ instances: [SessionState]) {
        defer { hasSeededUserMessageDates = true }

        for session in instances {
            guard let newDate = session.lastUserMessageDate else { continue }
            let previous = lastUserMessageDates[session.sessionId]
            lastUserMessageDates[session.sessionId] = newDate

            guard hasSeededUserMessageDates else { continue }
            // Only a strictly newer user message counts as a fresh reply.
            guard previous == nil || newDate > previous! else { continue }

            AlertHistoryStore.shared.markReadyResponded(
                sessionId: session.sessionId,
                userMessageDate: newDate
            )
        }
    }

    private func handlePendingPermissionSessions(_ pendingInstances: [SessionState]) {
        let currentPendingPermissionIDs = Set(pendingInstances.compactMap { $0.pendingToolId })

        defer {
            knownPendingPermissionIDs = currentPendingPermissionIDs
            hasSeededPendingPermissions = true
        }

        guard hasSeededPendingPermissions else { return }

        let hasNewPendingPermission = currentPendingPermissionIDs.contains {
            !knownPendingPermissionIDs.contains($0)
        }

        guard hasNewPendingPermission else { return }

        // The Agents tab is the approval surface — clear any persisted
        // hidden state (pre-rule prefs) so the pending approval is
        // reachable regardless of how this alert is surfaced (GW-144).
        NotchTab.ensureAgentsVisibleForApproval()

        // GW-209: resolve the triggering session FIRST (its pid drives the
        // per-session visibility check), against the *current* known set —
        // `defer` rewrites `knownPendingPermissionIDs` on function exit, so
        // capture it here before the async hop.
        guard let triggering = pendingInstances.first(where: {
            guard let id = $0.pendingToolId else { return false }
            return !knownPendingPermissionIDs.contains(id)
        }) else {
            return
        }

        // The gate (glow/haptic/record vs open) hinges on whether the
        // triggering session's own pane is focused — an async probe routed to
        // the multiplexer when relevant. Mirror playWaitingForInputNotification:
        // hop into a Task and finish the main-actor effects there, leaving the
        // synchronous publish/seed flow above untouched.
        Task { [weak self] in
            await self?.raisePendingPermissionAlert(for: triggering)
        }
    }

    /// GW-209: apply the per-session open rule for a freshly-arrived pending
    /// permission and raise the matching effects. `paneFocused` is the triggering
    /// session's own pane — not "any terminal on screen" — so a hidden lane pings
    /// even with cmux in front. Falls back to the coarse space check only when the
    /// triggering session has no pid (degrade honestly).
    private func raisePendingPermissionAlert(for triggering: SessionState) async {
        let paneFocused: Bool
        if let pid = triggering.pid {
            paneFocused = await TerminalVisibilityDetector.isSessionFocused(sessionPid: pid)
        } else {
            // No pid → can't resolve a specific pane; degrade to the old coarse
            // "any terminal visible on this space" signal.
            paneFocused = TerminalVisibilityDetector.isTerminalVisibleOnCurrentSpace()
        }

        let decision = PermissionOpenRule.decide(
            mode: Defaults[.permissionAutoOpenMode],
            notchClosed: ghostwireViewModel?.notchState == .closed,
            paneFocused: paneFocused
        )

        guard decision.alert || decision.open else { return }

        if decision.alert {
            // Tint the glow to the agent that raised the new pending permission (GW-138).
            passiveAlertTint = AgentIdentity.tint(for: triggering.agent)
            // GW-144/GW-207: alert history records the alerts actually raised,
            // with the folder + command + tool_use_id so the row reads and the
            // verdict can later stamp an outcome (allowed/denied/timedOut).
            AlertHistoryStore.shared.record(
                agent: triggering.agent,
                sessionId: triggering.sessionId,
                kind: "permission",
                detail: triggering.pendingToolName,
                folder: triggering.folderName,
                command: triggering.pendingCommandSummary,
                toolUseId: triggering.pendingToolId
            )

            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            passiveAlertPulse = UUID()
        }

        if decision.open {
            GhostwireViewCoordinator.shared.toggleExpandingView(status: true, type: .buddy)
        }
    }

    private func playWaitingForInputNotificationIfNeeded(for sessions: [SessionState]) async {
        for session in sessions {
            let isFocused: Bool
            if let pid = session.pid {
                isFocused = await TerminalVisibilityDetector.isSessionFocused(sessionPid: pid)
            } else {
                isFocused = false
            }

            guard !isFocused else { continue }

            if let soundName = GhostwireSettings.notificationSound.soundName {
                NSSound(named: soundName)?.play()
            }
            // GW-144/GW-207: alert history records the alerts actually raised,
            // with the folder so the row reads. Outcome ("responded") is
            // stamped later if a user message follows this ping.
            AlertHistoryStore.shared.record(
                agent: session.agent,
                sessionId: session.sessionId,
                kind: "ready",
                folder: session.folderName
            )
            return
        }
    }
}
