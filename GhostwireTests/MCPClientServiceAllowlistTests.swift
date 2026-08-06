import MCP
import XCTest

@testable import Ghostwire

/// Fake connection: records calls, returns canned tools/results.
private final class FakeConnection: MCPConnecting {
    var tools: [MCPToolInfo] = []
    var fullTools: [Tool] = []
    var calledTools: [String] = []
    var disconnected = false
    func listTools() async throws -> [MCPToolInfo] { tools }
    func listFullTools() async throws -> [Tool] { fullTools }
    func callTool(name: String, arguments: [String: Value]?) async throws -> MCPToolCallOutput {
        calledTools.append(name)
        return MCPToolCallOutput(result: CallTool.Result(content: [], isError: false))
    }
    func ping() async throws {}
    func disconnect() async { disconnected = true }
}

@MainActor
final class MCPClientServiceAllowlistTests: XCTestCase {
    private var service: MCPClientService!
    private var fake: FakeConnection!
    private var tempURL: URL!

    override func setUp() async throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-allowlist-\(UUID().uuidString).json")
        fake = FakeConnection()
        service = MCPClientService(
            store: MCPServerConfigStore(fileURL: tempURL),
            secretStore: InMemoryMCPSecretStore(),
            connectionFactory: { [fake] _ in fake! }
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    private func addHTTPServer(allowed: Set<String> = []) -> MCPServerConfig {
        var config = MCPServerConfig(
            id: UUID(), name: "S",
            transport: .http(endpoint: URL(string: "https://example.com/mcp")!)
        )
        config.allowedTools = allowed
        service.addServer(config)
        return config
    }

    // MARK: - GW-255 bulk selection

    func testBulkAllowAddsEveryToolInOneWrite() {
        let config = addHTTPServer()
        service.setToolsAllowed(
            serverID: config.id, tools: ["get_a", "get_b", "get_c"], allowed: true)
        XCTAssertEqual(
            service.store.server(id: config.id)?.allowedTools, ["get_a", "get_b", "get_c"])
    }

    func testBulkAllowIsAdditiveNotReplacing() {
        let config = addHTTPServer(allowed: ["existing"])
        service.setToolsAllowed(serverID: config.id, tools: ["get_a"], allowed: true)
        XCTAssertEqual(service.store.server(id: config.id)?.allowedTools, ["existing", "get_a"])
    }

    func testBulkRemoveOnlySubtractsTheNamedTools() {
        let config = addHTTPServer(allowed: ["a", "b", "c"])
        service.setToolsAllowed(serverID: config.id, tools: ["a", "c"], allowed: false)
        XCTAssertEqual(service.store.server(id: config.id)?.allowedTools, ["b"])
    }

    /// Disallowing implies unbinding (GW-214) — the bulk path must honour that
    /// too, or a "Remove all" leaves feed bindings that fail closed every poll.
    func testBulkRemoveUnbindsFeedToolsForEveryRemovedTool() {
        var config = addHTTPServer(allowed: ["a", "b"])
        config.feedTools = [MCPFeedToolBinding(tool: "a"), MCPFeedToolBinding(tool: "b")]
        service.store.update(config)

        service.setToolsAllowed(serverID: config.id, tools: ["a", "b"], allowed: false)
        XCTAssertEqual(service.store.server(id: config.id)?.feedTools ?? [], [])
    }

    func testBulkWithNoToolsIsANoOp() {
        let config = addHTTPServer(allowed: ["a"])
        service.setToolsAllowed(serverID: config.id, tools: [], allowed: false)
        XCTAssertEqual(service.store.server(id: config.id)?.allowedTools, ["a"])
    }

    /// The single-tool entry point is now a wrapper — it must keep behaving.
    func testSingleToolPathStillWorksThroughTheBulkImplementation() {
        let config = addHTTPServer()
        service.setToolAllowed(serverID: config.id, tool: "only", allowed: true)
        XCTAssertEqual(service.store.server(id: config.id)?.allowedTools, ["only"])
        service.setToolAllowed(serverID: config.id, tool: "only", allowed: false)
        XCTAssertEqual(service.store.server(id: config.id)?.allowedTools, [])
    }

    func testCallToolDeniedByDefault() async {
        let config = addHTTPServer()  // empty allowlist
        await service.connect(id: config.id)
        do {
            _ = try await service.callAllowedTool(
                serverID: config.id, name: "get_price", arguments: nil)
            XCTFail("default-deny must throw")
        } catch let error as MCPClientService.ServiceError {
            XCTAssertEqual(error, .toolNotAllowed("get_price"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertTrue(fake.calledTools.isEmpty, "the call must never reach the connection")
    }

    func testAllowedToolGoesThrough() async throws {
        let config = addHTTPServer(allowed: ["get_price"])
        await service.connect(id: config.id)
        _ = try await service.callAllowedTool(serverID: config.id, name: "get_price", arguments: nil)
        XCTAssertEqual(fake.calledTools, ["get_price"])
    }

    func testUntrustedStdioServerWillNotConnect() async {
        // No trustedCommandSignature set -> spawn must be refused.
        let config = MCPServerConfig(
            id: UUID(), name: "Untrusted",
            transport: .stdio(command: "npx", arguments: ["-y", "x"], environmentKeys: []),
            resolvedExecutablePath: "/usr/bin/true"
        )
        service.addServer(config)
        await service.connect(id: config.id)
        guard case .needsTrust = service.runtime(id: config.id)?.status else {
            return XCTFail(
                "expected .needsTrust, got \(String(describing: service.runtime(id: config.id)?.status))"
            )
        }
    }

    func testConnectPopulatesToolsAndProbeRecord() async {
        fake.tools = [
            MCPToolInfo(
                name: "typed", description: nil, hasOutputSchema: true,
                isReadOnlyHinted: true, isDestructiveHinted: nil),
            MCPToolInfo(
                name: "plain", description: nil, hasOutputSchema: false,
                isReadOnlyHinted: nil, isDestructiveHinted: nil),
        ]
        let config = addHTTPServer()
        await service.connect(id: config.id)
        guard case .connected(let count) = service.runtime(id: config.id)?.status else {
            return XCTFail("expected .connected")
        }
        XCTAssertEqual(count, 2)
        let probe = service.store.server(id: config.id)?.lastProbe
        XCTAssertEqual(probe?.toolCount, 2)
        XCTAssertEqual(probe?.toolsWithOutputSchema, ["typed"])
    }

    // MARK: - GW-253 gateway source

    func testGatewaySourceYieldsAllowlistedFullToolsWithSchema() async {
        let schema: Value = .object([
            "type": .string("object"),
            "properties": .object(["title": .object(["type": .string("string")])]),
        ])
        fake.fullTools = [
            Tool(name: "create_issue", description: "Create", inputSchema: schema),
            Tool(name: "delete_issue", description: "Delete", inputSchema: .object(["type": .string("object")])),
        ]
        let config = addHTTPServer(allowed: ["create_issue"])  // delete_issue NOT allowed
        await service.connect(id: config.id)

        let source = MCPClientServiceUpstreamSource(service: service)
        let servers = await source.servers()

        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers.first?.id, config.id)
        XCTAssertEqual(servers.first?.displayName, "S")
        XCTAssertEqual(servers.first?.tools.map(\.name), ["create_issue"])  // allowlist applied
        XCTAssertEqual(servers.first?.tools.first?.inputSchema, schema)  // full schema, not dropped
    }

    func testGatewaySourceCallRoutesThroughAllowlistChokepoint() async throws {
        fake.fullTools = [
            Tool(name: "create_issue", description: "", inputSchema: .object(["type": .string("object")]))
        ]
        let config = addHTTPServer(allowed: ["create_issue"])
        await service.connect(id: config.id)

        let source = MCPClientServiceUpstreamSource(service: service)
        _ = try await source.call(
            serverID: config.id, tool: "create_issue", arguments: ["title": .string("Bug")])

        XCTAssertEqual(fake.calledTools, ["create_issue"])
    }

    func testRemoveServerDeletesConfig() async {
        let config = addHTTPServer()
        service.removeServer(id: config.id)
        XCTAssertNil(service.store.server(id: config.id))
        XCTAssertNil(service.runtime(id: config.id))
    }

    /// Codex review P2: a second connect (Test/Authorize re-press) must tear
    /// down the previous connection, not orphan its stdio process.
    func testReconnectDisconnectsPreviousConnection() async {
        var created: [FakeConnection] = []
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-reconnect-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let service = MCPClientService(
            store: MCPServerConfigStore(fileURL: url),
            secretStore: InMemoryMCPSecretStore(),
            connectionFactory: { _ in
                let fake = FakeConnection()
                created.append(fake)
                return fake
            }
        )
        let config = MCPServerConfig(
            id: UUID(), name: "S",
            transport: .http(endpoint: URL(string: "https://example.com/mcp")!)
        )
        service.addServer(config)
        await service.connect(id: config.id)
        await service.connect(id: config.id)
        XCTAssertEqual(created.count, 2)
        XCTAssertTrue(created[0].disconnected, "first connection must be torn down")
        XCTAssertFalse(created[1].disconnected, "second connection stays live")
    }
}
