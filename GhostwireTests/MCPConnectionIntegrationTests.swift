import MCP
import XCTest

@testable import Ghostwire

final class MCPConnectionIntegrationTests: XCTestCase {

    /// Builds a real SDK server with one schema-declaring tool and one plain
    /// tool, wired to the connection over InMemoryTransport.
    private func makeServerAndConnection() async throws -> (Server, MCPConnection) {
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [
                Tool(
                    name: "typed_price",
                    description: "Price with output schema",
                    inputSchema: .object([:]),
                    annotations: .init(readOnlyHint: true),
                    outputSchema: .object(["type": .string("object")])
                ),
                Tool(
                    name: "plain_echo",
                    description: "No schema",
                    inputSchema: .object([:])
                ),
            ])
        }
        await server.withMethodHandler(CallTool.self) { params in
            if params.name == "typed_price" {
                return CallTool.Result(
                    content: [.text(text: "{\"usd\":42}", annotations: nil, _meta: nil)],
                    structuredContent: .object(["usd": .double(42)]),
                    isError: false
                )
            }
            return CallTool.Result(
                content: [.text(text: "echo", annotations: nil, _meta: nil)],
                isError: false
            )
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let connection = MCPConnection(serverName: "TestServer")
        try await connection.connect(transport: clientTransport)
        return (server, connection)
    }

    func testConnectListsToolsWithSchemaPresence() async throws {
        let (_, connection) = try await makeServerAndConnection()
        let tools = try await connection.listTools()
        XCTAssertEqual(tools.map(\.name).sorted(), ["plain_echo", "typed_price"])
        XCTAssertTrue(tools.first { $0.name == "typed_price" }!.hasOutputSchema)
        XCTAssertFalse(tools.first { $0.name == "plain_echo" }!.hasOutputSchema)
        XCTAssertEqual(tools.first { $0.name == "typed_price" }!.isReadOnlyHinted, true)
    }

    func testCallToolSurfacesStructuredContent() async throws {
        let (_, connection) = try await makeServerAndConnection()
        let output = try await connection.callTool(name: "typed_price", arguments: nil)
        XCTAssertNotNil(output.structuredContent)
        XCTAssertEqual(output.isError, false)
        XCTAssertFalse(output.textRepresentation.isEmpty)
    }

    func testCallToolWithoutSchemaHasNilStructuredContent() async throws {
        let (_, connection) = try await makeServerAndConnection()
        let output = try await connection.callTool(name: "plain_echo", arguments: nil)
        XCTAssertNil(output.structuredContent)
    }

    func testDisconnectThenCallThrows() async throws {
        let (_, connection) = try await makeServerAndConnection()
        await connection.disconnect()
        do {
            _ = try await connection.callTool(name: "plain_echo", arguments: nil)
            XCTFail("expected throw after disconnect")
        } catch { /* expected */ }
    }
}
