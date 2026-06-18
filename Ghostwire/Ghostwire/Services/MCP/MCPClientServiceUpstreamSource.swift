//
//  MCPClientServiceUpstreamSource.swift
//  Ghostwire
//
//  GW-253: backs the gateway core with the user's live MCPClientService
//  connections. Nonisolated + Sendable; hops to the @MainActor service per
//  call. `call` goes through `callAllowedTool` — the single default-deny choke
//  point — so the gateway never bypasses the user's per-tool allowlist.
//

import Foundation
import MCP

final class MCPClientServiceUpstreamSource: GatewayUpstreamSource {
    private let service: MCPClientService

    init(service: MCPClientService) {
        self.service = service
    }

    func servers() async -> [GatewayUpstreamServer] {
        await service.gatewayServers()
    }

    func call(serverID: UUID, tool: String, arguments: [String: Value]?) async throws
        -> MCPToolCallOutput {
        try await service.callAllowedTool(serverID: serverID, name: tool, arguments: arguments)
    }
}
