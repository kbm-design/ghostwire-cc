//
//  AgentHookConfig.swift
//  Ghostwire
//
//  One settings code path for every agent's hook integration (GW-144).
//  Adding an agent (e.g. gemini-cli, GW-174) = appending one entry to `all`;
//  the Agents tab renders whatever is listed here.
//

import Defaults
import Foundation

struct AgentHookConfig: Identifiable {
    /// AgentIdentity key ("claude" | "codex") — drives the identity tint.
    let id: String
    let displayName: String
    /// Gates the silent launch-time auto-install so uninstall sticks (GW-144).
    let enabledKey: Defaults.Key<Bool>
    /// CLI present on this machine (config dir exists).
    let isDetected: () -> Bool
    let isInstalled: () -> Bool
    let install: () -> Void
    let uninstall: () -> Void
    /// Agent hashes + trusts hooks CLI-side (Codex `/hooks`). Shows the
    /// trust row in settings — status detection lands with GW-196.
    let requiresCLITrust: Bool

    static let all: [AgentHookConfig] = [claude, codex]

    static let claude = AgentHookConfig(
        id: "claude",
        displayName: "Claude Code",
        enabledKey: .claudeHooksEnabled,
        isDetected: { configDirExists(".claude") },
        isInstalled: HookInstaller.isInstalled,
        install: HookInstaller.installIfNeeded,
        uninstall: HookInstaller.uninstall,
        requiresCLITrust: false
    )

    static let codex = AgentHookConfig(
        id: "codex",
        displayName: "Codex",
        enabledKey: .codexHooksEnabled,
        isDetected: { configDirExists(".codex") },
        isInstalled: CodexHookInstaller.isInstalled,
        install: CodexHookInstaller.installIfNeeded,
        uninstall: CodexHookInstaller.uninstall,
        requiresCLITrust: true
    )

    /// Install hooks at launch for every agent whose toggle is on.
    /// Replaces the unconditional installs in GhostwireApp.
    static func installEnabledAgents() {
        for agent in all where Defaults[agent.enabledKey] {
            agent.install()
        }
    }

    private static func configDirExists(_ name: String) -> Bool {
        FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(name).path
        )
    }
}
