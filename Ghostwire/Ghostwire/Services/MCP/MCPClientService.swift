//
//  MCPClientService.swift
//  Ghostwire
//
//  GW-219: the facade and the SINGLE security choke point for outbound MCP
//  tool calls. Everything (Settings debug Run, GW-214's feed) goes through
//  callAllowedTool — default-deny against the persisted per-tool allowlist.
//  Also owns connect/refresh supervision and sleep/wake revalidation.
//

import AppKit
import Combine
import Foundation
import MCP

/// Seam so tests can fake the protocol layer.
protocol MCPConnecting: AnyObject {
    func listTools() async throws -> [MCPToolInfo]
    func listFullTools() async throws -> [Tool]
    func callTool(name: String, arguments: [String: Value]?) async throws -> MCPToolCallOutput
    func ping() async throws
    func disconnect() async
}

extension MCPConnection: MCPConnecting {}

/// Per-server live state for the UI (config stays in the store).
struct MCPServerRuntime {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected(toolCount: Int)
        case needsTrust
        case needsAuth
        case failed(reason: String)
    }

    var status: Status = .disconnected
    var tools: [MCPToolInfo] = []
}

@MainActor
final class MCPClientService: ObservableObject {
    static let shared = MCPClientService()

    enum ServiceError: LocalizedError, Equatable {
        case serverNotFound
        case toolNotAllowed(String)
        case notConnected

        var errorDescription: String? {
            switch self {
            case .serverNotFound: return "Unknown MCP server."
            case .toolNotAllowed(let name):
                return "Tool “\(name)” is not in this server's allowlist."
            case .notConnected: return "Server is not connected."
            }
        }
    }

    let store: MCPServerConfigStore
    private let secretStore: MCPSecretStore
    /// Returns the live connection for a config. Injectable for tests; the
    /// default builds an MCPConnection (establish() performs the real connect).
    private let connectionFactory: (MCPServerConfig) -> MCPConnecting

    @Published private(set) var runtimes: [UUID: MCPServerRuntime] = [:]

    /// GW-214: fires when a config change alters which feed Sources should
    /// exist or what they'd call. `FeedSourceCoordinator` subscribes so it
    /// rebuilds itself; without this, a removed server leaves an orphan poll
    /// loop publishing a "Not connected" card for a server that's gone.
    ///
    /// Deliberately NOT `objectWillChange` or a store-wide observer: `runtimes`
    /// churns on every status change and `store.update` is also called by
    /// `recordProbe`/`recordRun` telemetry on every connect and every tool
    /// call. Either would restart the coordinator in a loop. This fires only
    /// from the explicit config mutations that actually change the source list
    /// (add / remove / allow / bind / arguments / trust).
    let feedConfigDidChange = PassthroughSubject<Void, Never>()
    private var connections: [UUID: MCPConnecting] = [:]
    private var healthPolicies: [UUID: ConnectionHealthPolicy] = [:]
    private var wakeObserver: NSObjectProtocol?

    init(
        store: MCPServerConfigStore = MCPServerConfigStore(),
        secretStore: MCPSecretStore = KeychainMCPSecretStore.shared,
        connectionFactory: ((MCPServerConfig) -> MCPConnecting)? = nil
    ) {
        self.store = store
        self.secretStore = secretStore
        self.connectionFactory = connectionFactory ?? { MCPConnection(serverName: $0.name) }
        observeWake()
    }

    func runtime(id: UUID) -> MCPServerRuntime? { runtimes[id] }

    // MARK: - Config mutations

    func addServer(_ config: MCPServerConfig) {
        store.add(config)
        runtimes[config.id] = MCPServerRuntime()
        feedConfigDidChange.send()
    }

    func removeServer(id: UUID) {
        if let config = store.server(id: id),
            case .stdio(_, _, let keys) = config.transport {
            secretStore.deleteAll(serverID: id, environmentKeys: keys)
        } else {
            secretStore.deleteAll(serverID: id, environmentKeys: [])
        }
        let connection = connections.removeValue(forKey: id)
        Task { await connection?.disconnect() }
        store.remove(id: id)
        runtimes[id] = nil
        healthPolicies[id] = nil
        // Or the coordinator keeps polling a server that no longer exists.
        feedConfigDidChange.send()
    }

    func setToolAllowed(serverID: UUID, tool: String, allowed: Bool) {
        guard var config = store.server(id: serverID) else { return }
        if allowed {
            config.allowedTools.insert(tool)
        } else {
            config.allowedTools.remove(tool)
            // Disallowing implies unbinding (GW-214): a binding left behind would
            // sit in Settings looking active while failing closed on every poll.
            config.feedTools?.removeAll { $0.tool == tool }
        }
        store.update(config)
        objectWillChange.send()
        feedConfigDidChange.send()
    }

    /// GW-214: bind/unbind a tool as an ambient feed card. Independent of the
    /// allowlist — binding never grants a call, it only schedules one that the
    /// allowlist has already permitted.
    func setFeedTool(serverID: UUID, tool: String, bound: Bool) {
        guard var config = store.server(id: serverID) else { return }
        var bindings = config.feedTools ?? []
        bindings.removeAll { $0.tool == tool }
        if bound {
            // Pre-fill the required-parameter shape so a tool that needs input
            // shows the user what's missing instead of returning a -32602 they
            // have to decode. Feed candidates require nothing and get `{}`.
            let required = runtimes[serverID]?.tools.first { $0.name == tool }?.requiredInputs ?? []
            bindings.append(
                MCPFeedToolBinding(tool: tool, argumentsJSON: Self.argumentTemplate(for: required)))
        }
        config.feedTools = bindings
        store.update(config)
        objectWillChange.send()
        feedConfigDidChange.send()
    }

    /// `{}` when nothing is required; otherwise the empty shape of what is.
    /// Pure string work — nonisolated so it's callable (and testable) off the
    /// main actor.
    nonisolated static func argumentTemplate(for requiredInputs: [String]) -> String {
        guard !requiredInputs.isEmpty else { return "{}" }
        return "{" + requiredInputs.map { "\"\($0)\": \"\"" }.joined(separator: ", ") + "}"
    }

    /// Edit a binding's call arguments (Settings). No-op for an unbound tool.
    func setFeedToolArguments(serverID: UUID, tool: String, argumentsJSON: String) {
        guard var config = store.server(id: serverID),
            var bindings = config.feedTools,
            let index = bindings.firstIndex(where: { $0.tool == tool })
        else { return }
        bindings[index].argumentsJSON = argumentsJSON
        config.feedTools = bindings
        store.update(config)
        objectWillChange.send()
        feedConfigDidChange.send()
    }

    /// User explicitly trusted the current command line (Add sheet / detail view).
    func trustCurrentCommand(serverID: UUID) {
        guard var config = store.server(id: serverID) else { return }
        config.trustedCommandSignature = config.commandSignature
        store.update(config)
        objectWillChange.send()
        feedConfigDidChange.send()
    }

    // MARK: - Lifecycle

    /// User-initiated connect (Settings buttons): allows the OAuth browser.
    func connectInteractively(id: UUID) async {
        MCPOAuthCoordinator.shared.beginInteractiveGrant()
        defer { MCPOAuthCoordinator.shared.endInteractiveGrant() }
        await connect(id: id)
    }

    func connect(id: UUID) async {
        guard let config = store.server(id: id) else { return }
        // Tear down any live connection first — a second Test/Authorize must
        // not orphan the previously spawned stdio process (Codex review P2).
        if connections[id] != nil {
            await disconnect(id: id)
        }
        guard config.isTrusted else {
            runtimes[id, default: MCPServerRuntime()].status = .needsTrust
            return
        }
        runtimes[id, default: MCPServerRuntime()].status = .connecting

        let connection = connectionFactory(config)
        do {
            if let real = connection as? MCPConnection {
                try await establish(real, config: config)
            }
            connections[id] = connection
            let tools = try await connection.listTools()
            runtimes[id]?.tools = tools
            runtimes[id]?.status = .connected(toolCount: tools.count)
            recordProbe(config: config, tools: tools)
            healthPolicies[id]?.recordSuccess()
        } catch {
            await connection.disconnect()
            connections[id] = nil
            runtimes[id]?.status = Self.isAuthError(error)
                ? .needsAuth
                : .failed(reason: error.localizedDescription)
        }
    }

    func disconnect(id: UUID) async {
        let connection = connections.removeValue(forKey: id)
        await connection?.disconnect()
        runtimes[id]?.status = .disconnected
        runtimes[id]?.tools = []
    }

    /// Test/refresh button + GW-214's poll entry point.
    func refresh(id: UUID) async {
        guard let connection = connections[id] else {
            await connect(id: id)
            return
        }
        do {
            let tools = try await connection.listTools()
            runtimes[id]?.tools = tools
            runtimes[id]?.status = .connected(toolCount: tools.count)
            if let config = store.server(id: id) { recordProbe(config: config, tools: tools) }
            healthPolicies[id]?.recordSuccess()
        } catch {
            await handleFailure(id: id, error: error)
        }
    }

    // MARK: - THE allowlist choke point

    func callAllowedTool(serverID: UUID, name: String, arguments: [String: Value]?) async throws
        -> MCPToolCallOutput {
        guard let config = store.server(id: serverID) else { throw ServiceError.serverNotFound }
        guard config.allowedTools.contains(name) else { throw ServiceError.toolNotAllowed(name) }
        guard let connection = connections[serverID] else { throw ServiceError.notConnected }
        do {
            let output = try await connection.callTool(name: name, arguments: arguments)
            healthPolicies[serverID]?.recordSuccess()
            recordRun(config: config, tool: name, output: output)
            return output
        } catch {
            await handleFailure(id: serverID, error: error)
            throw error
        }
    }

    // MARK: - GW-253 gateway source

    /// Build the gateway's upstream list: one entry per CONNECTED server,
    /// carrying its allowlisted full `Tool`s (with schemas). Live-fetches per
    /// call for now — caching at connect-time is a Phase-2 refinement.
    func gatewayServers() async -> [GatewayUpstreamServer] {
        var result: [GatewayUpstreamServer] = []
        for config in store.servers {
            guard let connection = connections[config.id] else { continue }
            let full = (try? await connection.listFullTools()) ?? []
            let allowed = full.filter { config.allowedTools.contains($0.name) }
            guard !allowed.isEmpty else { continue }
            result.append(
                GatewayUpstreamServer(id: config.id, displayName: config.name, tools: allowed))
        }
        return result
    }

    // MARK: - Health / wake supervision

    private func handleFailure(id: UUID, error: Error) async {
        var policy = healthPolicies[id, default: ConnectionHealthPolicy()]
        let action = policy.recordFailure()
        healthPolicies[id] = policy
        switch action {
        case .teardownAndReconnect:
            // Never reuse a wounded session — fresh transport + initialize.
            await disconnect(id: id)
            await connect(id: id)
        case .retry, .revalidate:
            runtimes[id]?.status = Self.isAuthError(error)
                ? .needsAuth
                : .failed(reason: error.localizedDescription)
        }
    }

    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.revalidateAll() }
        }
    }

    private func revalidateAll() async {
        for (id, connection) in connections {
            do {
                try await connection.ping()
            } catch {
                // Don't trust an hours-old session after sleep: full teardown.
                await disconnect(id: id)
                await connect(id: id)
            }
        }
    }

    // MARK: - Helpers

    /// Real connect for non-test connections (the factory only constructs).
    private func establish(_ connection: MCPConnection, config: MCPServerConfig) async throws {
        switch config.transport {
        case .http(let endpoint):
            let transport: HTTPClientTransport
            switch config.httpAuth {
            case .some(.bearer), .some(.header):
                // GW-292: static API-key / bearer — stamp the header per request.
                // The token rides in the Keychain, read here and never persisted.
                let token = secretStore.string(
                    account: MCPSecretAccount.httpAuthToken(serverID: config.id))
                transport = HTTPClientTransport(
                    endpoint: endpoint,
                    streaming: true,
                    requestModifier: config.httpAuth?.requestModifier(token: token) ?? { $0 }
                )
            case .some(.oauthClient), .none:
                // GW-291: pre-registered OAuth client, or (nil) the DCR default.
                transport = HTTPClientTransport(
                    endpoint: endpoint,
                    streaming: true,
                    authorizer: MCPOAuthCoordinator.shared.authorizer(
                        for: config, secretStore: secretStore)
                )
            }
            try await connection.connect(transport: transport)
        case .stdio(let command, let arguments, let environmentKeys):
            let resolver = LoginShellPATHResolver.shared
            let path: String
            if let resolved = config.resolvedExecutablePath,
                FileManager.default.isExecutableFile(atPath: resolved) {
                path = resolved
            } else if let reResolved = await resolver.resolve(command: command) {
                path = reResolved
            } else {
                throw StdioServerProcess.SpawnError.notExecutable(command)
            }
            // Secrets: Keychain -> memory -> child env. Never persisted, never logged.
            var environment: [String: String] = [:]
            environment["PATH"] = await resolver.loginShellPATH()
            for key in environmentKeys {
                if let value = secretStore.string(
                    account: MCPSecretAccount.env(serverID: config.id, key: key)) {
                    environment[key] = value
                }
            }
            try await connection.connectStdio(
                executablePath: path, arguments: arguments, environment: environment
            )
        }
    }

    private func recordProbe(config: MCPServerConfig, tools: [MCPToolInfo]) {
        var updated = config
        var probe = updated.lastProbe
            ?? MCPProbeRecord(date: Date(), toolCount: 0, toolsWithOutputSchema: [])
        probe.date = Date()
        probe.toolCount = tools.count
        probe.toolsWithOutputSchema = tools.filter(\.hasOutputSchema).map(\.name).sorted()
        updated.lastProbe = probe
        store.update(updated)
    }

    private func recordRun(config: MCPServerConfig, tool: String, output: MCPToolCallOutput) {
        var updated = config
        var probe = updated.lastProbe
            ?? MCPProbeRecord(date: Date(), toolCount: 0, toolsWithOutputSchema: [])
        probe.lastRunTool = tool
        probe.lastRunReturnedStructuredContent = output.structuredContent != nil
        updated.lastProbe = probe
        store.update(updated)
    }

    private static func isAuthError(_ error: Error) -> Bool {
        if error is MCPAuthInteractionRequired { return true }
        let description = String(describing: error).lowercased()
        return description.contains("unauthorized") || description.contains("401")
            || description.contains("authorization")
    }
}
