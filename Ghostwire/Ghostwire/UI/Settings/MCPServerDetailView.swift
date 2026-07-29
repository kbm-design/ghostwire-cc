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
                toolRow(tool: tool, config: config)
            }
            .frame(minHeight: 140)
        }
    }

    /// One tool. The allow switch is the only control on the title line —
    /// everything else drops to a secondary line that exists only once the tool
    /// is allowed. Crowding four controls onto one line wrapped the monospaced
    /// tool name mid-word and left no room for the name to breathe.
    @ViewBuilder
    private func toolRow(tool: MCPToolInfo, config: MCPServerConfig) -> some View {
        let isAllowed = config.allowedTools.contains(tool.name)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(tool.name).font(.body.monospaced()).lineLimit(1)
                        if tool.isReadOnlyHinted == true { badge("read-only", .green) }
                        if tool.isDestructiveHinted == true { badge("destructive", .red) }
                        if tool.hasOutputSchema { badge("schema", .blue) }
                    }
                    if let description = tool.description {
                        Text(description).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { isAllowed },
                        set: {
                            service.setToolAllowed(
                                serverID: serverID, tool: tool.name, allowed: $0)
                            restartFeed()
                        }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help("Allow Ghostwire to call this tool")
            }

            if isAllowed {
                secondaryLine(tool: tool, config: config)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - GW-214: bind a tool as a feed card

    /// Run + the feed binding. Only reachable once the tool is allowed.
    @ViewBuilder
    private func secondaryLine(tool: MCPToolInfo, config: MCPServerConfig) -> some View {
        let binding = config.feedTools?.first { $0.tool == tool.name }
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Button(runningTool == tool.name ? "Running…" : "Run") {
                    Task { await run(tool: tool.name) }
                }
                .font(.caption)
                .disabled(runningTool != nil)

                if tool.isFeedCandidate {
                    // The good path: no arguments to supply, so binding is one
                    // click and nothing else appears.
                    Toggle(
                        "Show in Feed",
                        isOn: Binding(
                            get: { binding != nil },
                            set: {
                                service.setFeedTool(
                                    serverID: serverID, tool: tool.name, bound: $0)
                                restartFeed()
                            }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .font(.caption)
                } else {
                    // Needs input, so it's a QUESTION, not a standing value.
                    // Reachable, but never the suggested path.
                    needsArgumentsControl(tool: tool, isBound: binding != nil)
                }
                Spacer(minLength: 0)
            }

            if let binding {
                if tool.isFeedCandidate {
                    // Optional parameters, collapsed. The candidacy rule means
                    // the common path needs none — but `list_issues` without
                    // `assignee: me` returns the whole team's work, so scoping
                    // has to be REACHABLE even though it isn't the default.
                    //
                    // A JSON box is a placeholder control, not the answer: the
                    // tool's inputSchema already describes each parameter's type
                    // and enum, so these should be generated native controls.
                    // That's GW-333.
                    DisclosureGroup("Options") {
                        feedArgumentsField(binding: binding, tool: tool)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    feedArgumentsField(binding: binding, tool: tool)
                }
            }
        }
        .padding(.leading, 2)
    }

    /// A tool with required inputs re-asks one frozen question on every poll.
    /// Sometimes that's genuinely what you want (a pinned repo, a fixed
    /// account), so it stays possible — behind a disclosure that says what
    /// you're signing up for rather than an icon that invites it.
    private func needsArgumentsControl(tool: MCPToolInfo, isBound: Bool) -> some View {
        HStack(spacing: 6) {
            Toggle(
                "Show in Feed",
                isOn: Binding(
                    get: { isBound },
                    set: {
                        service.setFeedTool(serverID: serverID, tool: tool.name, bound: $0)
                        restartFeed()
                    }
                )
            )
            .toggleStyle(.checkbox)
            .font(.caption)
            .foregroundStyle(.secondary)

            Image(systemName: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
                .help(
                    "Needs \(tool.requiredInputs.joined(separator: ", ")) — this asks a fixed question on every refresh. Best for a pinned subject, not a search."
                )
        }
    }

    /// Arguments for the scheduled call. Only shown for tools that require
    /// input; a feed candidate never needs it, which is the point.
    private func feedArgumentsField(binding: MCPFeedToolBinding, tool: MCPToolInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Arguments").font(.caption2).foregroundStyle(.secondary)
                TextField(
                    Self.argumentsPlaceholder(for: tool),
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
            } else if !tool.requiredInputs.isEmpty {
                // The empty `{}` default is invalid for this tool by definition,
                // so say what's missing instead of waiting for the server to
                // return a -32602 the user has to decode. Feed candidates
                // require nothing, so they never see this.
                Text("Requires \(tool.requiredInputs.joined(separator: ", ")).")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.leading, 2)
    }

    /// A filled-in shape beats `{}` — the user shouldn't have to infer the
    /// JSON from an error message.
    static func argumentsPlaceholder(for tool: MCPToolInfo) -> String {
        guard !tool.requiredInputs.isEmpty else { return "{}" }
        let pairs = tool.requiredInputs.map { "\"\($0)\": \"\"" }.joined(separator: ", ")
        return "{\(pairs)}"
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
