//
//  GatewayAuthTests.swift
//  GhostwireTests
//
//  GW-253 Phase 2: a per-launch bearer token gates the localhost gateway
//  endpoint (Origin-localhost is already enforced by the SDK transport's
//  default validation pipeline). Pure check — no socket needed.
//

import MCP
import XCTest

@testable import Ghostwire

final class GatewayAuthTests: XCTestCase {
    private func request(_ headers: [String: String]) -> HTTPRequest {
        HTTPRequest(method: "POST", headers: headers, body: nil, path: "/mcp")
    }

    func testValidBearerTokenAllows() {
        let auth = GatewayAuth(token: "secret")
        XCTAssertNil(auth.gate(request(["Authorization": "Bearer secret"])))
    }

    func testMissingTokenRejectsWith401() {
        let auth = GatewayAuth(token: "secret")
        let rejection = auth.gate(request([:]))
        XCTAssertEqual(rejection?.statusCode, 401)
    }

    func testWrongTokenRejects() {
        let auth = GatewayAuth(token: "secret")
        XCTAssertNotNil(auth.gate(request(["Authorization": "Bearer wrong"])))
    }

    func testHeaderNameIsCaseInsensitive() {
        let auth = GatewayAuth(token: "secret")
        XCTAssertNil(auth.gate(request(["authorization": "Bearer secret"])))
    }

    func testConstantTimeTokenCompareMatchesOnlyExactBytes() {
        XCTAssertTrue(GatewayAuth.constantTimeEquals("Bearer secret", "Bearer secret"))
        XCTAssertFalse(GatewayAuth.constantTimeEquals("Bearer secret", "Bearer secreu"))
        XCTAssertFalse(GatewayAuth.constantTimeEquals("Bearer secret", "Bearer secretx"))
        XCTAssertFalse(GatewayAuth.constantTimeEquals("Bearer secret", "Bearer secre"))
    }

    func testPersistentTokenIsStableAcrossInstances() {
        // The token must survive app restarts, or a `claude mcp add`
        // registration breaks on the next launch.
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw308-auth-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("gateway-token")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = GatewayTokenStore(fileURL: fileURL, keychain: InMemoryMCPSecretStore())
        let first = GatewayAuth.persistent(store: store)
        let second = GatewayAuth.persistent(store: store)
        XCTAssertFalse(first.token.isEmpty)
        XCTAssertEqual(first.token, second.token)  // reused, not regenerated
    }
}
