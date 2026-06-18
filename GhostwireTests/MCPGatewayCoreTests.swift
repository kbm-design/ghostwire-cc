//
//  MCPGatewayCoreTests.swift
//  GhostwireTests
//
//  GW-253: the gateway core merges the user's connected downstream servers into
//  one namespaced tool surface and routes calls back. These tests drive it
//  through an injected fake source — no live downstream, no transport.
//

import MCP
import XCTest

@testable import Ghostwire

final class MCPGatewayCoreTests: XCTestCase {
    /// Captures calls so routing assertions can inspect them.
    private final class FakeSource: GatewayUpstreamSource {
        let provided: [GatewayUpstreamServer]
        init(_ provided: [GatewayUpstreamServer]) { self.provided = provided }
        func servers() async -> [GatewayUpstreamServer] { provided }
        func call(serverID: UUID, tool: String, arguments: [String: Value]?) async throws
            -> MCPToolCallOutput {
            MCPToolCallOutput(
                result: CallTool.Result(content: [.text(text: "stub", annotations: nil, _meta: nil)]))
        }
    }

    func testBuildExposureNamespacesToolsAndForwardsSchema() async {
        let titleSchema: Value = .object([
            "type": .string("object"),
            "properties": .object(["title": .object(["type": .string("string")])]),
        ])
        let serverID = UUID()
        let create = Tool(name: "create_issue", description: "Create an issue", inputSchema: titleSchema)
        let list = Tool(name: "list_issues", description: "List issues", inputSchema: .object(["type": .string("object")]))
        let source = FakeSource([
            GatewayUpstreamServer(id: serverID, displayName: "Linear", tools: [create, list])
        ])
        let core = MCPGatewayCore(source: source)

        let exposure = await core.buildExposure()

        XCTAssertEqual(exposure.tools.map(\.name), ["linear_create_issue", "linear_list_issues"])
        let exposedCreate = exposure.tools.first { $0.name == "linear_create_issue" }
        XCTAssertEqual(exposedCreate?.inputSchema, titleSchema)  // schema forwarded, not dropped
        XCTAssertEqual(exposedCreate?.description, "Create an issue")
        XCTAssertEqual(exposure.routes["linear_create_issue"]?.serverID, serverID)
        XCTAssertEqual(exposure.routes["linear_create_issue"]?.originalName, "create_issue")
    }

    func testBuildExposureDisambiguatesCollidingNames() async {
        let idA = UUID()
        let idB = UUID()
        let objSchema: Value = .object(["type": .string("object")])
        let toolA = Tool(name: "create_issue", description: "A", inputSchema: objSchema)
        let toolB = Tool(name: "create_issue", description: "B", inputSchema: objSchema)
        // Two servers slug-identical ("linear") both exposing create_issue.
        let source = FakeSource([
            GatewayUpstreamServer(id: idA, displayName: "Linear", tools: [toolA]),
            GatewayUpstreamServer(id: idB, displayName: "Linear", tools: [toolB]),
        ])

        let exposure = await MCPGatewayCore(source: source).buildExposure()

        XCTAssertEqual(exposure.tools.map(\.name), ["linear_create_issue", "linear_create_issue_2"])
        XCTAssertEqual(exposure.routes["linear_create_issue"]?.serverID, idA)
        XCTAssertEqual(exposure.routes["linear_create_issue_2"]?.serverID, idB)
        XCTAssertEqual(exposure.routes["linear_create_issue_2"]?.originalName, "create_issue")
    }
}
