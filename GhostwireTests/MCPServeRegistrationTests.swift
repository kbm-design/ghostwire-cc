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
            ["mcp", "add", "--scope", "user", "ghostwire", "--", exe, "mcp-serve"])
    }

    func testClaudeCommandStringIsCopyPasteable() {
        let command = MCPServeRegistration.claudeCommandString(executable: exe)
        XCTAssertTrue(command.hasPrefix("claude mcp add --scope user ghostwire -- "))
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

    func testCodexAddArguments() {
        XCTAssertEqual(
            MCPServeRegistration.codexAddArguments(executable: exe),
            ["mcp", "add", "ghostwire", "--", exe, "mcp-serve"])
    }

    func testCodexCommandStringIsCopyPasteable() {
        let command = MCPServeRegistration.codexCommandString(executable: exe)
        XCTAssertTrue(command.hasPrefix("codex mcp add ghostwire -- "))
        XCTAssertTrue(command.contains("mcp-serve"))
    }

    func testTargetsSurfaceClaudeAndCodexAsCommands() {
        let targets = MCPServeRegistration.targets()
        // Only the two CLI agents are shown today, Codex right under Claude Code.
        XCTAssertEqual(targets.map(\.id), ["claude", "codex"])
        for target in targets {
            guard case .command = target.method else {
                return XCTFail("\(target.id) should register via a copyable command")
            }
        }
    }

    func testExecutablePathContainsArgsArrayEvenWithSpaces() {
        let spaced = "/Applications/My Apps/Ghostwire.app/Contents/MacOS/Ghostwire"
        let json = MCPServeRegistration.jsonSnippet(executable: spaced)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(json.utf8)))
    }
}
