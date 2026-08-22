//
//  MCPSettingsView.swift
//  Ghostwire
//
//  GW-219 shipped this debug-grade ("the full settings redesign comes later").
//  GW-255 is that redesign, and the first consumer of the GW-356 §8 vocabulary.
//
//  GW-449 then replaced its ROOT with a connector catalog grid
//  (`ConnectionsCatalogView`), so point 1 below no longer holds: this pane is
//  deliberately not a `Form` any more. What survives is the drill-in contract.
//
//  Three structural changes:
//
//  1. ~~It's a `Form` now.~~ SUPERSEDED by GW-449 — the root is a card grid.
//     The drill-in below is still a `Form`, and every other Settings pane
//     still is one; this pane is the single documented exception.
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

/// The pane's own navigation + sheet state, hoisted out of the view because the
/// "Add Server" control now lives in the settings PANE HEADER, which the window
/// owns (it used to be a `.toolbar` item, which macOS rendered up in the
/// transparent titlebar beside the traffic lights — one slot that changed hands
/// pane to pane). The header and the pane read the same object, so there is
/// still exactly one source of truth for "is a sheet up" and "am I drilled in".
@MainActor
final class MCPPaneModel: ObservableObject {
    @Published var showingAddSheet = false
    @Published var showingImportSheet = false
    @Published var openServerID: UUID?

    /// Whether there's a Claude Code config to read at all. Checked once per
    /// appearance rather than per redraw — this is a stat() in a view body.
    @Published var canImport = false

    /// The drill-in target, resolved fresh each read: a server removed from
    /// under us must fall back to the list rather than render an empty pane.
    var openServer: MCPServerConfig? {
        openServerID.flatMap { MCPClientService.shared.store.server(id: $0) }
    }
}

struct MCPSettingsView: View {
    @ObservedObject private var service = MCPClientService.shared
    @ObservedObject var model: MCPPaneModel

    private var openServer: MCPServerConfig? {
        model.openServerID.flatMap { service.store.server(id: $0) }
    }

    var body: some View {
        Group {
            if let openServer {
                detail(for: openServer)
            } else {
                root
            }
        }
        .onAppear { model.canImport = AgentMCPConfigImporter.claudeCodeConfigExists }
        // The open server can be deleted out from under the drill-in. `openServer`
        // already falls back to the list, but the id has to be cleared too or the
        // header's Add control stays disabled over a list it should be usable on.
        .onChange(of: openServer == nil) { _, isList in
            if isList { model.openServerID = nil }
        }
        .sheet(isPresented: $model.showingAddSheet) { MCPAddServerSheet() }
        .sheet(isPresented: $model.showingImportSheet) { MCPImportSheet() }
    }

    // MARK: - Root

    /// GW-449: the root is a card GRID now, not a `Form`. The grouped list of
    /// servers-you-already-added answered the wrong question — it could only
    /// show you what you'd already found somewhere else.
    @ViewBuilder private var root: some View {
        ConnectionsCatalogView(model: model)
    }

    // MARK: - Drill-in

    /// The back control lives in `WindowPaneHeader` now (GW-449), which also
    /// carries the server's name and tool count — so the drill-in is just the
    /// server's content.
    private func detail(for server: MCPServerConfig) -> some View {
        MCPServerDetailView(serverID: server.id, onRemoved: { model.openServerID = nil })
            // These used to live on the whole pane in `GhostwireWindowView`,
            // where they styled the root Form AND this drill-in. GW-449 removed
            // them along with the root Form, which silently took the drill-in's
            // styling with it — it started painting its own opaque background
            // over the black pane. They belong to the Form, so they live here.
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.black)
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
