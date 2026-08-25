//
//  AddCardsSectionTests.swift
//  GhostwireTests
//
//  GW-466. The Add-cards page's two pure seams: which tools a server section
//  offers (eligibility = enabled ∧ connected ∧ allowed ∧ feed candidate), and
//  the card-id round trip the context menu depends on to map a rendered card
//  back to its binding.
//

import XCTest

@testable import Ghostwire

final class AddCardsSectionTests: XCTestCase {
    private func tool(
        _ name: String,
        required: [String] = [],
        readOnly: Bool? = nil,
        destructive: Bool? = nil
    ) -> MCPToolInfo {
        MCPToolInfo(
            name: name,
            description: nil,
            hasOutputSchema: false,
            isReadOnlyHinted: readOnly,
            isDestructiveHinted: destructive,
            requiredInputs: required
        )
    }

    private func config(
        id: UUID = UUID(),
        name: String = "Linear",
        allowed: Set<String>,
        bound: [String] = [],
        enabled: Bool = true
    ) -> MCPServerConfig {
        MCPServerConfig(
            id: id,
            name: name,
            transport: .http(endpoint: URL(string: "https://example.com/mcp")!),
            allowedTools: allowed,
            isEnabled: enabled,
            feedTools: bound.map { MCPFeedToolBinding(tool: $0) }
        )
    }

    // MARK: Eligibility

    func testOffersOnlyAllowedFeedCandidates() {
        let id = UUID()
        let server = config(id: id, allowed: ["list_issues", "search_issues", "delete_issue"])
        let runtime = MCPServerRuntime(
            status: .connected(toolCount: 4),
            tools: [
                tool("list_issues"),                                  // eligible
                tool("search_issues", required: ["query"]),           // question, not a standing value
                tool("delete_issue", destructive: true),              // destructive-hinted
                tool("list_projects"),                                // candidate but NOT allowed
            ]
        )

        let sections = AddCardsSection.build(servers: [server], runtimes: [id: runtime])

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].tools.map(\.name), ["list_issues"])
    }

    func testDisconnectedDisabledAndEmptyServersHaveNoSection() {
        let disconnectedID = UUID()
        let disabledID = UUID()
        let emptyID = UUID()
        let servers = [
            config(id: disconnectedID, allowed: ["list_issues"]),
            config(id: disabledID, allowed: ["list_issues"], enabled: false),
            config(id: emptyID, allowed: []),
        ]
        let candidate = tool("list_issues")
        let runtimes: [UUID: MCPServerRuntime] = [
            disconnectedID: MCPServerRuntime(status: .disconnected, tools: []),
            disabledID: MCPServerRuntime(status: .connected(toolCount: 1), tools: [candidate]),
            emptyID: MCPServerRuntime(status: .connected(toolCount: 1), tools: [candidate]),
        ]

        XCTAssertTrue(AddCardsSection.build(servers: servers, runtimes: runtimes).isEmpty)
    }

    func testBoundToolsSurviveEligibilityAndReport() {
        let id = UUID()
        let server = config(id: id, allowed: ["my_issues"], bound: ["my_issues"])
        let runtime = MCPServerRuntime(
            status: .connected(toolCount: 1), tools: [tool("my_issues")])

        let sections = AddCardsSection.build(servers: [server], runtimes: [id: runtime])

        XCTAssertEqual(sections.first?.boundTools, ["my_issues"])
    }

    // MARK: Card-id round trip

    func testParseCardIdRoundTrips() {
        let serverID = UUID()
        let cardId = AddCardsView.cardId(serverID: serverID, tool: "list_issues")

        let parsed = MCPFeedSource.parseCardId(cardId)

        XCTAssertEqual(parsed?.serverID, serverID)
        XCTAssertEqual(parsed?.tool, "list_issues")
    }

    func testParseCardIdKeepsDotsInToolNames() {
        let serverID = UUID()
        let cardId = AddCardsView.cardId(serverID: serverID, tool: "linear.list.issues")

        XCTAssertEqual(MCPFeedSource.parseCardId(cardId)?.tool, "linear.list.issues")
    }

    func testParseCardIdRejectsForeignAndMalformedIds() {
        XCTAssertNil(MCPFeedSource.parseCardId("crypto.BTC"))
        XCTAssertNil(MCPFeedSource.parseCardId("mcp.not-a-uuid.tool"))
        XCTAssertNil(MCPFeedSource.parseCardId("mcp.\(UUID().uuidString)"))
        XCTAssertNil(MCPFeedSource.parseCardId("mcp.\(UUID().uuidString)."))
    }
}
