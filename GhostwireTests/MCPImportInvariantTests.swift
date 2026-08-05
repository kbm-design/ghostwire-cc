import MCP
import XCTest

@testable import Ghostwire

/// GW-332 Phase 1 — the four things an import must never do.
///
/// Each of these is a security posture inherited from GW-219, not a nicety:
/// a regression in any one of them is a silent downgrade, so they're asserted
/// against the bytes on disk rather than against the in-memory model.
@MainActor
final class MCPImportInvariantTests: XCTestCase {
    private var service: MCPClientService!
    private var secrets: InMemoryMCPSecretStore!
    private var tempURL: URL!

    override func setUp() async throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-import-\(UUID().uuidString).json")
        secrets = InMemoryMCPSecretStore()
        service = MCPClientService(
            store: MCPServerConfigStore(fileURL: tempURL),
            secretStore: secrets,
            connectionFactory: { _ in FakeImportConnection() }
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    private func persistedJSON() throws -> String {
        try String(contentsOf: tempURL, encoding: .utf8)
    }

    private func stdioServer(
        name: String = "railway",
        environment: [String: String] = ["RAILWAY_API_TOKEN": "rw_live_SUPERSECRET"]
    ) -> DiscoveredMCPServer {
        DiscoveredMCPServer(
            name: name,
            transport: .stdio(command: "npx", arguments: ["@railway/mcp"]),
            environment: environment,
            httpAuth: nil,
            httpAuthToken: nil,
            scopes: ["Global"],
            blocker: nil,
            signature: AgentMCPConfigImporter.commandSignature(
                command: "npx", arguments: ["@railway/mcp"])
        )
    }

    private func httpServer(token: String? = "hosted_SUPERSECRET") -> DiscoveredMCPServer {
        let endpoint = URL(string: "https://mcp.example.com/mcp")!
        return DiscoveredMCPServer(
            name: "hosted",
            transport: .http(endpoint: endpoint),
            environment: [:],
            httpAuth: token == nil ? nil : .bearer,
            httpAuthToken: token,
            scopes: ["Global"],
            blocker: nil,
            signature: AgentMCPConfigImporter.normalizedEndpointSignature(endpoint)
        )
    }

    // MARK: - 1. No secret reaches mcp-servers.json

    func testImportedEnvValueGoesToKeychainAndNeverToTheConfigFile() async throws {
        let added = await service.importServers([stdioServer()])
        let config = try XCTUnwrap(added.first)

        XCTAssertEqual(
            secrets.string(
                account: MCPSecretAccount.env(serverID: config.id, key: "RAILWAY_API_TOKEN")),
            "rw_live_SUPERSECRET")

        let raw = try persistedJSON()
        XCTAssertFalse(raw.contains("rw_live_SUPERSECRET"))
        XCTAssertTrue(raw.contains("RAILWAY_API_TOKEN"))  // the key NAME is fine
    }

    func testImportedHTTPTokenGoesToKeychainAndNeverToTheConfigFile() async throws {
        let added = await service.importServers([httpServer()])
        let config = try XCTUnwrap(added.first)

        XCTAssertEqual(
            secrets.string(account: MCPSecretAccount.httpAuthToken(serverID: config.id)),
            "hosted_SUPERSECRET")
        XCTAssertFalse(try persistedJSON().contains("hosted_SUPERSECRET"))
    }

    func testEveryImportedSecretIsAbsentFromTheFileInOneSweep() async throws {
        await service.importServers([stdioServer(), httpServer()])
        let raw = try persistedJSON()
        for secret in ["rw_live_SUPERSECRET", "hosted_SUPERSECRET"] {
            XCTAssertFalse(raw.contains(secret), "\(secret) leaked into mcp-servers.json")
        }
    }

    // MARK: - 2. Trust is not inherited

    func testImportedStdioServerIsUntrustedAndCannotSpawn() async throws {
        let added = await service.importServers([stdioServer()])
        let config = try XCTUnwrap(added.first)
        XCTAssertNil(config.trustedCommandSignature)
        XCTAssertFalse(config.isTrusted)

        // Connect must refuse rather than spawn.
        await service.connect(id: config.id)
        XCTAssertEqual(service.runtime(id: config.id)?.status, .needsTrust)
    }

    func testImportDoesNotWriteATrustSignatureIntoTheConfigFile() async throws {
        await service.importServers([stdioServer()])
        XCTAssertFalse(try persistedJSON().contains("trustedCommandSignature"))
    }

    // MARK: - 3. Nothing is allowlisted or feed-bound

    func testImportedServerIsPresentAndInert() async throws {
        let added = await service.importServers([stdioServer()])
        let config = try XCTUnwrap(added.first)
        XCTAssertTrue(config.allowedTools.isEmpty, "default-deny must survive import")
        XCTAssertNil(config.feedTools)
    }

    func testImportedHTTPServerCannotCallAToolWithoutAnAllowEntry() async throws {
        let added = await service.importServers([httpServer()])
        let config = try XCTUnwrap(added.first)
        await service.connect(id: config.id)
        do {
            _ = try await service.callAllowedTool(
                serverID: config.id, name: "anything", arguments: nil)
            XCTFail("an imported server must not be able to call tools")
        } catch {
            XCTAssertEqual(error as? MCPClientService.ServiceError, .toolNotAllowed("anything"))
        }
    }

    // MARK: - 4. Blocked entries are never imported

    func testBlockedServersAreSkipped() async throws {
        var blocked = stdioServer(name: "supabase")
        blocked.blocker = .credentialInCommandLine(flag: "--access-token")
        let added = await service.importServers([blocked, httpServer()])
        XCTAssertEqual(added.map(\.name), ["hosted"])
    }

    func testImportingNothingLeavesTheStoreAlone() async {
        var blocked = stdioServer()
        blocked.blocker = .alreadyAdded
        let added = await service.importServers([blocked])
        XCTAssertTrue(added.isEmpty)
        XCTAssertTrue(service.store.servers.isEmpty)
    }

    // MARK: - Round trip

    func testImportedServersSurviveAReloadOfTheStore() async throws {
        await service.importServers([stdioServer(), httpServer()])
        let reloaded = MCPServerConfigStore(fileURL: tempURL)
        XCTAssertEqual(reloaded.servers.map(\.name), ["railway", "hosted"])
        XCTAssertEqual(reloaded.servers.first?.httpAuth, nil)
        XCTAssertEqual(reloaded.servers.last?.httpAuth, .bearer)
    }

    func testImportedStdioConfigCarriesEnvKeyNamesSorted() async throws {
        let server = stdioServer(environment: ["B_KEY": "2", "A_KEY": "1"])
        let added = await service.importServers([server])
        let config = try XCTUnwrap(added.first)
        guard case .stdio(_, _, let keys) = config.transport else {
            return XCTFail("expected stdio transport")
        }
        XCTAssertEqual(keys, ["A_KEY", "B_KEY"])
    }
}

/// Connects without doing anything — `MCPClientService.connect` only calls
/// `establish` for a real `MCPConnection`, so this never touches the network.
private final class FakeImportConnection: MCPConnecting {
    func listTools() async throws -> [MCPToolInfo] { [] }
    func listFullTools() async throws -> [MCP.Tool] { [] }
    func callTool(name: String, arguments: [String: MCP.Value]?) async throws -> MCPToolCallOutput {
        MCPToolCallOutput(result: MCP.CallTool.Result(content: [], isError: false))
    }
    func ping() async throws {}
    func disconnect() async {}
}
