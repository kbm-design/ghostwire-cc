//
//  GatewayRegistration.swift
//  Ghostwire
//
//  GW-253 Phase 2: the copyable command that registers the localhost gateway
//  with a host agent over HTTP. Claude Code (and MCP Inspector via URL+header)
//  connect on-device, no tunnel. The bearer token guards the endpoint.
//

import Foundation

enum GatewayRegistration {
    static let serverName = "ghostwire-gateway"

    /// `claude mcp add --transport http ghostwire-gateway <url> --header "Authorization: Bearer <token>"`
    static func claudeCommand(endpointURL: String, token: String) -> String {
        "claude mcp add --transport http \(serverName) \(endpointURL) "
            + "--header \"Authorization: Bearer \(token)\""
    }
}
