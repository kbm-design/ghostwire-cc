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
    @Default(.alertHistoryMaxEntries) private var alertHistoryMaxEntries
    @Default(.alertHistoryMaxAgeDays) private var alertHistoryMaxAgeDays

    var body: some View {
        Form {
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
            }

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
            }

            Section {
                Picker("Message display", selection: $messageDisplayMode) {
                    Text("Inline").tag(MessageDisplayMode.inline)
                    Text("Full raw").tag(MessageDisplayMode.fullRaw)
                }
            } header: {
                Text("Display")
            } footer: {
                Text("Full raw shows prompts and commands verbatim — monospaced, unrendered, never truncated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            }

            if FileManager.default.fileExists(atPath: "/Applications/cmux.app") {
                Section {
                    HStack {
                        Text("Socket Control Mode")
                        Spacer()
                        Text("Automation mode")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("cmux")
                } footer: {
                    Text("To send messages from Ghostwire to cmux sessions, set Socket Control Mode to \"Automation mode\" in cmux Settings > Automation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            selectedSound = GhostwireSettings.notificationSound
        }
    }
}

/// One agent's hook row: identity dot + name, then install state.
/// Codex additionally shows the CLI-trust row (status detection = GW-196).
private struct AgentHooksRow: View {
    let agent: AgentHookConfig

    @State private var detected = false
    @State private var installed = false

    var body: some View {
        HStack {
            Circle()
                .fill(AgentIdentity.tint(for: agent.id))
                .frame(width: 8, height: 8)
            Text(agent.displayName)
            Spacer()
            if !detected {
                Text("Not detected")
                    .foregroundStyle(.secondary)
            } else if installed {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Installed")
                        .foregroundStyle(.secondary)
                }
                Button("Uninstall") {
                    agent.uninstall()
                    Defaults[agent.enabledKey] = false
                    refresh()
                }
            } else {
                Button("Install") {
                    Defaults[agent.enabledKey] = true
                    agent.install()
                    refresh()
                }
            }
        }
        .onAppear { refresh() }

        if agent.requiresCLITrust && detected && installed {
            HStack {
                Text("Hook trust")
                Spacer()
                Text("Check with /hooks in \(agent.displayName)")
                    .foregroundStyle(.secondary)
            }
            .opacity(0.4)
            .help("\(agent.displayName) requires one-time hook trust via /hooks in the CLI. Status detection is coming.")
        }
    }

    private func refresh() {
        detected = agent.isDetected()
        installed = agent.isInstalled()
    }
}
