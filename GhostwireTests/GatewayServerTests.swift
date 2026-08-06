//
//  GatewayServerTests.swift
//  GhostwireTests
//
//  GW-253 Phase 2: the gateway MCP server composition — ListTools exposes the
//  namespaced downstream tools, CallTool routes them, ListResources answers
//  empty-but-prompt (Codex marks a server unavailable / hangs otherwise).
//  Driven over the in-memory transport (no HTTP, no live downstream).
//

import MCP
import XCTest

@testable import Ghostwire

final class GatewayServerTests: XCTestCase {
    private final class FakeSource: GatewayUpstreamSource, @unchecked Sendable {
        struct Recorded { let tool: String; let arguments: [String: Value]? }
        let provided: [GatewayUpstreamServer]
        var output: MCPToolCallOutput
        private(set) var recorded: Recorded?
        init(
            _ provided: [GatewayUpstreamServer],
            output: MCPToolCallOutput = MCPToolCallOutput(
                result: CallTool.Result(content: [.text(text: "ok", annotations: nil, _meta: nil)]))
        ) {
            self.provided = provided
            self.output = output
        }
        func servers() async -> [GatewayUpstreamServer] { provided }
        func call(serverID: UUID, tool: String, arguments: [String: Value]?) async throws
            -> MCPToolCallOutput {
            recorded = Recorded(tool: tool, arguments: arguments)
            return output
        }
    }

    func testMakeServerListsNamespacedToolsRoutesCallsAndAnswersResources() async throws {
        let schema: Value = .object(["type": .string("object")])
        let create = Tool(name: "create_issue", description: "Create", inputSchema: schema)
        let source = FakeSource([
            GatewayUpstreamServer(id: UUID(), displayName: "Linear", tools: [create])
        ])
        let server = await GatewayServer.makeServer(source: source)

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let client = Client(name: "gw-server-test", version: "0")
        _ = try await client.connect(transport: clientTransport)

        // GW-184: the advertised surface is the working set (here just the one
        // cold-start tool) plus the search_tools/call_tool fallback.
        let tools = try await client.listTools(cursor: nil)
        XCTAssertEqual(tools.tools.map(\.name), ["linear_create_issue", "search_tools", "call_tool"])

        let context: RequestContext<CallTool.Result> = try await client.callTool(
            name: "linear_create_issue", arguments: ["title": .string("Bug")])
        _ = try await context.value
        XCTAssertEqual(source.recorded?.tool, "create_issue")

        // resources/list must answer promptly (empty) — Codex hangs otherwise.
        let resources = try await client.listResources(cursor: nil)
        XCTAssertTrue(resources.resources.isEmpty)

        await client.disconnect()
    }

    func testGatewayForwardsMultiItemContentNotFlattenedToText() async throws {
        // Codex P2: a downstream returning multiple/non-text content items must
        // pass through intact, not be collapsed into a single text item.
        let multi = MCPToolCallOutput(
            result: CallTool.Result(content: [
                .text(text: "one", annotations: nil, _meta: nil),
                .text(text: "two", annotations: nil, _meta: nil),
            ]))
        let create = Tool(name: "create_issue", description: "", inputSchema: .object(["type": .string("object")]))
        let source = FakeSource(
            [GatewayUpstreamServer(id: UUID(), displayName: "Linear", tools: [create])],
            output: multi)
        let server = await GatewayServer.makeServer(source: source)

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let client = Client(name: "gw-multi-test", version: "0")
        _ = try await client.connect(transport: clientTransport)

        let context: RequestContext<CallTool.Result> = try await client.callTool(
            name: "linear_create_issue", arguments: [:])
        let result = try await context.value
        XCTAssertEqual(result.content.count, 2)  // not collapsed to one text item

        await client.disconnect()
    }
}
