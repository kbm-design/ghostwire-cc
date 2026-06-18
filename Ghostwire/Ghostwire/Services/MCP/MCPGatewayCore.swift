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
                let exposedName = "\(slug)_\(tool.name)"
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
}
