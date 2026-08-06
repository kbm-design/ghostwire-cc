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

/// One search_tools hit: enough to call_tool it without a second round-trip.
struct GatewaySearchMatch: Codable, Sendable {
    let name: String
    let description: String
    let inputSchema: Value
}

/// Structured payload returned by search_tools.
struct GatewaySearchResult: Codable, Sendable {
    let count: Int
    let tools: [GatewaySearchMatch]
}

struct MCPGatewayCore: Sendable {
    let source: GatewayUpstreamSource
    let usage: ToolUsageRecording
    let config: WorkingSetConfig

    init(
        source: GatewayUpstreamSource,
        usage: ToolUsageRecording = ToolUsageStore.shared,
        config: WorkingSetConfig = .default
    ) {
        self.source = source
        self.usage = usage
        self.config = config
    }

    // MARK: - Meta tools

    static let searchToolName = "search_tools"
    static let callToolName = "call_tool"

    /// search_tools: ranks the full downstream catalog by a keyword query and
    /// returns the best matches (with input schemas) for tools not in the
    /// working set. Read-only.
    static var searchToolDefinition: Tool {
        Tool(
            name: searchToolName,
            description: """
                Search every connected MCP server for tools that are not in the working set. \
                Returns matching tool names with their input schemas; invoke one via call_tool.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Keywords matched against tool names and descriptions."),
                    ])
                ]),
                "required": .array([.string("query")]),
            ]),
            annotations: .init(readOnlyHint: true))
    }

    /// call_tool: invoke any exposed tool by name (e.g. one returned by
    /// search_tools), including tools outside the working set.
    static var callToolDefinition: Tool {
        Tool(
            name: callToolName,
            description: """
                Invoke any connected MCP tool by its exposed name (as returned by search_tools), \
                including tools that are not in the working set.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("The exposed tool name to invoke."),
                    ]),
                    "arguments": .object([
                        "type": .string("object"),
                        "description": .string("Arguments object forwarded to the downstream tool."),
                    ]),
                ]),
                "required": .array([.string("name")]),
            ]))
    }

    /// The bounded surface the host actually sees: the working set (recency ∪
    /// frequency) plus search_tools and call_tool. Recomputed per build; the
    /// full route map is retained so call_tool/search can still reach anything.
    ///
    /// Gating tradeoff (GW-184): tools outside the working set are reachable only
    /// via the generic `call_tool`, so a host that caches "always allow
    /// call_tool" loses per-tool approval for the long tail (working-set tools
    /// keep per-name host gating). This matches every major aggregator
    /// (Composio/Pipedream/Zapier/Klavis), which all relax host per-tool consent
    /// behind a generic execute tool and lean on server-side authz instead. Our
    /// authz floor is `MCPServerConfig.allowedTools` (default-deny): call_tool
    /// can only reach tools the user already allowlisted in the notch. Restoring
    /// granular gating for the long tail (pin sensitive tools to always-exposed,
    /// or notch-side per-call prompts) is a tracked fast-follow.
    func publicExposure() async -> GatewayExposure {
        let full = await buildExposure()
        let snapshot = await usage.snapshot()
        let catalog: [(name: String, serverID: UUID)] = full.tools.compactMap { tool in
            guard let route = full.routes[tool.name] else { return nil }
            return (tool.name, route.serverID)
        }
        let workingSet = Set(
            WorkingSetSelector.select(catalog: catalog, usage: snapshot, config: config))
        var tools = full.tools.filter { workingSet.contains($0.name) }
        tools.append(Self.searchToolDefinition)
        tools.append(Self.callToolDefinition)
        return GatewayExposure(tools: tools, routes: full.routes)
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
                        annotations: tool.annotations,
                        outputSchema: tool.outputSchema
                    ))
                routes[exposedName] = GatewayRoute(serverID: server.id, originalName: tool.name)
            }
        }
        return GatewayExposure(tools: tools, routes: routes)
    }

    /// Dispatch a host call. `search_tools` and `call_tool` are handled here;
    /// any other name is a direct working-set tool. Rebuilds the route map per
    /// call (stateless probe) — caching is a later refinement.
    func call(exposedName: String, arguments: [String: Value]?) async throws -> MCPToolCallOutput {
        switch exposedName {
        case Self.searchToolName:
            return await searchResult(query: arguments?["query"]?.stringValue ?? "")
        case Self.callToolName:
            guard let inner = arguments?["name"]?.stringValue else {
                throw GatewayError.unknownTool(Self.callToolName)
            }
            return try await route(exposedName: inner, arguments: arguments?["arguments"]?.objectValue)
        default:
            return try await route(exposedName: exposedName, arguments: arguments)
        }
    }

    /// Resolve an exposed name to its downstream, log the use (feeds the working
    /// set), and forward the call.
    private func route(exposedName: String, arguments: [String: Value]?) async throws
        -> MCPToolCallOutput {
        let routes = await buildExposure().routes
        guard let route = routes[exposedName] else {
            throw GatewayError.unknownTool(exposedName)
        }
        await usage.record(exposedName)
        return try await source.call(
            serverID: route.serverID, tool: route.originalName, arguments: arguments)
    }

    /// Rank the full catalog for `query` and return matches with schemas. Search
    /// is local — it never touches a downstream and is not counted as usage.
    private func searchResult(query: String) async -> MCPToolCallOutput {
        let catalog = await buildExposure().tools
        let hits = ToolSearch.search(query: query, catalog: catalog, limit: config.searchLimit)
        let summary = hits.isEmpty
            ? "No tools matched \"\(query)\". Try different keywords."
            : hits.map { "• \($0.name) — \($0.description ?? "")" }.joined(separator: "\n")
        let payload = GatewaySearchResult(
            count: hits.count,
            tools: hits.map {
                GatewaySearchMatch(
                    name: $0.name, description: $0.description ?? "", inputSchema: $0.inputSchema)
            })
        let result = (try? CallTool.Result(
            content: [.text(text: summary, annotations: nil, _meta: nil)],
            structuredContent: payload,
            isError: false))
            ?? CallTool.Result(content: [.text(text: summary, annotations: nil, _meta: nil)])
        return MCPToolCallOutput(result: result)
    }

    /// Names reserved for the gateway's own meta tools — a downstream must
    /// never claim them, or it would shadow search_tools/call_tool dispatch.
    private static let reservedNames: Set<String> = [searchToolName, callToolName]

    /// Disambiguate exposed names that collide across servers (e.g. two
    /// servers that slug identically and share a tool name) — or collide with a
    /// reserved meta name — by suffixing `_2`, `_3`, … Never let a later tool
    /// overwrite an earlier route or a meta tool.
    private static func uniqueName(_ base: String, taken routes: [String: GatewayRoute]) -> String {
        if routes[base] == nil && !reservedNames.contains(base) { return base }
        var n = 2
        while routes["\(base)_\(n)"] != nil || reservedNames.contains("\(base)_\(n)") { n += 1 }
        return "\(base)_\(n)"
    }
}
