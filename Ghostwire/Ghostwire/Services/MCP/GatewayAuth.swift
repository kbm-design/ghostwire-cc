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
        guard Self.constantTimeEquals(provided ?? "", "Bearer \(token)") else {
            return .error(statusCode: 401, .invalidRequest("Unauthorized"))
        }
        return nil
    }

    /// Constant-time byte comparison for bearer tokens. Length still affects the
    /// loop bound, but content mismatches do not short-circuit on the first byte.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        let maxCount = max(left.count, right.count)
        var diff = left.count ^ right.count
        for index in 0..<maxCount {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            diff |= Int(a ^ b)
        }
        return diff == 0
    }
}
