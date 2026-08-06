//
//  GatewayRegistration.swift
//  Ghostwire
//
//  GW-253 Phase 2: the copyable command that registers the localhost gateway
//  with a host agent over HTTP. Claude Code (and MCP Inspector via URL+header)
//  connect on-device, no tunnel. The bearer token guards the endpoint.
//
//  GW-350: this was dead code — nothing called it — and the command it would
//  have emitted was missing `--scope user`. Both fixed here; GW-255 gives it
//  the surface.
//

import Foundation

enum GatewayRegistration {
    /// The one definition. `GatewayServer` used to declare its own copy, so the
    /// name the server advertises and the name the command registers could
    /// drift apart silently (GW-350).
    static let serverName = "ghostwire-gateway"

    /// `claude mcp add --transport http --scope user ghostwire-gateway <url> --header "…"`
    ///
    /// **`--scope user` is required.** The CLI defaults to `local` — project
    /// config keyed to the process cwd — so a command run from the wrong
    /// directory lands outside `~/.claude.json` and is invisible in every real
    /// project. `MCPServeRegistration.claudeAddArguments` already does this;
    /// the gateway's copy didn't, which is the likely origin of the orphaned
    /// project-scoped registration in GW-308.
    static func claudeCommand(endpointURL: String, token: String) -> String {
        "claude mcp add --transport http --scope user \(serverName) \(endpointURL) "
            + "--header \"Authorization: Bearer \(token)\""
    }
}
