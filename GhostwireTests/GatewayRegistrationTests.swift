//
//  GatewayRegistrationTests.swift
//  GhostwireTests
//
//  GW-253 Phase 2: the copyable command that registers the localhost gateway
//  with a host agent over HTTP, carrying the bearer token.
//
//  GW-350 changed the expected string: the original omitted `--scope user`, so
//  the command registered into project/local scope keyed to whatever directory
//  the user happened to run it from. This test previously pinned that bug.
//

import XCTest

@testable import Ghostwire

final class GatewayRegistrationTests: XCTestCase {
    func testClaudeCodeHTTPRegisterCommand() {
        let cmd = GatewayRegistration.claudeCommand(
            endpointURL: "http://127.0.0.1:51762/mcp", token: "abc123")
        XCTAssertEqual(
            cmd,
            "claude mcp add --transport http --scope user ghostwire-gateway "
                + "http://127.0.0.1:51762/mcp --header \"Authorization: Bearer abc123\"")
    }

    /// The whole point of GW-350. `claude mcp add` defaults to `local` — a
    /// project config keyed to the process cwd — so a command run from the
    /// wrong directory lands outside `~/.claude.json` and is invisible in every
    /// real project. This is the likely origin of the orphaned project-scoped
    /// registration GW-308 hit.
    func testCommandRegistersIntoUserScope() {
        let cmd = GatewayRegistration.claudeCommand(
            endpointURL: "http://127.0.0.1:51762/mcp", token: "t")
        XCTAssertTrue(cmd.contains("--scope user"), "must not fall back to the CLI's local default")
    }

    /// GW-350 minor: the name was declared twice, so the name the server
    /// advertises and the name the command registers could drift apart.
    func testServerNameHasOneDefinition() {
        XCTAssertEqual(GatewayServer.serverName, GatewayRegistration.serverName)
    }
}

// MARK: - GW-351

final class GatewayRegistrationAuditTests: XCTestCase {
    private func write(_ json: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return url
    }

    private func entry(token: String) -> [String: Any] {
        [
            "type": "http",
            "url": "http://127.0.0.1:51762/mcp",
            "headers": ["Authorization": "Bearer \(token)"],
        ]
    }

    func testMissingConfigIsNotRegisteredRatherThanStale() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        XCTAssertEqual(
            GatewayRegistrationAudit.status(liveToken: "live", configURL: missing), .notRegistered)
    }

    func testMatchingUserScopedTokenIsCurrent() throws {
        let url = try write([
            "mcpServers": [GatewayRegistration.serverName: entry(token: "live")]
        ])
        XCTAssertEqual(
            GatewayRegistrationAudit.status(liveToken: "live", configURL: url),
            .current(scopes: ["user"]))
    }

    func testStaleTokenIsReportedWithItsScope() throws {
        let url = try write([
            "mcpServers": [GatewayRegistration.serverName: entry(token: "old")]
        ])
        XCTAssertEqual(
            GatewayRegistrationAudit.status(liveToken: "live", configURL: url),
            .stale(scopes: ["user"]))
    }

    /// The exact shape GW-350 found on a real machine: a working user-scoped
    /// entry AND a stale project-scoped leftover. A single "does it match"
    /// answer would call this healthy while the project entry keeps 401ing.
    func testStaleProjectScopedEntryWinsOverAHealthyUserScopedOne() throws {
        let url = try write([
            "mcpServers": [GatewayRegistration.serverName: entry(token: "live")],
            "projects": [
                "/Users/someone": [
                    "mcpServers": [GatewayRegistration.serverName: entry(token: "old")]
                ]
            ],
        ])
        let status = GatewayRegistrationAudit.status(liveToken: "live", configURL: url)
        XCTAssertEqual(status, .stale(scopes: ["/Users/someone"]))
        XCTAssertTrue(status.needsReconnect)
    }

    func testConfigWithoutOurServerIsNotRegistered() throws {
        let url = try write(["mcpServers": ["something-else": entry(token: "live")]])
        XCTAssertEqual(
            GatewayRegistrationAudit.status(liveToken: "live", configURL: url), .notRegistered)
    }

    /// Header names are case-insensitive per RFC 9110, and the CLI writes
    /// whatever the user typed.
    func testAuthorizationHeaderMatchIsCaseInsensitive() {
        let parsed = GatewayRegistrationAudit.bearerToken(
            from: ["headers": ["authorization": "bearer abc123"]])
        XCTAssertEqual(parsed, "abc123")
    }

    /// A malformed sibling key must not fail the whole read — the file is
    /// ~185KB of unrelated client state whose shape drifts release to release.
    func testUnrelatedKeysAreIgnored() throws {
        let url = try write([
            "numStartups": 412,
            "tipsHistory": ["x": 1],
            "mcpServers": [GatewayRegistration.serverName: entry(token: "live")],
        ])
        XCTAssertEqual(
            GatewayRegistrationAudit.status(liveToken: "live", configURL: url),
            .current(scopes: ["user"]))
    }

    /// An empty live token means the gateway hasn't minted one yet; comparing
    /// against it would flag every registration as stale.
    func testEmptyLiveTokenNeverReportsStale() throws {
        let url = try write([
            "mcpServers": [GatewayRegistration.serverName: entry(token: "old")]
        ])
        XCTAssertEqual(
            GatewayRegistrationAudit.status(liveToken: "", configURL: url), .notRegistered)
    }
}
