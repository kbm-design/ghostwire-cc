import MCP
import XCTest

@testable import Ghostwire

/// Fake connection: records calls, returns canned tools/results.
private final class FakeConnection: MCPConnecting {
    var tools: [MCPToolInfo] = []
    var calledTools: [String] = []
    func listTools() async throws -> [MCPToolInfo] { tools }
    func callTool(name: String, arguments: [String: Value]?) async throws -> MCPToolCallOutput {
        calledTools.append(name)
        return MCPToolCallOutput(result: CallTool.Result(content: [], isError: false))
    }
    func ping() async throws {}
    func disconnect() async {}
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

    func testRemoveServerDeletesConfig() async {
        let config = addHTTPServer()
        service.removeServer(id: config.id)
        XCTAssertNil(service.store.server(id: config.id))
        XCTAssertNil(service.runtime(id: config.id))
    }
}
