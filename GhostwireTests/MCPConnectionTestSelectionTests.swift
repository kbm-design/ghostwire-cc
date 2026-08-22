import XCTest

@testable import Ghostwire

/// Which tool the drill-in's "Test connection" calls.
///
/// Pinned because getting it wrong produces the WORST kind of failure: a red
/// "Failed" on a connection that works. Codex caught exactly that (P2,
/// 2026-08-21) — the rule fell back to an un-allowlisted tool, which
/// `callAllowedTool` rejects before it ever reaches the network, so every
/// freshly connected server (allowlist empty by default) failed its own test.
@MainActor
final class MCPConnectionTestSelectionTests: XCTestCase {

    private func tool(
        _ name: String, readOnly: Bool? = nil, destructive: Bool? = nil,
        required: [String] = []
    ) -> MCPToolInfo {
        MCPToolInfo(
            name: name, description: nil, hasOutputSchema: false,
            isReadOnlyHinted: readOnly, isDestructiveHinted: destructive,
            requiredInputs: required)
    }

    private func pick(_ tools: [MCPToolInfo], allowed: Set<String>) -> MCPToolInfo? {
        MCPServerDetailView.testableTool(tools: tools, allowed: allowed, serverName: "Linear")
    }

    /// THE regression. A connected server starts with an empty allowlist.
    func testNoToolIsOfferedWhenNothingIsAllowlisted() {
        let tools = [tool("list_issues", readOnly: true)]
        XCTAssertNil(
            pick(tools, allowed: []),
            "an un-allowed tool would be rejected by callAllowedTool and report a false failure")
    }

    func testPicksAnAllowlistedReadOnlyToolWithNoInputs() throws {
        let tools = [
            tool("delete_issue", readOnly: false, destructive: true),
            tool("get_issue", readOnly: true, required: ["id"]),
            tool("list_issues", readOnly: true),
        ]
        let picked = try XCTUnwrap(pick(tools, allowed: ["delete_issue", "get_issue", "list_issues"]))
        XCTAssertEqual(picked.name, "list_issues")
    }

    /// A test may never change anything, however convenient the tool.
    func testNeverPicksAMutatingTool() {
        let tools = [
            tool("create_issue", readOnly: false),
            tool("delete_all", readOnly: false, destructive: true),
        ]
        XCTAssertNil(pick(tools, allowed: ["create_issue", "delete_all"]))
    }

    /// `testConnection` sends `[:]`, so a tool needing input can only answer
    /// "Invalid arguments" — which says nothing about the connection.
    func testNeverPicksAToolThatRequiresInput() {
        let tools = [tool("get_issue_status", readOnly: true, required: ["id", "team"])]
        XCTAssertNil(pick(tools, allowed: ["get_issue_status"]))
    }

    /// Servers that annotate nothing still get a test — the classifier infers
    /// read-only from the verb, and the user has already allowlisted it.
    func testInferredReadOnlyCounts() throws {
        let tools = [tool("list_issues")]
        let picked = try XCTUnwrap(pick(tools, allowed: ["list_issues"]))
        XCTAssertEqual(picked.name, "list_issues")
    }

    /// An unclassifiable tool is not a safe tool.
    func testUnclassifiableToolIsNotOffered() {
        XCTAssertNil(pick([tool("mystery")], allowed: ["mystery"]))
    }
}
