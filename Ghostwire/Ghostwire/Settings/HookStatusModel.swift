//
//  HookStatusModel.swift
//  Ghostwire
//
//  Shared hook install/detection state (GW-144 review F4). All surfaces
//  (Agents settings rows, notch menu, onboarding) read this one model and
//  every install/uninstall path calls refresh() — so two visible surfaces
//  can never disagree about whether hooks are installed.
//

import Combine
import Foundation

@MainActor
final class HookStatusModel: ObservableObject {
    static let shared = HookStatusModel()

    struct AgentStatus: Equatable {
        var detected = false
        var installed = false
    }

    @Published private(set) var byAgent: [String: AgentStatus] = [:]

    private init() {
        refresh()
    }

    func status(for agentId: String) -> AgentStatus {
        byAgent[agentId] ?? AgentStatus()
    }

    /// Re-read detection + install state from disk for every agent.
    /// Call after any install/uninstall and on surface appearance (also
    /// catches changes made outside the app, e.g. via the CLI).
    func refresh() {
        var next: [String: AgentStatus] = [:]
        for agent in AgentHookConfig.all {
            next[agent.id] = AgentStatus(
                detected: agent.isDetected(),
                installed: agent.isInstalled()
            )
        }
        if next != byAgent {
            byAgent = next
        }
    }
}
