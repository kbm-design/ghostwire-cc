//
//  MCPServeRegistrationTests.swift
//  GhostwireTests
//
//  GW-173: the per-agent registration builders. Agent-agnostic server; only
//  the registration string/command differs per agent.
//

import XCTest

@testable import Ghostwire

final class MCPServeRegistrationTests: XCTestCase {
    private let exe = "/Applications/Ghostwire.app/Contents/MacOS/Ghostwire"

    func testClaudeAddArguments() {
        XCTAssertEqual(
            MCPServeRegistration.claudeAddArguments(executable: exe),
            ["mcp", "add", "ghostwire", "--", exe, "mcp-serve"])
    }

    func testClaudeCommandStringIsCopyPasteable() {
        let command = MCPServeRegistration.claudeCommandString(executable: exe)
        XCTAssertTrue(command.hasPrefix("claude mcp add ghostwire -- "))
        XCTAssertTrue(command.contains("mcp-serve"))
    }

    func testJSONSnippetShape() {
        let json = MCPServeRegistration.jsonSnippet(executable: exe)
        XCTAssertTrue(json.contains("\"mcpServers\""))
        XCTAssertTrue(json.contains("\"ghostwire\""))
        XCTAssertTrue(json.contains("\"args\": [\"mcp-serve\"]"))
        // Valid JSON.
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    func testTOMLSnippetShape() {
        let toml = MCPServeRegistration.tomlSnippet(executable: exe)
        XCTAssertTrue(toml.contains("[mcp_servers.ghostwire]"))
        XCTAssertTrue(toml.contains("command = "))
        XCTAssertTrue(toml.contains("args = [\"mcp-serve\"]"))
    }

    func testTargetsCoverFourAgents() {
        let ids = MCPServeRegistration.targets().map(\.id)
        XCTAssertEqual(Set(ids), ["claude", "claude-desktop", "cursor", "codex"])
    }

    func testExecutablePathContainsArgsArrayEvenWithSpaces() {
        let spaced = "/Applications/My Apps/Ghostwire.app/Contents/MacOS/Ghostwire"
        let json = MCPServeRegistration.jsonSnippet(executable: spaced)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(json.utf8)))
    }
}
