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
    /// Re-check whether the agent currently trusts our installed hooks.
    /// `nil` for agents with no CLI trust gate (e.g. Claude) — one code path:
    /// surfaces never fork on agent, they just skip the trust line when nil.
    let trustStatus: () -> CodexHookTrust.TrustStatus?

    // Scoped to Claude + Codex for now (2026-08-17) — the third-party cluster
    // below stays defined (GenericHookInstaller specs untouched) so re-adding
    // an agent later is a one-line append, not new work.
    static let all: [AgentHookConfig] = [claude, codex]

    static let claude = AgentHookConfig(
        id: "claude",
        displayName: "Claude Code",
        enabledKey: .claudeHooksEnabled,
        isDetected: { configDirExists(".claude") },
        isInstalled: HookInstaller.isInstalled,
        install: HookInstaller.installIfNeeded,
        uninstall: HookInstaller.uninstall,
        requiresCLITrust: false,
        // Claude has no hook-trust gate — hooks fire as soon as they're written.
        trustStatus: { nil }
    )

    static let codex = AgentHookConfig(
        id: "codex",
        displayName: "Codex",
        enabledKey: .codexHooksEnabled,
        isDetected: { configDirExists(".codex") },
        isInstalled: CodexHookInstaller.isInstalled,
        install: CodexHookInstaller.installIfNeeded,
        uninstall: CodexHookInstaller.uninstall,
        requiresCLITrust: true,
        trustStatus: { CodexHookTrust.currentStatus() }
    )

    // Third-party agent cluster (GW-175). All run through GenericHookInstaller
    // with their own HookInstallSpec, and self-guard on the CLI binary being
    // present (config dirs linger after a CLI is removed, so we detect by the
    // binary, not the dir). None has a Codex-style `/hooks` trust gate, so
    // requiresCLITrust is false.
    static let cursor = thirdParty("Cursor", .cursorHooksEnabled, GenericHookInstaller.cursor)
    static let copilot = thirdParty("Copilot", .copilotHooksEnabled, GenericHookInstaller.copilot)
    static let factory = thirdParty("Factory droid", .factoryHooksEnabled, GenericHookInstaller.factory)
    static let qoder = thirdParty("Qoder", .qoderHooksEnabled, GenericHookInstaller.qoder)
    static let codebuddy = thirdParty("CodeBuddy", .codebuddyHooksEnabled, GenericHookInstaller.codebuddy)
    // GW-174. gemini-cli warns about *workspace* hooks only, so a user-scope
    // install in ~/.gemini/settings.json needs no trust step.
    static let gemini = thirdParty("Gemini CLI", .geminiHooksEnabled, GenericHookInstaller.gemini)

    /// Build a cluster agent descriptor backed by GenericHookInstaller + a spec.
    private static func thirdParty(
        _ displayName: String,
        _ enabledKey: Defaults.Key<Bool>,
        _ spec: HookInstallSpec
    ) -> AgentHookConfig {
        AgentHookConfig(
            id: spec.agentId,
            displayName: displayName,
            enabledKey: enabledKey,
            isDetected: { GenericHookInstaller.isBinaryAvailable(spec.binaryName) },
            isInstalled: { GenericHookInstaller.isInstalled(spec) },
            install: { GenericHookInstaller.installIfNeeded(spec) },
            uninstall: { GenericHookInstaller.uninstall(spec) },
            requiresCLITrust: false,
            trustStatus: { nil }
        )
    }

    /// Install hooks at launch for every agent whose toggle is on.
    /// Replaces the unconditional installs in GhostwireApp.
    static func installEnabledAgents() {
        for agent in all where Defaults[agent.enabledKey] {
            agent.install()
        }
        // Re-check install + trust state after the launch-time installs so the
        // shared model (and the proactive re-trust prompt) reflect any hook
        // change picked up this launch — e.g. the buddi -> ghostwire rename that
        // leaves Codex distrusting the new command (GW-196). Cheap file I/O.
        Task { @MainActor in HookStatusModel.shared.refresh() }
    }

    private static func configDirExists(_ name: String) -> Bool {
        FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(name).path
        )
    }
}
