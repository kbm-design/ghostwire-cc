import XCTest

@testable import Ghostwire

/// GW-332 Phase 1. The fixtures mirror the SHAPE of a real `~/.claude.json`
/// (dumped 2026-08-05 before the parser was written): heterogeneous sibling
/// keys, a `projects` map whose keys are absolute paths, entries with and
/// without `type`, and — the one that matters — most servers living under
/// `projects[*].mcpServers` rather than at the top level.
final class AgentMCPConfigImporterTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    private func write(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: tempURL)
    }

    private func discover(existing: [MCPServerConfig] = []) throws -> [DiscoveredMCPServer] {
        try AgentMCPConfigImporter.discover(claudeCodeConfigAt: tempURL, existing: existing)
    }

    // MARK: - THE gotcha: both maps

    func testWalksTopLevelAndProjectScopedServers() throws {
        try write([
            "numStartups": 412,  // unrelated sibling keys must not break the parse
            "mcpServers": [
                "qmd": ["type": "stdio", "command": "qmd", "args": ["mcp"]]
            ],
            "projects": [
                "/Users/someone": [
                    "hasTrustDialogAccepted": true,
                    "mcpServers": [
                        "playwright": [
                            "type": "stdio", "command": "npx", "args": ["@playwright/mcp@latest"],
                        ]
                    ],
                ],
                "/Users/someone/Code/app": [
                    "mcpServers": [
                        "railway": ["type": "stdio", "command": "npx", "args": ["@railway/mcp"]]
                    ]
                ],
                "/Users/someone/Code/no-servers": ["lastCost": 1.5],
            ],
        ])

        let found = try discover()
        XCTAssertEqual(Set(found.map(\.name)), ["qmd", "playwright", "railway"])
    }

    func testTopLevelOnlyWalkWouldMissMostServers() throws {
        // Regression guard stated as the failure it prevents: if `projects` is
        // ever dropped from the walk, this count falls to 1.
        try write([
            "mcpServers": ["a": ["command": "a"]],
            "projects": [
                "/p1": ["mcpServers": ["b": ["command": "b"]]],
                "/p2": ["mcpServers": ["c": ["command": "c"]]],
                "/p3": ["mcpServers": ["d": ["command": "d"]]],
            ],
        ])
        XCTAssertEqual(try discover().count, 4)
    }

    func testProjectScopeIsLabelledWithItsPath() throws {
        try write(["projects": ["/Users/someone/Code/app": ["mcpServers": ["a": ["command": "a"]]]]])
        XCTAssertEqual(try discover().first?.scopes, ["/Users/someone/Code/app"])
    }

    func testGlobalScopeIsLabelled() throws {
        try write(["mcpServers": ["a": ["command": "a"]]])
        XCTAssertEqual(try discover().first?.scopes, [AgentMCPConfigImporter.globalScopeLabel])
    }

    // MARK: - Dedupe is on signature, never on name

    func testSameServerInTwoScopesCollapsesAndUnionsScopes() throws {
        try write([
            "mcpServers": ["rive": ["type": "http", "url": "http://127.0.0.1:9791/mcp"]],
            "projects": [
                "/p1": ["mcpServers": ["rive": ["type": "http", "url": "http://127.0.0.1:9791/mcp"]]]
            ],
        ])
        let found = try discover()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].scopes, [AgentMCPConfigImporter.globalScopeLabel, "/p1"])
    }

    /// Real case: `figma-desktop` and `figma-dev-mode-mcp-server` are the same
    /// endpoint under two names in two projects.
    func testDifferentNamesSameEndpointAreOneServer() throws {
        try write([
            "projects": [
                "/p1": ["mcpServers": ["figma-desktop": ["type": "http", "url": "http://127.0.0.1:3845/mcp"]]],
                "/p2": [
                    "mcpServers": [
                        "figma-dev-mode-mcp-server": ["type": "http", "url": "http://127.0.0.1:3845/mcp"]
                    ]
                ],
            ]
        ])
        XCTAssertEqual(try discover().count, 1)
    }

    func testSameNameDifferentCommandAreTwoServers() throws {
        try write([
            "mcpServers": ["tool": ["command": "npx", "args": ["a"]]],
            "projects": ["/p1": ["mcpServers": ["tool": ["command": "npx", "args": ["b"]]]]],
        ])
        XCTAssertEqual(try discover().count, 2)
    }

    func testDedupesAgainstExistingStdioServerBySignatureNotName() throws {
        try write(["mcpServers": ["a-different-name": ["command": "npx", "args": ["-y", "@x/y"]]]])
        let existing = MCPServerConfig(
            id: UUID(), name: "Totally Unrelated Name",
            transport: .stdio(command: "npx", arguments: ["-y", "@x/y"], environmentKeys: []))
        XCTAssertEqual(try discover(existing: [existing]).first?.blocker, .alreadyAdded)
    }

    func testDedupesAgainstExistingHTTPServerIgnoringTrailingSlashAndCase() throws {
        try write(["mcpServers": ["x": ["type": "http", "url": "HTTPS://MCP.Example.com/mcp/"]]])
        let existing = MCPServerConfig(
            id: UUID(), name: "y",
            transport: .http(endpoint: URL(string: "https://mcp.example.com/mcp")!))
        XCTAssertEqual(try discover(existing: [existing]).first?.blocker, .alreadyAdded)
    }

    func testMatchingNameButDifferentCommandIsNotDeduped() throws {
        try write(["mcpServers": ["same": ["command": "npx", "args": ["-y", "@new/server"]]]])
        let existing = MCPServerConfig(
            id: UUID(), name: "same",
            transport: .stdio(command: "npx", arguments: ["-y", "@old/server"], environmentKeys: []))
        XCTAssertNil(try discover(existing: [existing]).first?.blocker)
    }

    // MARK: - Credentials baked into the command line

    /// Verified live: a real config had
    /// `npx -y @supabase/mcp-server-supabase@latest --access-token sbp_…`.
    /// Args are part of `commandSignature`, which IS persisted — importing this
    /// would put the token in `mcp-servers.json`.
    func testCredentialInArgsBlocksImport() throws {
        try write([
            "mcpServers": [
                "supabase": [
                    "command": "npx",
                    "args": ["-y", "@supabase/mcp-server-supabase@latest", "--access-token", "sbp_secret"],
                ]
            ]
        ])
        XCTAssertEqual(
            try discover().first?.blocker, .credentialInCommandLine(flag: "--access-token"))
    }

    func testCredentialInEqualsFormBlocksImport() throws {
        try write(["mcpServers": ["s": ["command": "srv", "args": ["--api-key=abc123"]]]])
        XCTAssertEqual(try discover().first?.blocker, .credentialInCommandLine(flag: "--api-key"))
    }

    func testOrdinaryFlagsAreNotMistakenForCredentials() throws {
        // A false positive hides a working server, so the detector matches flag
        // NAMES rather than guessing at value shapes.
        try write([
            "mcpServers": [
                "s": ["command": "srv", "args": ["--port", "8080", "--verbose", "--key-format", "pem"]]
            ]
        ])
        XCTAssertNil(try discover().first?.blocker)
    }

    func testCredentialFlagWithNoValueIsNotBlocked() throws {
        try write(["mcpServers": ["s": ["command": "srv", "args": ["--token"]]]])
        XCTAssertNil(try discover().first?.blocker)
    }

    func testCredentialFlagFollowedByAnotherFlagIsNotBlocked() throws {
        try write(["mcpServers": ["s": ["command": "srv", "args": ["--token", "--stdio"]]]])
        XCTAssertNil(try discover().first?.blocker)
    }

    func testCredentialsInEndpointBlockImport() throws {
        try write(["mcpServers": ["s": ["type": "http", "url": "https://user:pw@example.com/mcp"]]])
        XCTAssertEqual(try discover().first?.blocker, .credentialInEndpoint)
    }

    // MARK: - Self-reference

    func testGhostwireOwnServeEntryIsBlocked() throws {
        try write([
            "mcpServers": [
                MCPServeRegistration.serverName: [
                    "command": "/Applications/Ghostwire.app/Contents/MacOS/Ghostwire",
                    "args": [MCPServeRegistration.serveArgument],
                ]
            ]
        ])
        XCTAssertEqual(try discover().first?.blocker, .selfReference)
    }

    func testGhostwireGatewayEntryIsBlocked() throws {
        try write([
            "mcpServers": [
                GatewayRegistration.serverName: [
                    "type": "http", "url": "http://127.0.0.1:51762/mcp",
                    "headers": ["Authorization": "Bearer gw-token"],
                ]
            ]
        ])
        XCTAssertEqual(try discover().first?.blocker, .selfReference)
    }

    func testRenamedGhostwireServeEntryIsStillBlockedByItsCommand() throws {
        try write([
            "mcpServers": [
                "my-notch": [
                    "command": "/Applications/Ghostwire.app/Contents/MacOS/Ghostwire",
                    "args": ["mcp-serve"],
                ]
            ]
        ])
        XCTAssertEqual(try discover().first?.blocker, .selfReference)
    }

    // MARK: - Transport inference & malformed entries

    func testTypeIsOptional_commandImpliesStdio() throws {
        try write(["mcpServers": ["s": ["command": "srv", "args": ["x"]]]])
        XCTAssertEqual(try discover().first?.transport, .stdio(command: "srv", arguments: ["x"]))
    }

    func testTypeIsOptional_urlImpliesHTTP() throws {
        try write(["mcpServers": ["s": ["url": "https://example.com/mcp"]]])
        XCTAssertEqual(
            try discover().first?.transport, .http(endpoint: URL(string: "https://example.com/mcp")!))
    }

    func testSSETypeMapsToHTTPTransport() throws {
        try write(["mcpServers": ["s": ["type": "sse", "url": "https://example.com/sse"]]])
        guard case .http = try XCTUnwrap(discover().first).transport else {
            return XCTFail("sse should map to the http transport")
        }
    }

    func testEntryWithNeitherCommandNorURLIsSkipped() throws {
        try write(["mcpServers": ["broken": ["type": "stdio"]]])
        XCTAssertTrue(try discover().isEmpty)
    }

    /// Dropping a non-string arg would change the command line, so the whole
    /// entry is skipped rather than silently rewritten.
    func testNonStringArgumentsSkipTheEntry() throws {
        try write(["mcpServers": ["s": ["command": "srv", "args": ["ok", 42]]]])
        XCTAssertTrue(try discover().isEmpty)
    }

    func testMissingArgsMeansNoArguments() throws {
        try write(["mcpServers": ["s": ["command": "srv"]]])
        XCTAssertEqual(try discover().first?.transport, .stdio(command: "srv", arguments: []))
    }

    func testUnreadableFileThrows() {
        XCTAssertThrowsError(try discover()) { error in
            XCTAssertEqual(error as? AgentMCPConfigImporter.DiscoveryError, .unreadable)
        }
    }

    func testMalformedJSONThrows() throws {
        try Data("not json".utf8).write(to: tempURL)
        XCTAssertThrowsError(try discover()) { error in
            XCTAssertEqual(error as? AgentMCPConfigImporter.DiscoveryError, .malformed)
        }
    }

    func testEmptyConfigYieldsNothing() throws {
        try write(["numStartups": 1])
        XCTAssertTrue(try discover().isEmpty)
    }

    // MARK: - Secrets are carried out-of-band

    func testEnvValuesAreCapturedSeparatelyFromKeys() throws {
        try write([
            "mcpServers": [
                "railway": [
                    "command": "npx", "args": ["@railway/mcp"],
                    "env": ["RAILWAY_API_TOKEN": "rw_live_secret"],
                ]
            ]
        ])
        let found = try XCTUnwrap(discover().first)
        XCTAssertEqual(found.environment, ["RAILWAY_API_TOKEN": "rw_live_secret"])
        // The transport — the part that gets persisted — names the key only.
        XCTAssertEqual(found.transport, .stdio(command: "npx", arguments: ["@railway/mcp"]))
    }

    func testBearerHeaderBecomesBearerAuthWithSchemeStripped() throws {
        try write([
            "mcpServers": [
                "s": [
                    "type": "http", "url": "https://example.com/mcp",
                    "headers": ["Authorization": "Bearer abc123"],
                ]
            ]
        ])
        let found = try XCTUnwrap(discover().first)
        XCTAssertEqual(found.httpAuth, .bearer)
        // Keeping the prefix would send "Bearer Bearer abc123".
        XCTAssertEqual(found.httpAuthToken, "abc123")
    }

    func testCustomAuthHeaderBecomesNamedHeaderAuth() throws {
        try write([
            "mcpServers": [
                "s": ["type": "http", "url": "https://example.com/mcp", "headers": ["x-api-key": "k1"]]
            ]
        ])
        let found = try XCTUnwrap(discover().first)
        XCTAssertEqual(found.httpAuth, .header(name: "x-api-key"))
        XCTAssertEqual(found.httpAuthToken, "k1")
    }

    func testUnrepresentableHeadersAreReportedNotDropped() throws {
        try write([
            "mcpServers": [
                "s": [
                    "type": "http", "url": "https://example.com/mcp",
                    "headers": ["Authorization": "Bearer t", "X-Tenant": "acme"],
                ]
            ]
        ])
        XCTAssertEqual(try discover().first?.unmappedHeaderNames, ["X-Tenant"])
    }

    func testHTTPServerWithNoHeadersUsesDynamicRegistration() throws {
        try write(["mcpServers": ["s": ["type": "http", "url": "https://example.com/mcp"]]])
        let found = try XCTUnwrap(discover().first)
        XCTAssertNil(found.httpAuth)  // nil = DCR, the GW-291 default
        XCTAssertNil(found.httpAuthToken)
    }

    // MARK: - Ordering

    func testImportableServersSortAboveBlockedOnes() throws {
        try write([
            "mcpServers": [
                "aaa-blocked": ["command": "srv", "args": ["--token", "x"]],
                "zzz-fine": ["command": "srv2"],
            ]
        ])
        let found = try discover()
        XCTAssertEqual(found.map(\.name), ["zzz-fine", "aaa-blocked"])
    }
}
