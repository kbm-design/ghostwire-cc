//
//  MCPSettingsView.swift
//  Ghostwire
//
//  GW-219 deliverable surface (debug-grade, simple first pass — the full
//  settings redesign comes later). List + manual add. No catalog:
//  bring-your-own/paste is the model.
//

import SwiftUI

struct MCPSettingsView: View {
    @ObservedObject private var service = MCPClientService.shared
    @State private var showingAddSheet = false
    @State private var selectedServer: IdentifiableUUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if service.store.servers.isEmpty {
                emptyState
            } else {
                serverList
            }
        }
        .toolbar {
            ToolbarItem {
                Button { showingAddSheet = true } label: {
                    Label("Add Server", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            MCPAddServerSheet()
        }
        .sheet(item: $selectedServer) { wrapped in
            MCPServerDetailView(serverID: wrapped.id)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "server.rack")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Connect MCP servers to glance at — kept out of your agents' context.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add manually…") { showingAddSheet = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var serverList: some View {
        List {
            ForEach(service.store.servers) { server in
                MCPServerRow(server: server, runtime: service.runtime(id: server.id))
                    .contentShape(Rectangle())
                    .onTapGesture { selectedServer = IdentifiableUUID(id: server.id) }
            }
        }
    }
}

private struct IdentifiableUUID: Identifiable {
    let id: UUID
}

struct MCPServerRow: View {
    let server: MCPServerConfig
    let runtime: MCPServerRuntime?

    var body: some View {
        HStack(spacing: 8) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                if case .failed(let reason) = runtime?.status {
                    Text(reason).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
            }
            Spacer()
            if case .connected(let count) = runtime?.status {
                Text("\(count) tools").font(.caption).foregroundStyle(.secondary)
            }
            Text(server.transport.displayBadge)
                .font(.caption2.monospaced())
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
        }
        .padding(.vertical, 2)
    }

    private var statusDot: some View {
        Circle().frame(width: 8, height: 8).foregroundStyle(statusColor)
    }

    private var statusColor: Color {
        switch runtime?.status {
        case .connected: return .green
        case .connecting: return .yellow
        case .needsAuth, .needsTrust: return .orange
        case .failed: return .red
        case .disconnected, nil: return .gray
        }
    }
}

struct MCPAddServerSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Tuples can't back SwiftUI bindings (no key paths to tuple elements) — use a tiny struct.
    private struct EnvRow: Identifiable {
        let id = UUID()
        var key = ""
        var value = ""
    }

    @State private var name = ""
    @State private var input = ""  // URL or command line — transport auto-detected
    @State private var envRows: [EnvRow] = []
    @State private var errorMessage: String?
    @State private var isConnecting = false

    private var detectedTransport: String {
        input.hasPrefix("http://") || input.hasPrefix("https://") ? "http" : "stdio"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add MCP Server").font(.headline)
            TextField("Name", text: $name)
            TextField("Hosted URL or command (e.g. npx -y @example/server)", text: $input)
                .font(.body.monospaced())
            if detectedTransport == "stdio" && !input.isEmpty {
                envSection
                Label(
                    "This runs a program on your Mac. Only add commands you trust.",
                    systemImage: "exclamationmark.shield"
                )
                .font(.caption).foregroundStyle(.orange)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(detectedTransport == "stdio" ? "Trust & Connect" : "Connect") {
                    Task { await addAndConnect() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || input.isEmpty || isConnecting)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var envSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach($envRows) { $row in
                HStack {
                    TextField("ENV_KEY", text: $row.key).font(.caption.monospaced())
                    SecureField("value (stored in Keychain)", text: $row.value)
                        .font(.caption.monospaced())
                    Button {
                        envRows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Remove variable")
                }
            }
            Button {
                envRows.append(EnvRow())
            } label: {
                Label("Add environment variable", systemImage: "plus.circle").font(.caption)
            }
            .buttonStyle(.plain)
        }
    }

    @MainActor
    private func addAndConnect() async {
        isConnecting = true
        defer { isConnecting = false }
        errorMessage = nil

        var config: MCPServerConfig
        if detectedTransport == "http" {
            guard let url = URL(string: input.trimmingCharacters(in: .whitespaces)) else {
                errorMessage = "Invalid URL."
                return
            }
            config = MCPServerConfig(id: UUID(), name: name, transport: .http(endpoint: url))
        } else {
            let parts = input.split(separator: " ").map(String.init)
            guard let command = parts.first else { return }
            let arguments = Array(parts.dropFirst())
            let keys = envRows.map(\.key).filter { !$0.isEmpty }
            config = MCPServerConfig(
                id: UUID(), name: name,
                transport: .stdio(command: command, arguments: arguments, environmentKeys: keys)
            )
            // Resolve absolute path NOW (add-time) — surface failure immediately.
            if let resolved = await LoginShellPATHResolver.shared.resolve(command: command) {
                config.resolvedExecutablePath = resolved
            } else {
                errorMessage = "“\(command)” not found on your shell's PATH. Is it installed?"
                return
            }
            // Env values -> Keychain only.
            for row in envRows where !row.key.isEmpty {
                KeychainMCPSecretStore.shared.setString(
                    row.value,
                    account: MCPSecretAccount.env(serverID: config.id, key: row.key)
                )
            }
            // The button said "Trust & Connect" — record the trusted signature.
            config.trustedCommandSignature = config.commandSignature
        }

        MCPClientService.shared.addServer(config)
        await MCPClientService.shared.connectInteractively(id: config.id)
        dismiss()
    }
}
