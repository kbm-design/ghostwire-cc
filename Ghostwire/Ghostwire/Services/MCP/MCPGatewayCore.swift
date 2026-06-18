//
//  MCPGatewayCore.swift
//  Ghostwire
//
//  GW-253: the gateway engine. Reads the user's connected downstream servers
//  from a `GatewayUpstreamSource`, re-exposes their allowlisted tools under a
//  per-server namespace (`‹slug›_‹tool›`) with `inputSchema` forwarded intact,
//  and routes a call back to the right downstream by the exposed name.
//
//  Pure (no transport, no UI). The host gates tool calls — the gateway never
//  does; native-passthrough means the client's per-tool permission applies.
//

import Foundation
import MCP

/// Maps an exposed (namespaced) tool name back to its downstream server + the
/// downstream's own tool name.
struct GatewayRoute {
    let serverID: UUID
    let originalName: String
}

/// The gateway's merged tool surface plus the routing table behind it.
struct GatewayExposure {
    let tools: [Tool]
    let routes: [String: GatewayRoute]
}

struct MCPGatewayCore {
    let source: GatewayUpstreamSource

    init(source: GatewayUpstreamSource) {
        self.source = source
    }

    /// Enumerate downstreams and build the namespaced exposure + route map.
    func buildExposure() async -> GatewayExposure {
        var tools: [Tool] = []
        var routes: [String: GatewayRoute] = [:]
        for server in await source.servers() {
            let slug = GatewaySlug.slugify(server.displayName)
            for tool in server.tools {
                let exposedName = Self.uniqueName("\(slug)_\(tool.name)", taken: routes)
                tools.append(
                    Tool(
                        name: exposedName,
                        description: tool.description,
                        inputSchema: tool.inputSchema,
                        annotations: tool.annotations
                    ))
                routes[exposedName] = GatewayRoute(serverID: server.id, originalName: tool.name)
            }
        }
        return GatewayExposure(tools: tools, routes: routes)
    }

    /// Disambiguate exposed names that collide across servers (e.g. two
    /// servers that slug identically and share a tool name) by suffixing
    /// `_2`, `_3`, … — never let a later tool overwrite an earlier route.
    private static func uniqueName(_ base: String, taken routes: [String: GatewayRoute]) -> String {
        guard routes[base] != nil else { return base }
        var n = 2
        while routes["\(base)_\(n)"] != nil { n += 1 }
        return "\(base)_\(n)"
    }
}
