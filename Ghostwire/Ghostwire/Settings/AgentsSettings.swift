//
//  AgentsSettings.swift
//  Ghostwire
//
//  Agents settings tab (GW-144, formerly ClaudeCodeSettings).
//  Per-agent hook rows render from AgentHookConfig.all — one code path
//  for Claude / Codex / future agents, never parallel implementations.
//

import AppKit
import Defaults
import SwiftUI

struct AgentsSettings: View {
    @State private var selectedSound = GhostwireSettings.notificationSound
    @ObservedObject private var usageService = UsageService.shared
    @Default(.messageDisplayMode) private var messageDisplayMode
    @Default(.permissionAutoOpenMode) private var permissionAutoOpenMode
    @Default(.alertHistoryMaxEntries) private var alertHistoryMaxEntries
    @Default(.alertHistoryMaxAgeDays) private var alertHistoryMaxAgeDays

    @ObservedObject private var hookStatus = HookStatusModel.shared
    @ObservedObject private var cmuxStatus = CmuxSocketStatusModel.shared

    /// Agents whose hooks are installed but no longer trusted by the CLI.
    private var retrustAgents: [AgentHookConfig] {
        AgentHookConfig.all.filter { hookStatus.status(for: $0.id).needsRetrust }
    }

    var body: some View {
        Form {
            // Proactive re-trust prompt (GW-196): when a hook change (e.g. the
            // buddi -> ghostwire rename) leaves Codex distrusting our hooks, they
            // silently stop firing. Surface it at the top of the tab on open so
            // the user fixes it before hitting a dead approval. Recomputed on
            // appearance — no polling.
            if !retrustAgents.isEmpty {
                Section {
                    ForEach(retrustAgents) { agent in
                        RetrustBanner(agentName: agent.displayName)
                    }
                }
            }

            Section {
                ForEach(AgentHookConfig.all) { agent in
                    AgentHooksRow(agent: agent)
                }
            } header: {
                Text("Agents")
            } footer: {
                Text("Hooks forward agent events to Ghostwire via Unix socket.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .leadingFooter()
            }

            // GW-173: pull side — let agents read the Shelf over local MCP.
            ShelfAccessSection()

            // Reserved IA slot (GW-144): per-agent approval modes are gated
            // on the PreToolUse-as-gate work (GW-139) — greyed, not wired.
            Section {
                HStack {
                    Text("Approval mode")
                    Spacer()
                    Text("Full gate")
                        .foregroundStyle(.secondary)
                }
                .opacity(0.4)
            } footer: {
                Text("Per-agent approval modes (auto-approve · plan · review · full gate) are planned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .leadingFooter()
            }

            Section {
                Picker("Message display", selection: $messageDisplayMode) {
                    Text("Inline").tag(MessageDisplayMode.inline)
                    Text("Full raw").tag(MessageDisplayMode.fullRaw)
                }
                Picker("Open for approvals", selection: $permissionAutoOpenMode) {
                    Text("Smart").tag(PermissionAutoOpenMode.smart)
                    Text("Always").tag(PermissionAutoOpenMode.always)
                    Text("Never").tag(PermissionAutoOpenMode.never)
                }
            } header: {
                Text("Display")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Full raw shows prompts and commands verbatim — monospaced, unrendered, never truncated.")
                    Text("Smart opens the notch only when the asking session's pane isn't already in front of you. Always opens on every approval; Never only glows.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .leadingFooter()
            }

            Section {
                Picker("Keep alerts", selection: $alertHistoryMaxEntries) {
                    ForEach([25, 50, 100, 250, 500], id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                Picker("For up to", selection: $alertHistoryMaxAgeDays) {
                    ForEach([1, 3, 7, 14, 30], id: \.self) { days in
                        Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                    }
                }
            } header: {
                Text("Alert history")
            } footer: {
                Text("Caps the recorded permission and ready alerts. Whichever limit hits first wins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .leadingFooter()
            }

            Section {
                Picker("Sound", selection: $selectedSound) {
                    ForEach(NotificationSound.allCases, id: \.self) { sound in
                        Text(sound.rawValue).tag(sound)
                    }
                }
                .onChange(of: selectedSound) { _, newValue in
                    GhostwireSettings.notificationSound = newValue
                    if let name = newValue.soundName {
                        NSSound(named: NSSound.Name(name))?.play()
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Plays when an agent finishes and is ready for input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .leadingFooter()
            }

            Section {
                HStack {
                    Text("Socket")
                    Spacer()
                    let active = FileManager.default.fileExists(atPath: HookSocketServer.socketPath)
                    Circle()
                        .fill(active ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(active ? "Active" : "Inactive")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Usage tracking")
                    Spacer()
                    if usageService.isAvailable {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Connected")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Not available")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Status")
            } footer: {
                Text("The socket is shared by all agents. OAuth login required for plan usage display.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .leadingFooter()
            }

            // cmux socket access (GW-206). Multiplexer-level, not per-agent:
            // cmux addresses surfaces for whichever agent runs in them, so one
            // row covers Claude and Codex alike. Hidden entirely when cmux
            // isn't installed (.unavailable) — never alarm non-cmux users.
            if let access = cmuxStatus.access,
               CmuxSocketStatusPresentation.isVisible(access),
               let row = CmuxSocketStatusPresentation.row(for: access) {
                Section {
                    CmuxSocketRow(row: row, isRefreshing: cmuxStatus.isRefreshing) {
                        cmuxStatus.refresh()
                    }
                } header: {
                    Text("cmux")
                } footer: {
                    Text("Lets Ghostwire send messages and focus cmux surfaces. cmux is optional.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .leadingFooter()
                }
            }
        }
        .onAppear {
            selectedSound = GhostwireSettings.notificationSound
            // Re-check install + trust from disk every time the tab appears, so
            // a hook change made outside the app (rename, CLI edit) shows up.
            hookStatus.refresh()
            // Live cmux socket probe (off the main thread) on every appearance —
            // catches a cmux start/stop or a mode change made outside the app.
            cmuxStatus.refresh()
        }
    }
}

/// Top-of-tab proactive prompt shown when an installed agent's hooks are no
/// longer trusted by its CLI. Amber, with a copyable `/hooks` instruction.
private struct RetrustBanner: View {
    let agentName: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(agentName) stopped firing Ghostwire hooks")
                    .fontWeight(.medium)
                Text("The hooks changed, so \(agentName) marked them untrusted. Run /hooks in \(agentName) and trust them to restore approvals.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString("/hooks", forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy /hooks",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            }
        }
    }
}

/// One agent's hook row: identity dot + name, then install state.
/// Codex additionally shows the CLI-trust row (status detection = GW-196).
/// State comes from the shared HookStatusModel (review F4) so this row,
/// the notch menu, and onboarding can never disagree.
private struct AgentHooksRow: View {
    let agent: AgentHookConfig

    @ObservedObject private var hookStatus = HookStatusModel.shared

    var body: some View {
        let status = hookStatus.status(for: agent.id)
        HStack {
            Circle()
                .fill(AgentIdentity.tint(for: agent.id))
                .frame(width: 8, height: 8)
            Text(agent.displayName)
            Spacer()
            if !status.detected {
                Text("Not detected")
                    .foregroundStyle(.secondary)
            } else if status.installed {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Installed")
                        .foregroundStyle(.secondary)
                }
                Button("Uninstall") {
                    agent.uninstall()
                    Defaults[agent.enabledKey] = false
                    hookStatus.refresh()
                }
            } else {
                Button("Install") {
                    Defaults[agent.enabledKey] = true
                    agent.install()
                    hookStatus.refresh()
                }
            }
        }
        .onAppear { hookStatus.refresh() }

        // Codex (and any CLI-trust agent) shows a live trust row once its hooks
        // are installed. Trusted → green dot; re-trust required → amber dot with
        // a copyable /hooks instruction (GW-196). `.notConfigured` is treated as
        // benign and stays silent — it only means there's nothing to trust yet.
        if agent.requiresCLITrust,
           status.detected,
           status.installed,
           let trust = status.trust,
           trust != .notConfigured {
            CodexTrustRow(agentName: agent.displayName, status: trust)
        }
    }
}

/// Hook-trust status for a CLI-trust agent (Codex). Green when trusted; amber
/// with a copyable `/hooks` instruction when a re-trust is required.
private struct CodexTrustRow: View {
    let agentName: String
    let status: CodexHookTrust.TrustStatus

    @State private var copied = false

    private var instruction: String { "/hooks" }

    var body: some View {
        HStack {
            Text("Hook trust")
            Spacer()
            if status == .trusted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Trusted")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Re-trust required")
                    .foregroundStyle(.secondary)
                Button {
                    copyInstruction()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy \(instruction)")
            }
        }
        .help(status == .trusted
              ? "\(agentName) trusts the Ghostwire hooks."
              : "\(agentName) stopped firing the Ghostwire hooks after they changed. Run \(instruction) in \(agentName) and trust them to restore approvals.")
    }

    private func copyInstruction() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(instruction, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}

/// cmux socket-access row (GW-206). Glyph + tint encode severity (green ok /
/// amber action / gray neutral); the remedy line is shown beneath and is
/// copyable. A refresh affordance re-runs the live probe on demand. Drives off
/// the pure `CmuxSocketStatusPresentation.Row` so the mapping stays testable.
private struct CmuxSocketRow: View {
    let row: CmuxSocketStatusPresentation.Row
    let isRefreshing: Bool
    let onRefresh: () -> Void

    @State private var copied = false

    private var tint: Color {
        switch row.severity {
        case .ok:      return .green
        case .action:  return .orange
        case .neutral: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Socket access")
                Spacer()
                Image(systemName: row.glyph)
                    .foregroundStyle(tint)
                Text(row.status)
                    .foregroundStyle(.secondary)
                if let remedy = row.remedy {
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(remedy, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("Copy fix")
                }
                Button {
                    onRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
                .help("Re-check cmux socket access")
            }

            if let remedy = row.remedy {
                Text(remedy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
