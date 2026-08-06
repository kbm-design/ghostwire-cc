//
//  GatewayServer.swift
//  Ghostwire
//
//  GW-253 Phase 2: composes the gateway core into an MCP `Server` — the thing
//  the HTTP listener serves per session. Pure (no transport); the listener and
//  tests bring their own transport. Mirrors MCPServeRuntime.makeServer.
//

import Foundation
import MCP

enum GatewayServer {
    /// GW-350: one definition, in `GatewayRegistration`. A second copy here let
    /// the advertised name and the registered name drift apart.
    static var serverName: String { GatewayRegistration.serverName }

    static func makeServer(source: GatewayUpstreamSource) async -> Server {
        let core = MCPGatewayCore(source: source)
        let server = Server(
            name: serverName,
            version: appVersion,
            instructions: """
                Ghostwire's gateway re-exposes the MCP servers you've connected in \
                the notch (e.g. Linear, GitHub) as one set of namespaced tools — \
                `‹app›_‹tool›`. Call them like any tool; Ghostwire routes each to \
                the right downstream and forwards the result.
                """,
            capabilities: .init(
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )

        await server.withMethodHandler(ListTools.self) { _ in
            // GW-184: advertise the bounded working set + search_tools/call_tool,
            // not the full downstream catalog. Recomputed per ListTools.
            let exposure = await core.publicExposure()
            return ListTools.Result(tools: exposure.tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            do {
                let output = try await core.call(exposedName: params.name, arguments: params.arguments)
                // Forward the downstream result verbatim — full content array
                // (text/image/audio/resource + per-item meta), structuredContent,
                // isError, and result-level _meta. No flattening to text.
                return CallTool.Result(
                    content: output.content,
                    structuredContent: output.structuredContent,
                    isError: output.isError ?? false,
                    _meta: output.meta)
            } catch {
                return CallTool.Result(
                    content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                    isError: true)
            }
        }

        // No resources, but answer promptly — Codex probes resources/list to
        // decide a server is available and hangs/marks it down if it's silent.
        await server.withMethodHandler(ListResources.self) { _ in
            ListResources.Result(resources: [])
        }

        return server
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }
}
