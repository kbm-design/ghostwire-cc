//
//  GW448LiveConnectorVerificationTests.swift
//  GhostwireTests
//
//  GW-448: measure whether each catalog connector actually COMPLETES from
//  Ghostwire — connect (DCR + loopback OAuth) → tools/list → one real
//  `tools/call` through `callAllowedTool`. "Connected" only proves
//  `initialize` + `tools/list`; a server can list 58 tools and fail every
//  call, so the call is the test.
//
//  This is a LIVE harness, not a unit test. It is skipped unless
//  `GW448_LIVE=1` is in the environment, and it talks to real vendor accounts.
//  It never touches `~/.ghostwire/mcp-servers.json` (own scratch store) but it
//  DOES use the real Keychain, so an OAuth grant survives a re-run.
//
//  Run:
//    TEST_RUNNER_GW448_LIVE=1 TEST_RUNNER_GW448_OUT=/path/results.json \
//      TEST_RUNNER_GW448_ONLY=linear,notion \
//      xcodebuild test -scheme Ghostwire -destination 'platform=macOS' \
//      -only-testing:GhostwireTests/GW448LiveConnectorVerificationTests
//
//  Someone must complete each OAuth consent in the browser while it runs (the
//  coordinator's loopback listener waits 180s per server).
//

import Foundation
import MCP
import XCTest

@testable import Ghostwire

@MainActor
final class GW448LiveConnectorVerificationTests: XCTestCase {

    struct Row: Codable {
        var id: String
        var name: String
        var endpoint: String
        var serverID: String
        var reusedLiveServerID: Bool
        var status: String
        var toolCount: Int
        var zeroInputReadOnlyTools: [String]
        // Optional: older result files must still decode when a field is added.
        var allTools: [String]?
        var tool: String?
        var callSucceeded: Bool?
        var callIsError: Bool?
        var callSample: String?
        var callError: String?
        var connectError: String?
        var connectSeconds: Double
        var measuredAt: String
    }

    func testLiveCatalogConnectors() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["GW448_LIVE"] == "1", "GW-448 live harness; set GW448_LIVE=1")

        let only = Set((env["GW448_ONLY"] ?? "").split(separator: ",").map { String($0) })
        let outURL = URL(fileURLWithPath: env["GW448_OUT"]
            ?? NSTemporaryDirectory().appending("gw448-results.json"))
        let scratchStoreURL = URL(fileURLWithPath: env["GW448_STORE"]
            ?? NSTemporaryDirectory().appending("gw448-mcp-servers.json"))

        // The real store is opened READ-ONLY (it persists only on mutation) so
        // a catalog endpoint Keelan already added reuses its UUID → same
        // loopback port, same Keychain token, no second consent screen.
        let liveStore = MCPServerConfigStore()
        let store = MCPServerConfigStore(fileURL: scratchStoreURL)
        let service = MCPClientService(store: store)
        MCPOAuthCoordinator.shared.authorizationURLObserver = { url in
            print("GW448 AUTH_URL \(url.absoluteString)")
        }
        defer { MCPOAuthCoordinator.shared.authorizationURLObserver = nil }

        var rows = Self.loadRows(outURL)
        let entries = ConnectorCatalog.bundled().filter { only.isEmpty || only.contains($0.id) }
        XCTAssertFalse(entries.isEmpty, "no catalog entries matched GW448_ONLY")

        for entry in entries {
            let liveMatch = liveStore.servers.first { Self.endpoint(of: $0) == entry.endpoint }
            let scratchMatch = store.servers.first { Self.endpoint(of: $0) == entry.endpoint }
            // GW448_FRESH=1 ignores both matches: a new UUID means a new
            // loopback port, which is the only way past a port collision.
            let fresh = env["GW448_FRESH"] == "1"
            let id = fresh ? UUID() : (scratchMatch?.id ?? liveMatch?.id ?? UUID())
            if store.server(id: id) == nil {
                service.addServer(
                    MCPServerConfig(id: id, name: entry.name, transport: .http(endpoint: entry.endpoint)))
            }

            var row = Row(
                id: entry.id, name: entry.name, endpoint: entry.endpoint.absoluteString,
                serverID: id.uuidString, reusedLiveServerID: liveMatch?.id == id,
                status: "", toolCount: 0, zeroInputReadOnlyTools: [], allTools: nil,
                connectSeconds: 0, measuredAt: ISO8601DateFormatter().string(from: Date()))

            print("GW448 ▶ \(entry.name) — connecting (\(entry.endpoint))")
            let started = Date()
            await service.connectInteractively(id: id)
            row.connectSeconds = Date().timeIntervalSince(started)
            let runtime = service.runtime(id: id) ?? MCPServerRuntime()
            row.status = Self.describe(runtime.status)
            row.toolCount = runtime.tools.count
            row.allTools = runtime.tools.map { "\($0.name)(\($0.requiredInputs.joined(separator: ",")))" }

            if case .needsAuth = runtime.status, let config = store.server(id: id) {
                // The service collapses every auth-shaped failure into
                // `.needsAuth`. Re-run the same transport directly to keep the
                // verbatim error — that is the reusable finding GW-448 wants.
                let probe = MCPConnection(serverName: entry.name)
                // GW448_NOSTREAM=1 drops the SSE side-channel: its GET fires
                // after `sseInitializationTimeout` and opens a SECOND OAuth
                // flow on the same loopback port while the human is still on
                // the consent screen (→ "Address already in use").
                let streaming = env["GW448_NOSTREAM"] != "1"
                let transport = HTTPClientTransport(
                    endpoint: entry.endpoint, streaming: streaming,
                    authorizer: MCPOAuthCoordinator.shared.authorizer(for: config))
                MCPOAuthCoordinator.shared.beginInteractiveGrant()
                do {
                    try await probe.connect(transport: transport)
                    let tools = try await probe.listTools()
                    row.status = "connected(\(tools.count)) [direct probe, streaming=\(streaming)]"
                    row.toolCount = tools.count
                    row.allTools = tools.map { "\($0.name)(\($0.requiredInputs.joined(separator: ",")))" }
                    let candidates = tools.filter {
                        $0.requiredInputs.isEmpty
                            && MCPToolClassifier.classify(tool: $0, serverName: entry.name).0 == .readOnly
                    }
                    row.zeroInputReadOnlyTools = candidates.map(\.name)
                    if let tool = candidates.first {
                        row.tool = tool.name
                        let output = try await probe.callTool(name: tool.name, arguments: [:])
                        row.callSucceeded = true
                        row.callIsError = output.isError
                        row.callSample = String(output.textRepresentation.prefix(300))
                    }
                } catch {
                    row.connectError = String(describing: error).prefix(800).description
                }
                MCPOAuthCoordinator.shared.endInteractiveGrant()
                await probe.disconnect()
                print("GW448 ✖ \(entry.name) probe: \(row.status) error=\(row.connectError ?? "-")")
            }

            if case .connected = runtime.status {
                // Same selection rule as the pane's "Test connection", with the
                // allowlist widened to "any tool" so we pick before allowing.
                let candidates = runtime.tools.filter { tool in
                    tool.requiredInputs.isEmpty
                        && MCPToolClassifier.classify(tool: tool, serverName: entry.name).0 == .readOnly
                }
                row.zeroInputReadOnlyTools = candidates.map(\.name)
                if let tool = candidates.first {
                    row.tool = tool.name
                    service.setToolAllowed(serverID: id, tool: tool.name, allowed: true)
                    do {
                        let output = try await service.callAllowedTool(
                            serverID: id, name: tool.name, arguments: [:])
                        row.callSucceeded = true
                        row.callIsError = output.isError
                        row.callSample = String(output.textRepresentation.prefix(300))
                    } catch {
                        row.callSucceeded = false
                        row.callError = String(describing: error).prefix(500).description
                    }
                }
            }
            print("GW448 ◀ \(entry.name): \(row.status) tools=\(row.toolCount) "
                + "tool=\(row.tool ?? "-") ok=\(row.callSucceeded.map(String.init) ?? "-") "
                + "isError=\(row.callIsError.map(String.init) ?? "-")")
            await service.disconnect(id: id)

            rows.removeAll { $0.id == entry.id }
            rows.append(row)
            Self.saveRows(rows, to: outURL)  // per-server, so a hang keeps earlier results
        }
        print("GW448 results → \(outURL.path)")
    }

    // MARK: - Helpers

    private static func endpoint(of config: MCPServerConfig) -> URL? {
        if case .http(let endpoint) = config.transport { return endpoint }
        return nil
    }

    private static func describe(_ status: MCPServerRuntime.Status) -> String {
        switch status {
        case .connected(let n): return "connected(\(n))"
        case .connecting: return "connecting"
        case .disconnected: return "disconnected"
        case .needsAuth: return "needsAuth"
        case .needsTrust: return "needsTrust"
        case .failed(let reason): return "failed: \(reason)"
        }
    }

    private static func loadRows(_ url: URL) -> [Row] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Row].self, from: data)) ?? []
    }

    private static func saveRows(_ rows: [Row], to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(rows).write(to: url, options: .atomic)
    }
}
