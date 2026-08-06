//
//  MCPSettingsView.swift
//  Ghostwire
//
//  GW-219 shipped this debug-grade ("the full settings redesign comes later").
//  GW-255 is that redesign, and the first consumer of the GW-356 §8 vocabulary.
//
//  Three structural changes:
//
//  1. It's a `Form` now. Every other detail pane is one; this was a bare `List`
//     and inherited none of the grouped styling the rest of Settings shares
//     (§8 "The frame").
//  2. The server detail is a DRILL-IN, not a sheet (§8.6) — every control in it
//     writes through immediately, so there was never anything for Cancel to
//     mean. The Settings shell is a `NavigationSplitView` switching on a
//     sidebar string, so there is no navigation bar to come back through; the
//     pane supplies its own back control instead.
//  3. The gateway gets a real section, at the top, because what it exposes is
//     the list underneath it.
//
//  GW-332 Phase 1 stands: import is the top of the funnel, manual add is the
//  escape hatch. Most people running Ghostwire already have MCP servers
//  configured for Claude Code.
//

import SwiftUI

struct MCPSettingsView: View {
    @ObservedObject private var service = MCPClientService.shared
    @State private var showingAddSheet = false
    @State private var showingImportSheet = false
    @State private var openServerID: UUID?

    /// Whether there's a Claude Code config to read at all. Checked once per
    /// appearance rather than per redraw — this is a stat() in a view body.
    @State private var canImport = false

    /// The drill-in target, resolved fresh each render: a server removed from
    /// under us must fall back to the list rather than render an empty pane.
    private var openServer: MCPServerConfig? {
        openServerID.flatMap { service.store.server(id: $0) }
    }

    var body: some View {
        Group {
            if let openServer {
                detail(for: openServer)
            } else {
                root
            }
        }
        .onAppear { canImport = AgentMCPConfigImporter.claudeCodeConfigExists }
        .toolbar {
            ToolbarItem {
                // A plain menu, NOT `Menu(primaryAction:)`. The split-button
                // form listed "Import…" twice — once as the + click, once
                // inside its own chevron menu — so the two halves looked like
                // two different commands that happened to do the same thing.
                Menu {
                    Button("Import Servers…") { showingImportSheet = true }
                        .disabled(!canImport)
                    Button("Add Manually…") { showingAddSheet = true }
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                // Adding a server from inside one server's page is incoherent —
                // the drill-in is a place, not a list.
                .disabled(openServer != nil)
            }
        }
        .sheet(isPresented: $showingAddSheet) { MCPAddServerSheet() }
        .sheet(isPresented: $showingImportSheet) { MCPImportSheet() }
    }

    // MARK: - Root

    @ViewBuilder private var root: some View {
        Form {
            GatewaySection()

            Section {
                if service.store.servers.isEmpty {
                    emptyState
                } else {
                    ForEach(service.store.servers) { server in
                        MCPServerRow(server: server, runtime: service.runtime(id: server.id))
                            .contentShape(Rectangle())
                            // §8.2: the whole row taps ONLY because the tap
                            // drills in. It carries no control of its own.
                            .onTapGesture { openServerID = server.id }
                    }
                }
            } header: {
                Text("Servers")
            } footer: {
                if !service.store.servers.isEmpty {
                    Text(
                        "Local servers run a program on this Mac. Hosted servers are reached "
                        + "over the network. Open one to choose which of its tools Ghostwire may call."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .leadingFooter()
                }
            }
        }
        .formStyle(.grouped)
    }

    /// §8.3 / GW-367: state the section's JOB, not its emptiness.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "server.rack")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Connect MCP servers to glance at — kept out of your agents' context.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if canImport {
                Text("You already have servers configured for Claude Code.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button("Import Servers…") { showingImportSheet = true }
                    .buttonStyle(.borderedProminent)
                Button("Add manually…") { showingAddSheet = true }
                    .buttonStyle(.link)
            } else {
                Button("Add manually…") { showingAddSheet = true }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Drill-in

    private func detail(for server: MCPServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The back affordance the Settings shell can't provide. Kept
            // outside the Form so it reads as navigation chrome rather than a
            // row you could mistake for a setting.
            Button {
                openServerID = nil
            } label: {
                Label("Servers", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
            }
            .buttonStyle(.link)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 2)
            .accessibilityLabel("Back to servers")
            .keyboardShortcut("[", modifiers: .command)

            MCPServerDetailView(serverID: server.id, onRemoved: { openServerID = nil })
        }
    }
}

// MARK: - Server row

struct MCPServerRow: View {
    let server: MCPServerConfig
    let runtime: MCPServerRuntime?

    private var severity: SettingsStateSeverity { runtime?.status.severity ?? .inert }

    var body: some View {
        HStack(spacing: 8) {
            if runtime?.status == .connecting {
                ProgressView().controlSize(.small).frame(width: 8, height: 8)
            } else {
                SettingsStateDot(severity: severity, caption: statusCaption ?? "Connected")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                // §8.4: every non-default state gets WORDS, not just a dot
                // colour. Before this, a freshly imported stdio server showed
                // an unlabelled grey dot and read as "the import didn't work".
                if let caption = statusCaption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(severity.color)
                        .lineLimit(1)
                }
            }
            Spacer()
            // The allowed count, not the tool count: a connected server with an
            // empty allowlist can't be called, and "41 tools" implied otherwise.
            if case .connected(let count) = runtime?.status {
                Text("\(server.allowedTools.count) of \(count) allowed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            MCPTransportBadge(transport: server.transport)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    /// nil for the two states that need no explanation: connected (the count
    /// already says so) and never-touched.
    private var statusCaption: String? {
        switch runtime?.status {
        case .failed(let reason): return reason
        case .needsTrust: return "Not trusted — open to review the command"
        case .needsAuth: return "Needs authorization"
        case .connecting: return "Connecting…"
        case .connected, .disconnected, nil: return nil
        }
    }
}

// MARK: - Add sheet

struct MCPAddServerSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Tuples can't back SwiftUI bindings (no key paths to tuple elements) — use a tiny struct.
    private struct EnvRow: Identifiable {
        let id = UUID()
        var key = ""
        var value = ""
    }

    /// GW-291/292: how a hosted (.http) server authenticates.
    private enum HTTPAuthMode: String, CaseIterable, Identifiable {
        case auto = "Automatic"
        case apiKey = "API key / token"
        case oauth = "OAuth app"
        var id: String { rawValue }
    }
    @State private var name = ""
    @State private var input = ""  // URL or command line — transport auto-detected
    @State private var envRows: [EnvRow] = []
    @State private var errorMessage: String?
    @State private var isConnecting = false

    // GW-291/292 auth fields (only used for the .http transport).
    @State private var authMode: HTTPAuthMode = .auto
    @State private var customHeaderName = ""
    @State private var apiKeyToken = ""
    @State private var oauthClientID = ""
    @State private var oauthClientSecret = ""
    @State private var oauthPort = ""
    @State private var oauthPath = ""

    private var detectedTransport: MCPTransportKind { detectMCPTransportKind(from: input) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add MCP Server").font(.headline)
            TextField("Name", text: $name)
            TextField("Hosted URL or command (e.g. npx -y @example/server)", text: $input)
                .font(.body.monospaced())
            if detectedTransport == .stdio && !input.isEmpty {
                envSection
                Label(
                    "This runs a program on your Mac. Only add commands you trust.",
                    systemImage: "exclamationmark.shield"
                )
                .font(.caption).foregroundStyle(SettingsStateColors.attention)
            }
            if detectedTransport == .http && !input.isEmpty {
                httpAuthSection
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(SettingsStateColors.error)
            }
            HStack {
                Spacer()
                // §8.1: `.cancelAction` ALWAYS set explicitly. Without it Esc
                // behaved differently in this sheet than in the other two.
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(detectedTransport == .stdio ? "Trust & Connect" : "Connect") {
                    Task { await addAndConnect() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || input.isEmpty || isConnecting)
            }
        }
        .padding(20)
        // §8.1 rung S: one decision, few fields, no list. Was 440 — one of the
        // three independent guesses the ladder replaced.
        .frame(width: 420)
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

    private var httpAuthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Authentication", selection: $authMode) {
                ForEach(HTTPAuthMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch authMode {
            case .auto:
                Text("Signs in automatically (dynamic registration). Works for servers that support it.")
                    .font(.caption).foregroundStyle(.secondary)
            case .apiKey:
                SecureField("API key / token (stored in Keychain)", text: $apiKeyToken)
                    .font(.caption.monospaced())
                DisclosureGroup("Advanced") {
                    TextField("Custom header name (default: Authorization: Bearer)",
                              text: $customHeaderName)
                        .font(.caption.monospaced())
                }
                .font(.caption)
            case .oauth:
                TextField("Client ID", text: $oauthClientID).font(.caption.monospaced())
                SecureField("Client secret — optional (stored in Keychain)", text: $oauthClientSecret)
                    .font(.caption.monospaced())
                DisclosureGroup("Advanced — pinned callback") {
                    HStack {
                        TextField("Loopback port (optional)", text: $oauthPort)
                            .font(.caption.monospaced()).frame(width: 160)
                        TextField("Callback path (default /callback)", text: $oauthPath)
                            .font(.caption.monospaced())
                    }
                    if let port = UInt16(oauthPort.trimmingCharacters(in: .whitespaces)) {
                        let path = MCPOAuthCoordinator.normalizedLoopbackPath(oauthPath)
                        Text("Register this callback: http://127.0.0.1:\(port)\(path)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .font(.caption)
            }
        }
    }

    @MainActor
    private func addAndConnect() async {
        isConnecting = true
        defer { isConnecting = false }
        errorMessage = nil

        var config: MCPServerConfig
        if detectedTransport == .http {
            guard let url = URL(string: input.trimmingCharacters(in: .whitespaces)) else {
                errorMessage = "Invalid URL."
                return
            }
            config = MCPServerConfig(id: UUID(), name: name, transport: .http(endpoint: url))
            switch authMode {
            case .auto:
                break  // httpAuth stays nil → dynamic client registration
            case .apiKey:
                let token = apiKeyToken.trimmingCharacters(in: .whitespaces)
                guard !token.isEmpty else {
                    errorMessage = "Enter the API key / token."
                    return
                }
                // Blank custom header (the default) → Authorization: Bearer.
                let header = customHeaderName.trimmingCharacters(in: .whitespaces)
                config.httpAuth = header.isEmpty ? .bearer : .header(name: header)
                KeychainMCPSecretStore.shared.setString(
                    token, account: MCPSecretAccount.httpAuthToken(serverID: config.id))
            case .oauth:
                let clientID = oauthClientID.trimmingCharacters(in: .whitespaces)
                guard !clientID.isEmpty else {
                    errorMessage = "Enter the OAuth client ID."
                    return
                }
                let portText = oauthPort.trimmingCharacters(in: .whitespaces)
                let port: UInt16?
                if portText.isEmpty {
                    port = nil
                } else if let parsed = UInt16(portText) {
                    port = parsed
                } else {
                    errorMessage = "Loopback port must be a number (1–65535)."
                    return
                }
                let path = oauthPath.trimmingCharacters(in: .whitespaces)
                config.httpAuth = .oauthClient(
                    clientID: clientID, loopbackPort: port,
                    loopbackPath: path.isEmpty ? nil : path)
                let secret = oauthClientSecret.trimmingCharacters(in: .whitespaces)
                if !secret.isEmpty {
                    KeychainMCPSecretStore.shared.setString(
                        secret, account: MCPSecretAccount.oauthClientSecret(serverID: config.id))
                }
            }
        } else {
            let trimmedCommand = input.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmedCommand.split(separator: " ").map(String.init)
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
