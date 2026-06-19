//
//  ToolSearchTests.swift
//  GhostwireTests
//
//  GW-184: the search fallback. A query ranks the full downstream catalog by
//  name+description match; results carry their inputSchema so the agent can
//  call without a second round-trip.
//

import MCP
import XCTest

@testable import Ghostwire

final class ToolSearchTests: XCTestCase {
    private let objSchema: Value = .object(["type": .string("object")])

    private func tool(_ name: String, _ description: String) -> Tool {
        Tool(name: name, description: description, inputSchema: objSchema)
    }

    func testMatchesOnNameCaseInsensitively() {
        let catalog = [
            tool("linear_create_issue", "Create a Linear issue"),
            tool("github_list_repos", "List GitHub repositories"),
        ]
        let hits = ToolSearch.search(query: "CREATE ISSUE", catalog: catalog, limit: 10)

        XCTAssertEqual(hits.first?.name, "linear_create_issue")
        XCTAssertTrue(hits.contains { $0.name == "linear_create_issue" })
    }

    func testMatchesOnDescriptionWhenNameDoesNot() {
        let catalog = [
            tool("acme_widget", "Delete a customer record"),
            tool("acme_gadget", "Toggle a feature flag"),
        ]
        let hits = ToolSearch.search(query: "customer", catalog: catalog, limit: 10)

        XCTAssertEqual(hits.map(\.name), ["acme_widget"])
    }

    func testRanksMoreRelevantFirst() {
        let catalog = [
            tool("notes_search", "Search notes"),
            tool("issue_search_create", "Search and create issues"),
        ]
        // "search create" overlaps both tokens of the second tool, one of the first.
        let hits = ToolSearch.search(query: "search create", catalog: catalog, limit: 10)

        XCTAssertEqual(hits.first?.name, "issue_search_create")
    }

    func testRespectsLimit() {
        let catalog = (1...20).map { tool("search_tool_\($0)", "search target \($0)") }
        let hits = ToolSearch.search(query: "search", catalog: catalog, limit: 10)

        XCTAssertEqual(hits.count, 10)
    }

    func testPreservesInputSchemaOnResults() {
        let schema: Value = .object([
            "type": .string("object"),
            "properties": .object(["q": .object(["type": .string("string")])]),
        ])
        let catalog = [Tool(name: "find_thing", description: "find a thing", inputSchema: schema)]
        let hits = ToolSearch.search(query: "find", catalog: catalog, limit: 10)

        XCTAssertEqual(hits.first?.inputSchema, schema)
    }

    func testNoMatchReturnsEmpty() {
        let catalog = [tool("alpha", "first"), tool("beta", "second")]
        let hits = ToolSearch.search(query: "zzzznomatch", catalog: catalog, limit: 10)

        XCTAssertTrue(hits.isEmpty)
    }
}
