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
                            }
                        )
                    )
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
            }
            .frame(minHeight: 140)
        }
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
            let output = try await service.callAllowedTool(
                serverID: serverID, name: tool, arguments: nil)
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
