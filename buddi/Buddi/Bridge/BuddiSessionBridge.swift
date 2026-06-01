import AppKit
import Combine
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

    private var cancellables = Set<AnyCancellable>()
    private var knownWaitingForInputSessionIDs = Set<String>()
    private var hasSeededWaitingForInputSessions = false
    private var knownPendingPermissionIDs = Set<String>()
    private var hasSeededPendingPermissions = false

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
        sessionMonitor.startMonitoring()
    }

    func stopMonitoring() {
        sessionMonitor.stopMonitoring()
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

        guard hasNewPendingPermission,
              ghostwireViewModel?.notchState == .closed,
              !TerminalVisibilityDetector.isTerminalVisibleOnCurrentSpace()
        else {
            return
        }

        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        passiveAlertPulse = UUID()

        GhostwireViewCoordinator.shared.toggleExpandingView(status: true, type: .buddy)
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
            return
        }
    }
}
