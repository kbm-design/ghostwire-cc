//
//  MCPServerDetailView.swift
//  Ghostwire
//
//  GW-219: connection info + per-tool allowlist (default OFF) + debug Run
//  showing raw structuredContent/text. Annotation badges are UI bias only,
//  never a security boundary — the allowlist is enforced in
//  MCPClientService.callAllowedTool.
//

import MCP
import SwiftUI

struct MCPServerDetailView: View {
    let serverID: UUID
    @ObservedObject private var service = MCPClientService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var runOutput: String?
    @State private var runningTool: String?

    private var config: MCPServerConfig? { service.store.server(id: serverID) }
    private var runtime: MCPServerRuntime? { service.runtime(id: serverID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statusSection
            Divider()
            toolsSection
            if let runOutput {
                debugOutput(runOutput)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: 480, height: 520)
    }

    @ViewBuilder private var header: some View {
        if let config {
            HStack {
                Text(config.name).font(.headline)
                Text(config.transport.displayBadge)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                Spacer()
            }
            Text(connectionInfo).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }

    private var connectionInfo: String {
        switch config?.transport {
        case .http(let endpoint): return endpoint.absoluteString
        case .stdio(let command, let arguments, _):
            return ([config?.resolvedExecutablePath ?? command] + arguments)
                .joined(separator: " ")
        case nil: return ""
        }
    }

    @ViewBuilder private var statusSection: some View {
        HStack(spacing: 8) {
            statusLabel
            Spacer()
            switch runtime?.status {
            case .needsAuth:
                Button("Authorize") {
                    Task { await service.connectInteractively(id: serverID) }
                }
            case .needsTrust:
                Button("Trust & Connect") {
                    service.trustCurrentCommand(serverID: serverID)
                    Task { await service.connectInteractively(id: serverID) }
                }
            default:
                Button("Test") {
                    Task { await service.connectInteractively(id: serverID) }
                }
            }
        }
        if case .failed(let reason) = runtime?.status {
            Text(reason)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch runtime?.status {
        case .connected(let count):
            Label("Connected — \(count) tools", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .connecting:
            Label("Connecting…", systemImage: "ellipsis.circle")
        case .needsAuth:
            Label("Needs authorization", systemImage: "key").foregroundStyle(.orange)
        case .needsTrust:
            Label("Not trusted yet", systemImage: "exclamationmark.shield")
                .foregroundStyle(.orange)
        case .failed:
            Label("Error", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .disconnected, nil:
            Label("Disconnected", systemImage: "circle")
        }
    }

    @ViewBuilder private var toolsSection: some View {
        if let runtime, !runtime.tools.isEmpty, let config {
            Text("Tools — allow individually (read-only glances)").font(.subheadline)
            List(runtime.tools) { tool in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(tool.name).font(.body.monospaced())
                                if tool.isReadOnlyHinted == true { badge("read-only", .green) }
                                if tool.isDestructiveHinted == true { badge("destructive", .red) }
                                if tool.hasOutputSchema { badge("schema", .blue) }
                            }
                            if let description = tool.description {
                                Text(description).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        if config.allowedTools.contains(tool.name) {
                            feedToggle(config: config, tool: tool.name)
                            Button(runningTool == tool.name ? "Running…" : "Run") {
                                Task { await run(tool: tool.name) }
                            }
                            .font(.caption)
                            .disabled(runningTool != nil)
                        }
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { config.allowedTools.contains(tool.name) },
                                set: {
                                    service.setToolAllowed(
                                        serverID: serverID, tool: tool.name, allowed: $0)
                                    restartFeed()
                                }
                            )
                        )
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .help("Allow Ghostwire to call this tool")
                    }
                    if let binding = config.feedTools?.first(where: { $0.tool == tool.name }) {
                        feedArgumentsField(binding: binding)
                    }
                }
            }
            .frame(minHeight: 140)
        }
    }

    // MARK: - GW-214: bind a tool as a feed card

    /// A SECOND opt-in on top of the allowlist. Allowing says "you may call
    /// this"; binding says "call it on a timer and show me the answer". Only
    /// offered for already-allowed tools, because the feed goes through
    /// `callAllowedTool` and a binding without the allowlist would fail closed.
    private func feedToggle(config: MCPServerConfig, tool: String) -> some View {
        let isBound = config.feedTools?.contains { $0.tool == tool } ?? false
        return Button {
            service.setFeedTool(serverID: serverID, tool: tool, bound: !isBound)
            restartFeed()
        } label: {
            Image(systemName: isBound ? "square.grid.2x2.fill" : "square.grid.2x2")
                .foregroundStyle(isBound ? Color.effectiveAccent : .secondary)
        }
        .buttonStyle(.plain)
        .help(isBound ? "Showing in the Feed — click to stop" : "Show this tool's result in the Feed")
    }

    /// Arguments for the scheduled call. Most read tools need none, so this
    /// starts at `{}` — an empty object rather than nothing, because strict
    /// servers reject a missing `arguments` field outright.
    private func feedArgumentsField(binding: MCPFeedToolBinding) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Feed arguments").font(.caption2).foregroundStyle(.secondary)
                TextField(
                    "{}",
                    text: Binding(
                        get: { binding.argumentsJSON },
                        set: {
                            service.setFeedToolArguments(
                                serverID: serverID, tool: binding.tool, argumentsJSON: $0)
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .onSubmit { restartFeed() }
            }
            if !binding.hasValidArguments {
                Text("Not a JSON object — the tool will be called with no arguments.")
                    .font(.caption2).foregroundStyle(.orange)
            } else if !binding.argumentsJSON.trimmingCharacters(in: .whitespaces).isEmpty,
                binding.argumentsJSON.trimmingCharacters(in: .whitespaces) != "{}" {
                // These are stored in ~/.ghostwire/mcp-servers.json, which is
                // otherwise guaranteed secret-free (env values and tokens live
                // in the Keychain). Say so rather than let a token land there
                // silently.
                Text("Saved in plain text — put credentials in the server's auth settings, not here.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 4)
    }

    /// Rebuild the Source list now rather than at the next poll, so a binding
    /// shows up in the Feed while the user is still looking at this sheet.
    private func restartFeed() {
        FeedSourceCoordinator.shared.start()
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private func debugOutput(_ output: String) -> some View {
        ScrollView {
            Text(output)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 120)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
    }

    private var footer: some View {
        HStack {
            Button("Remove Server", role: .destructive) {
                service.removeServer(id: serverID)
                dismiss()
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    @MainActor
    private func run(tool: String) async {
        runningTool = tool
        defer { runningTool = nil }
        do {
            // Empty object, not nil: strict servers (zod-validated) reject a
            // missing arguments field with "expected object, received undefined".
            let output = try await service.callAllowedTool(
                serverID: serverID, name: tool, arguments: [:])
            var sections: [String] = []
            if let structured = output.structuredContent {
                sections.append("structuredContent:\n\(structured)")
            }
            if !output.textRepresentation.isEmpty {
                sections.append("text:\n\(output.textRepresentation)")
            }
            runOutput = sections.isEmpty ? "(empty result)" : sections.joined(separator: "\n\n")
        } catch {
            runOutput = "Error: \(error.localizedDescription)"
        }
    }
}
