//
//  GatewayHTTPService.swift
//  Ghostwire
//
//  GW-253 Phase 2: owns the localhost gateway HTTP server lifecycle. Runs
//  in-process (so the per-session server reaches the app's live authed
//  connections via MCPClientServiceUpstreamSource). Holds the per-launch
//  bearer token + the endpoint URL the agent registers against.
//
//  v1 is started/stopped explicitly (debug toggle). Auto-start-on-launch behind
//  a Default is a follow-up once the UX lands.
//

import Defaults
import Foundation

@MainActor
final class GatewayHTTPService {
    static let shared = GatewayHTTPService()

    /// Auto-start at app launch. Runs only when the user actually has MCP
    /// servers configured (nothing to expose otherwise) and the kill-switch is
    /// on. Skipped under tests (no run loop; a bound port would leak).
    static func startIfEnabled() {
        guard NSClassFromString("XCTestCase") == nil else { return }
        guard Defaults[.mcpGatewayEnabled] else { return }  // kill-switch (default on)
        guard !MCPClientService.shared.store.servers.isEmpty else { return }  // nothing to expose
        Task { await shared.start() }
    }

    let auth = GatewayAuth.persistent()
    private let config = GatewayHTTPListener.Configuration()
    private var listener: GatewayHTTPListener?
    private(set) var isRunning = false

    var token: String { auth.token }
    var endpointURL: String { "http://\(config.host):\(config.port)\(config.endpoint)" }

    private init() {}

    func start() async {
        guard listener == nil else { return }
        // Capture the live service + a Sendable source on the MainActor; the
        // per-session factory runs off-MainActor and hops back via the source.
        let source = MCPClientServiceUpstreamSource(service: MCPClientService.shared)
        let auth = self.auth
        let listener = GatewayHTTPListener(
            configuration: config,
            gate: { auth.gate($0) },
            serverFactory: { _, _ in await GatewayServer.makeServer(source: source) }
        )
        do {
            try await listener.start()
            self.listener = listener
            isRunning = true
        } catch {
            isRunning = false
            GatewayHTTPListener.log.error("gateway start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() async {
        await listener?.stop()
        listener = nil
        isRunning = false
    }
}
