//
//  MCPServerConfig.swift
//  Ghostwire
//
//  GW-219: persisted configuration for one external MCP server.
//  NCC's OWN config — separate from agent configs. Never holds secret
//  values: env entries are key NAMES whose values live in the Keychain.
//

import Foundation

enum MCPTransportConfig: Codable, Equatable {
    /// Spawn a local server process. `environmentKeys` are the names of env
    /// vars to inject at spawn; their values are stored in the Keychain
    /// (service com.ghostwire.mcp, account "env.<serverID>.<KEY>").
    case stdio(command: String, arguments: [String], environmentKeys: [String])
    /// Hosted server over Streamable HTTP (SSE when streaming).
    case http(endpoint: URL)

    var displayBadge: String {
        switch self {
        case .stdio: return "stdio"
        case .http: return "http"
        }
    }
}

struct MCPProbeRecord: Codable, Equatable {
    var date: Date
    var toolCount: Int
    /// Tool names that declare an outputSchema (from tools/list — no call needed).
    var toolsWithOutputSchema: [String]
    /// Last debug-run result, if the user has run an allowed tool.
    var lastRunTool: String?
    var lastRunReturnedStructuredContent: Bool?
}

struct MCPServerConfig: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var transport: MCPTransportConfig
    /// Per-TOOL read-only allowlist. Default empty = default-deny.
    var allowedTools: Set<String> = []
    var isEnabled: Bool = true
    /// Trust gate for stdio (spawning = code execution). Holds the exact
    /// command signature the user approved; nil or mismatch = won't spawn.
    var trustedCommandSignature: String?
    /// Absolute executable path resolved at add-time against the login-shell PATH.
    var resolvedExecutablePath: String?
    var lastProbe: MCPProbeRecord?

    /// Canonical signature of what would be executed. Any edit to the
    /// command line changes this and invalidates prior trust.
    var commandSignature: String? {
        guard case .stdio(let command, let arguments, _) = transport else { return nil }
        return ([command] + arguments).joined(separator: "\u{1F}")
    }

    var isTrusted: Bool {
        switch transport {
        case .http: return true  // no code execution on our machine
        case .stdio: return trustedCommandSignature != nil && trustedCommandSignature == commandSignature
        }
    }
}
