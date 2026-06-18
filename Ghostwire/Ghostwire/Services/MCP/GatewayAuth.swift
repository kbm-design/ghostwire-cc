//
//  GatewayAuth.swift
//  Ghostwire
//
//  GW-253 Phase 2: a per-launch bearer token guards the localhost gateway
//  endpoint, handed to the agent in its `mcp add` config. Origin-localhost is
//  already enforced by the SDK transport's default validation pipeline; this
//  adds authentication on top (the spec requires both for a local HTTP server).
//

import Foundation
import MCP

struct GatewayAuth: Sendable {
    let token: String

    init(token: String = UUID().uuidString) {
        self.token = token
    }

    /// Load the persisted token, or mint + store one on first use. Stable
    /// across launches so a `claude mcp add` registration keeps working.
    static func persistent(store: MCPSecretStore = KeychainMCPSecretStore.shared) -> GatewayAuth {
        if let existing = store.string(account: MCPSecretAccount.gatewayToken), !existing.isEmpty {
            return GatewayAuth(token: existing)
        }
        let token = UUID().uuidString
        store.setString(token, account: MCPSecretAccount.gatewayToken)
        return GatewayAuth(token: token)
    }

    /// `RequestGate`: returns nil to allow, or a 401 `HTTPResponse` to reject.
    func gate(_ request: HTTPRequest) -> HTTPResponse? {
        let provided = request.headers.first {
            $0.key.caseInsensitiveCompare("Authorization") == .orderedSame
        }?.value
        guard provided == "Bearer \(token)" else {
            return .error(statusCode: 401, .invalidRequest("Unauthorized"))
        }
        return nil
    }
}
