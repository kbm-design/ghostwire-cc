//
//  MCPServeRuntimeTests.swift
//  GhostwireTests
//
//  GW-173: end-to-end over InMemoryTransport — a real SDK Server (our serve
//  side) talking to a real SDK Client (GW-219's MCPConnection). The symmetric
//  proof that one Swift MCP codebase serves both directions. Data is injected,
//  so the user's real Shelf file is never touched.
//

import Defaults
import MCP
import XCTest

@testable import Ghostwire

@MainActor
final class MCPServeRuntimeTests: XCTestCase {
    private var originalEnabled = false

    override func setUp() {
        super.setUp()
        originalEnabled = Defaults[.mcpServeEnabled]
        Defaults[.mcpServeEnabled] = true
    }

    override func tearDown() {
        Defaults[.mcpServeEnabled] = originalEnabled
        super.tearDown()
    }

    private func connect(items: [ShelfStoredItem]) async throws -> MCPConnection {
        let server = await MCPServeRuntime.makeServer(provider: {
            ShelfContextProvider(items: items)
        })
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let connection = MCPConnection(serverName: "ghostwire-test")
        try await connection.connect(transport: clientTransport)
        return connection
    }

    func testListToolsExposesThreeReadOnlyTools() async throws {
        let connection = try await connect(items: [])
        let tools = try await connection.listTools()
        XCTAssertEqual(Set(tools.map(\.name)), ["get_held_items", "search_saves", "get_file"])
        XCTAssertTrue(tools.allSatisfy { $0.isReadOnlyHinted == true })
        await connection.disconnect()
    }

    func testGetHeldItemsFlowsStructuredContent() async throws {
        let item = ShelfStoredItem(kind: .text(string: "roadmap notes"))
        let connection = try await connect(items: [item])
        let output = try await connection.callTool(name: "get_held_items", arguments: nil)
        XCTAssertEqual(output.isError, false)
        XCTAssertNotNil(output.structuredContent)
        XCTAssertTrue(output.textRepresentation.contains("roadmap notes"))
        await connection.disconnect()
    }

    func testGetFileReturnsTextContent() async throws {
        let item = ShelfStoredItem(kind: .text(string: "the body text"))
        let connection = try await connect(items: [item])
        let output = try await connection.callTool(
            name: "get_file", arguments: ["id": .string(item.id.uuidString)])
        XCTAssertTrue(output.textRepresentation.contains("the body text"))
        await connection.disconnect()
    }

    func testSearchFiltersResults() async throws {
        let alpha = ShelfStoredItem(kind: .text(string: "alpha snippet"))
        let beta = ShelfStoredItem(kind: .text(string: "beta snippet"))
        let connection = try await connect(items: [alpha, beta])
        let output = try await connection.callTool(
            name: "search_saves", arguments: ["query": .string("alpha")])
        XCTAssertTrue(output.textRepresentation.contains("alpha"))
        XCTAssertFalse(output.textRepresentation.contains("beta"))
        await connection.disconnect()
    }

    func testGetFileUnknownIdIsError() async throws {
        let connection = try await connect(items: [])
        let output = try await connection.callTool(
            name: "get_file", arguments: ["id": .string(UUID().uuidString)])
        XCTAssertEqual(output.isError, true)
        await connection.disconnect()
    }

    func testDisabledGateServesNothing() async throws {
        Defaults[.mcpServeEnabled] = false
        let item = ShelfStoredItem(kind: .text(string: "secret data"))
        let connection = try await connect(items: [item])
        let output = try await connection.callTool(name: "get_held_items", arguments: nil)
        XCTAssertFalse(output.textRepresentation.contains("secret data"))
        XCTAssertTrue(output.textRepresentation.lowercased().contains("turned off"))
        await connection.disconnect()
    }
}
