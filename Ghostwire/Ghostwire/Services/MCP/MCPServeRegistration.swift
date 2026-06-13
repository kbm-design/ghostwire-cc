//
//  MCPServeRegistration.swift
//  Ghostwire
//
//  GW-173: register the Shelf context-hub server (the `mcp-serve` subcommand)
//  with each agent. The SERVER is agent-agnostic — MCP over stdio is identical
//  for every client. Only the *registration* differs: where the entry goes.
//
//  One code path for every agent (mirrors AgentHookConfig): adding an agent =
//  appending one `MCPServeTarget`. Claude Code has a CLI (`claude mcp add`), so
//  we can write its entry on an explicit click; the rest get a copy-paste
//  config snippet. We never edit a config file without a user action.
//

import Foundation

struct MCPServeTarget: Identifiable, Sendable {
    enum Method: Sendable {
        /// Runnable CLI that writes the agent's config (argument vector after the tool name).
        case cli(tool: String, arguments: [String])
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
                method: .cli(tool: "claude", arguments: claudeAddArguments(executable: exe))
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
    /// keyed to the process cwd), so a GUI-launched registration would land in
    /// the app bundle's directory instead of `~/.claude.json` and be invisible
    /// in the user's real projects.
    static func claudeAddArguments(executable: String) -> [String] {
        ["mcp", "add", "--scope", "user", serverName, "--", executable, serveArgument]
    }

    /// The full copyable command for manual setup / docs.
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

    // MARK: - Claude CLI execution (user-initiated)

    enum RegistrationError: LocalizedError {
        case toolNotFound(String)
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .toolNotFound(let tool):
                return "Couldn't find the `\(tool)` CLI on your PATH. Install it, or use the copyable command instead."
            case .failed(let output):
                return output.isEmpty ? "Registration failed." : output
            }
        }
    }

    /// Run `claude mcp add …` using the user's login-shell PATH (GW-219's
    /// resolver — GUI apps inherit launchd's minimal PATH). User-initiated only.
    @discardableResult
    static func registerWithClaude() async throws -> String {
        let exe = executablePath
        guard let claudePath = await LoginShellPATHResolver.shared.resolve(command: "claude") else {
            throw RegistrationError.toolNotFound("claude")
        }
        return try await run(executable: claudePath, arguments: claudeAddArguments(executable: exe))
    }

    private static func run(executable: String, arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw RegistrationError.failed([out, err].filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        return out.isEmpty ? "Registered Ghostwire with Claude Code." : out
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
