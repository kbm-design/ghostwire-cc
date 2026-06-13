//
//  MCPServeRegistration.swift
//  Ghostwire
//
//  GW-173: how to register the Shelf context-hub server (`mcp-serve`) with each
//  agent. The SERVER is agent-agnostic — MCP over stdio is identical for every
//  client; only the registration entry differs.
//
//  TRUST POSTURE: the app NEVER writes an agent's config. It only DISPLAYS the
//  stdio entry (a `claude mcp add` command for Claude Code, a config snippet for
//  the rest) and the user adds it themselves — the same model as Obsidian's MCP
//  and most others. A freshly-downloaded app mutating ~/.claude.json is exactly
//  the kind of capability we don't want to own.
//
//  One code path for every agent (mirrors AgentHookConfig): adding an agent =
//  appending one `MCPServeTarget`.
//

import Foundation

struct MCPServeTarget: Identifiable, Sendable {
    enum Method: Sendable {
        /// A shell command the user copies and runs (Claude Code's `claude mcp add`).
        case command(String)
        /// A config block the user pastes into `configPath`.
        case snippet(String)
    }

    let id: String
    let displayName: String
    /// Human-readable location of the agent's MCP config (for the UI).
    let configPath: String
    let method: Method
}

enum MCPServeRegistration {
    /// Absolute path to the running app's executable — what each agent spawns.
    static var executablePath: String {
        Bundle.main.executablePath
            ?? "/Applications/Ghostwire.app/Contents/MacOS/Ghostwire"
    }

    static let serverName = MCPServeRuntime.serverName  // "ghostwire"
    static let serveArgument = "mcp-serve"

    // MARK: - Per-agent targets (one code path)

    static func targets() -> [MCPServeTarget] {
        let exe = executablePath
        return [
            MCPServeTarget(
                id: "claude",
                displayName: "Claude Code",
                configPath: "~/.claude.json",
                method: .command(claudeCommandString(executable: exe))
            ),
            MCPServeTarget(
                id: "claude-desktop",
                displayName: "Claude Desktop",
                configPath: "~/Library/Application Support/Claude/claude_desktop_config.json",
                method: .snippet(jsonSnippet(executable: exe))
            ),
            MCPServeTarget(
                id: "cursor",
                displayName: "Cursor",
                configPath: "~/.cursor/mcp.json",
                method: .snippet(jsonSnippet(executable: exe))
            ),
            MCPServeTarget(
                id: "codex",
                displayName: "Codex",
                configPath: "~/.codex/config.toml",
                method: .snippet(tomlSnippet(executable: exe))
            ),
        ]
    }

    // MARK: - Pure builders (testable)

    /// Arguments to `claude` for
    /// `claude mcp add --scope user ghostwire -- <exe> mcp-serve`.
    /// `--scope user` is required: the CLI defaults to `local` (project config
    /// keyed to the process cwd), so a registration run from the wrong directory
    /// would land outside `~/.claude.json` and be invisible in real projects.
    static func claudeAddArguments(executable: String) -> [String] {
        ["mcp", "add", "--scope", "user", serverName, "--", executable, serveArgument]
    }

    /// The full copyable command the user runs themselves.
    static func claudeCommandString(executable: String) -> String {
        (["claude"] + claudeAddArguments(executable: executable))
            .map { $0.contains(" ") ? "\"\($0)\"" : $0 }
            .joined(separator: " ")
    }

    /// `mcpServers` JSON block (Claude Desktop, Cursor).
    static func jsonSnippet(executable: String) -> String {
        """
        {
          "mcpServers": {
            "\(serverName)": {
              "command": "\(jsonEscaped(executable))",
              "args": ["\(serveArgument)"]
            }
          }
        }
        """
    }

    /// `[mcp_servers.*]` TOML block (Codex).
    static func tomlSnippet(executable: String) -> String {
        """
        [mcp_servers.\(serverName)]
        command = "\(tomlEscaped(executable))"
        args = ["\(serveArgument)"]
        """
    }

    // MARK: - Escaping

    private static func jsonEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func tomlEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
