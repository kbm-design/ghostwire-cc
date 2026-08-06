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
    /// Captures calls so routing assertions can inspect them. `@unchecked` —
    /// test-only, driven single-threaded through `await`.
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

    /// Captures usage records and serves a preset snapshot. Actor → Sendable.
    private actor FakeUsage: ToolUsageRecording {
        private(set) var recorded: [String] = []
        private let preset: [String: ToolUsage]
        init(_ preset: [String: ToolUsage] = [:]) { self.preset = preset }
        func record(_ exposedName: String) async { recorded.append(exposedName) }
        func snapshot() async -> [String: ToolUsage] { preset }
        func recordedNames() -> [String] { recorded }
    }

    private func server(_ name: String, _ tools: [Tool]) -> GatewayUpstreamServer {
        GatewayUpstreamServer(id: UUID(), displayName: name, tools: tools)
    }

    private func bareTool(_ name: String, _ desc: String = "") -> Tool {
        Tool(name: name, description: desc, inputSchema: .object(["type": .string("object")]))
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

    func testBuildExposurePreservesOutputSchema() async {
        // Codex P2: structured-output tools must keep their outputSchema contract
        // when re-exposed, not just inputSchema.
        let outputSchema: Value = .object([
            "type": .string("object"),
            "properties": .object(["id": .object(["type": .string("string")])]),
        ])
        let tool = Tool(
            name: "create_issue", description: "", inputSchema: .object(["type": .string("object")]),
            outputSchema: outputSchema)
        let source = FakeSource([
            GatewayUpstreamServer(id: UUID(), displayName: "Linear", tools: [tool])
        ])

        let exposure = await MCPGatewayCore(source: source).buildExposure()

        XCTAssertEqual(exposure.tools.first?.outputSchema, outputSchema)
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

    func testCallRoutesToDownstreamByExposedName() async throws {
        let serverID = UUID()
        let create = Tool(name: "create_issue", description: "", inputSchema: .object(["type": .string("object")]))
        let source = FakeSource([
            GatewayUpstreamServer(id: serverID, displayName: "Linear", tools: [create])
        ])
        let usage = FakeUsage()
        let core = MCPGatewayCore(source: source, usage: usage)

        let output = try await core.call(
            exposedName: "linear_create_issue", arguments: ["title": .string("Bug")])

        XCTAssertEqual(source.recorded?.serverID, serverID)
        XCTAssertEqual(source.recorded?.tool, "create_issue")  // bare downstream name, prefix stripped
        XCTAssertEqual(source.recorded?.arguments?["title"], .string("Bug"))
        XCTAssertEqual(output.textRepresentation, "stub")
        let logged = await usage.recordedNames()
        XCTAssertEqual(logged, ["linear_create_issue"])  // direct call is logged for the working set
    }

    func testCallUnknownToolThrows() async {
        let core = MCPGatewayCore(source: FakeSource([]), usage: FakeUsage())
        do {
            _ = try await core.call(exposedName: "nope_tool", arguments: nil)
            XCTFail("expected unknownTool to throw")
        } catch GatewayError.unknownTool(let name) {
            XCTAssertEqual(name, "nope_tool")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - GW-184 working set + search/call fallback

    func testPublicExposureReturnsWorkingSetPlusMetaTools() async {
        // Cold start (empty usage), small catalog under cap → all real tools
        // exposed, followed by the two meta tools.
        let source = FakeSource([
            server("Linear", [bareTool("create_issue"), bareTool("list_issues")])
        ])
        let core = MCPGatewayCore(source: source, usage: FakeUsage())

        let names = await core.publicExposure().tools.map(\.name)

        XCTAssertEqual(
            names, ["linear_create_issue", "linear_list_issues", "search_tools", "call_tool"])
    }

    func testPublicExposureBoundsSurfaceToCapPlusMetaTools() async {
        // 40 tools, cap 10 → only 10 working-set tools + 2 meta are advertised,
        // not the full 40. This is the whole point of GW-184.
        let tools = (1...40).map { bareTool("tool_\($0)") }
        let source = FakeSource([server("Big", tools)])
        let core = MCPGatewayCore(
            source: source, usage: FakeUsage(),
            config: WorkingSetConfig(recencyLimit: 15, frequencyLimit: 10, cap: 10, searchLimit: 10))

        let exposed = await core.publicExposure().tools

        XCTAssertEqual(exposed.count, 12)  // 10 working-set + search_tools + call_tool
        XCTAssertTrue(exposed.contains { $0.name == "search_tools" })
        XCTAssertTrue(exposed.contains { $0.name == "call_tool" })
    }

    func testCallToolMetaRoutesAndLogsInnerTool() async throws {
        let serverID = UUID()
        let source = FakeSource([
            GatewayUpstreamServer(
                id: serverID, displayName: "Linear",
                tools: [
                    Tool(
                        name: "list_issues", description: "",
                        inputSchema: .object(["type": .string("object")]),
                        annotations: .init(readOnlyHint: true))
                ])
        ])
        let usage = FakeUsage()
        let core = MCPGatewayCore(source: source, usage: usage)

        _ = try await core.call(
            exposedName: "call_tool",
            arguments: ["name": .string("linear_list_issues"),
                        "arguments": .object(["limit": .int(10)])])

        XCTAssertEqual(source.recorded?.serverID, serverID)
        XCTAssertEqual(source.recorded?.tool, "list_issues")
        XCTAssertEqual(source.recorded?.arguments?["limit"], .int(10))
        let logged = await usage.recordedNames()
        XCTAssertEqual(logged, ["linear_list_issues"])  // the inner tool, not "call_tool"
    }

    func testCallToolMetaRejectsMutatingInnerTool() async {
        let source = FakeSource([
            server("Linear", [
                Tool(
                    name: "create_issue", description: "",
                    inputSchema: .object(["type": .string("object")]),
                    annotations: .init(readOnlyHint: false, destructiveHint: false))
            ])
        ])
        let usage = FakeUsage()
        let core = MCPGatewayCore(source: source, usage: usage)

        do {
            _ = try await core.call(
                exposedName: "call_tool",
                arguments: ["name": .string("linear_create_issue")])
            XCTFail("expected call_tool to reject mutating tools")
        } catch GatewayError.metaToolRequiresDirectCall(let name) {
            XCTAssertEqual(name, "linear_create_issue")
            XCTAssertNil(source.recorded)
            let logged = await usage.recordedNames()
            XCTAssertTrue(logged.isEmpty)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testCallToolMetaUnknownInnerThrows() async {
        let core = MCPGatewayCore(source: FakeSource([]), usage: FakeUsage())
        do {
            _ = try await core.call(exposedName: "call_tool", arguments: ["name": .string("ghost_tool")])
            XCTFail("expected unknownTool")
        } catch GatewayError.unknownTool(let name) {
            XCTAssertEqual(name, "ghost_tool")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testDownstreamCannotShadowMetaToolNames() async {
        // Codex P2: a server slugging to "search_tools"/"call_tool" must not
        // collide with the meta tools — it gets suffixed, meta names stay ours.
        let searchServer = GatewayUpstreamServer(
            id: UUID(), displayName: "search", tools: [bareTool("tools")])  // → search_tools
        let callServer = GatewayUpstreamServer(
            id: UUID(), displayName: "call", tools: [bareTool("tool")])  // → call_tool
        let source = FakeSource([searchServer, callServer])
        let core = MCPGatewayCore(source: source, usage: FakeUsage())

        let exposure = await core.buildExposure()

        // The downstream tools are reachable under disambiguated names...
        XCTAssertEqual(exposure.routes["search_tools_2"]?.serverID, searchServer.id)
        XCTAssertEqual(exposure.routes["call_tool_2"]?.serverID, callServer.id)
        // ...and the bare meta names are NOT downstream routes.
        XCTAssertNil(exposure.routes["search_tools"])
        XCTAssertNil(exposure.routes["call_tool"])
    }

    func testSearchToolsMetaReturnsMatchesWithoutCallingDownstream() async throws {
        let source = FakeSource([
            server("Linear", [bareTool("create_issue", "Create a Linear issue")]),
            server("GitHub", [bareTool("list_repos", "List GitHub repositories")]),
        ])
        let usage = FakeUsage()
        let core = MCPGatewayCore(source: source, usage: usage)

        let output = try await core.call(
            exposedName: "search_tools", arguments: ["query": .string("create issue")])

        XCTAssertTrue(output.textRepresentation.contains("linear_create_issue"))
        XCTAssertFalse(output.textRepresentation.contains("github_list_repos"))
        XCTAssertNotNil(output.structuredContent)  // schema-bearing results for call_tool
        XCTAssertNil(source.recorded)  // search resolves locally, never hits a downstream
        let logged = await usage.recordedNames()
        XCTAssertTrue(logged.isEmpty)  // searching is not using
    }
}
