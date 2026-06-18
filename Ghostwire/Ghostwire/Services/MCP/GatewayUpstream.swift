//
//  GatewayUpstream.swift
//  Ghostwire
//
//  GW-253: the gateway's upstream seam. The gateway re-exposes the user's
//  connected downstream MCP servers (held + authed in the notch) under a
//  per-server namespace. This file owns the namespacing slug and — as the
//  engine grows — the source protocol the core reads from.
//
//  Slugs are underscore-free on purpose: Gemini CLI splits the tool FQN on
//  underscores (`mcp_{server}_{tool}`), so an underscore in the server slug
//  breaks its allowlist/policy parser.
//

import Foundation
import MCP

/// Derives a host-safe, underscore-free namespace prefix from a server name.
enum GatewaySlug {
    static func slugify(_ name: String) -> String {
        let filtered = name.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return filtered.isEmpty ? "server" : filtered
    }
}

/// One connected downstream server's contribution to the gateway: its identity
/// plus the full SDK `Tool`s (with `inputSchema`) the user has allowlisted.
struct GatewayUpstreamServer: Sendable {
    let id: UUID
    let displayName: String
    let tools: [Tool]
}

/// What the gateway core reads from. Faked in tests; backed by
/// `MCPClientService` in production (a later task). `servers()` yields only
/// connected, allowlisted tools; `call` forwards to the real downstream.
/// Sendable so the core can run behind the SDK's `@Sendable` server handlers.
protocol GatewayUpstreamSource: Sendable {
    func servers() async -> [GatewayUpstreamServer]
    func call(serverID: UUID, tool: String, arguments: [String: Value]?) async throws
        -> MCPToolCallOutput
}
