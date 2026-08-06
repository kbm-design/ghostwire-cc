//
//  MCPGatewayEndToEndTests.swift
//  GhostwireTests
//
//  GW-253: prove the gateway core behind a real SDK Server, driven by a real
//  SDK Client over the in-memory transport (mirrors MCPServeRuntimeTests). This
//  is the Phase 0 proof — the namespaced tools AND their inputSchema cross the
//  wire, and a CallTool routes through to the downstream. No real transport/UI.
//

import MCP
import XCTest

@testable import Ghostwire

final class MCPGatewayEndToEndTests: XCTestCase {
    private final class FakeSource: GatewayUpstreamSource, @unchecked Sendable {
        struct Recorded { let serverID: UUID; let tool: String; let arguments: [String: Value]? }
        let provided: [GatewayUpstreamServer]
        private(set) var recorded: Recorded?
        init(_ provided: [GatewayUpstreamServer]) { self.provided = provided }
        func servers() async -> [GatewayUpstreamServer] { provided }
        func call(serverID: UUID, tool: String, arguments: [String: Value]?) async throws
            -> MCPToolCallOutput {
            recorded = Recorded(serverID: serverID, tool: tool, arguments: arguments)
            return MCPToolCallOutput(
                result: CallTool.Result(content: [.text(text: "stub", annotations: nil, _meta: nil)]))
        }
    }

    func testGatewayServesNamespacedToolsWithSchemaAndRoutesCallsOverTheWire() async throws {
        let titleSchema: Value = .object([
            "type": .string("object"),
            "properties": .object(["title": .object(["type": .string("string")])]),
        ])
        let serverID = UUID()
        let create = Tool(name: "create_issue", description: "Create an issue", inputSchema: titleSchema)
        let source = FakeSource([
            GatewayUpstreamServer(id: serverID, displayName: "Linear", tools: [create])
        ])
        let core = MCPGatewayCore(source: source)
        let exposure = await core.buildExposure()

        let server = Server(
            name: "ghostwire-gateway-test", version: "0",
            capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: exposure.tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            let output = try await core.call(exposedName: params.name, arguments: params.arguments)
            return CallTool.Result(
                content: [.text(text: output.textRepresentation, annotations: nil, _meta: nil)],
                isError: output.isError ?? false)
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let client = Client(name: "gw-test-client", version: "0")
        _ = try await client.connect(transport: clientTransport)

        // tools/list — namespaced name AND the forwarded schema survive the wire.
        let listed = try await client.listTools(cursor: nil)
        let tool = listed.tools.first { $0.name == "linear_create_issue" }
        XCTAssertNotNil(tool)
        XCTAssertEqual(tool?.inputSchema, titleSchema)

        // tools/call — routes through to the downstream (prefix stripped).
        let context: RequestContext<CallTool.Result> = try await client.callTool(
            name: "linear_create_issue", arguments: ["title": .string("Bug")])
        let result = try await context.value
        XCTAssertEqual(source.recorded?.tool, "create_issue")
        XCTAssertEqual(source.recorded?.serverID, serverID)
        let text = result.content.compactMap { content -> String? in
            if case .text(let t, _, _) = content { return t }
            return nil
        }.joined()
        XCTAssertEqual(text, "stub")

        await client.disconnect()
    }
}
