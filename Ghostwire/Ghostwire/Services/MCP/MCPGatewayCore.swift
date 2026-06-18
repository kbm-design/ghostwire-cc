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

enum GatewayError: Error, Equatable {
    /// The host called an exposed name that resolves to no downstream tool.
    case unknownTool(String)
}

/// Maps an exposed (namespaced) tool name back to its downstream server + the
/// downstream's own tool name.
struct GatewayRoute: Sendable {
    let serverID: UUID
    let originalName: String
}

/// The gateway's merged tool surface plus the routing table behind it.
struct GatewayExposure: Sendable {
    let tools: [Tool]
    let routes: [String: GatewayRoute]
}

struct MCPGatewayCore: Sendable {
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

    /// Resolve an exposed name to its downstream and forward the call. Rebuilds
    /// the route map per call (stateless probe) — caching the exposure is a
    /// Phase-2 refinement once the gateway is hosted behind a transport.
    func call(exposedName: String, arguments: [String: Value]?) async throws -> MCPToolCallOutput {
        let routes = await buildExposure().routes
        guard let route = routes[exposedName] else {
            throw GatewayError.unknownTool(exposedName)
        }
        return try await source.call(
            serverID: route.serverID, tool: route.originalName, arguments: arguments)
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
