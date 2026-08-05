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

    /// Load the persisted token, or mint one on first use. Stable across launches
    /// AND across builds (GW-308): the token lives in a file, not Keychain, so a
    /// differently-signed build can still read it and a `claude mcp add`
    /// registration never goes stale.
    static func persistent(store: GatewayTokenStore = GatewayTokenStore()) -> GatewayAuth {
        GatewayAuth(token: store.loadOrCreate())
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
