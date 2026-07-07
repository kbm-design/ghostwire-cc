//
//  MCPHTTPAuthTests.swift
//  GhostwireTests
//
//  GW-291/292: per-server HTTP auth for remote MCP servers — pre-registered
//  OAuth client_id/secret (with optional pinned loopback) and static
//  API-key/Bearer header injection. Covers:
//    - MCPHTTPAuth Codable round-trip + legacy back-compat (absent = nil)
//    - Keychain account naming + deleteAll cleanup
//    - authentication(for:secretStore:) selection (DCR / public / confidential)
//    - redirectURI(for: config) pinned port/path vs UUID-hash fallback
//    - MCPHTTPAuth.requestModifier(token:) header injection
//

import XCTest
import MCP
@testable import Ghostwire

final class MCPHTTPAuthTests: XCTestCase {

    private func httpConfig(id: UUID = UUID(), auth: MCPHTTPAuth?) -> MCPServerConfig {
        var config = MCPServerConfig(
            id: id, name: "Remote",
            transport: .http(endpoint: URL(string: "https://mcp.example.com/")!))
        config.httpAuth = auth
        return config
    }

    // MARK: - Codable

    func testHTTPAuthCodableRoundTripAllCases() throws {
        let cases: [MCPHTTPAuth] = [
            .bearer,
            .header(name: "x-api-key"),
            .oauthClient(clientID: "abc123", loopbackPort: nil, loopbackPath: nil),
            .oauthClient(clientID: "gh", loopbackPort: 51777, loopbackPath: "/callback/"),
        ]
        for value in cases {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(MCPHTTPAuth.self, from: data)
            XCTAssertEqual(decoded, value)
        }
    }

    func testLegacyConfigWithoutHTTPAuthDecodesToNil() throws {
        // A config JSON persisted before GW-291 has no "httpAuth" key.
        let legacy = """
        {
          "id": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
          "name": "Old Server",
          "transport": { "http": { "endpoint": "https://mcp.example.com/" } },
          "allowedTools": [],
          "isEnabled": true
        }
        """
        let data = Data(legacy.utf8)
        let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: data)
        XCTAssertNil(decoded.httpAuth, "absent httpAuth must decode to nil (default DCR behavior)")
    }

    // MARK: - Keychain accounts

    func testSecretAccountNamesAreNamespacedPerServer() {
        let id = UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!
        XCTAssertEqual(MCPSecretAccount.httpAuthToken(serverID: id),
                       "http.token.A1B2C3D4-E5F6-7890-ABCD-EF1234567890")
        XCTAssertEqual(MCPSecretAccount.oauthClientSecret(serverID: id),
                       "oauth.clientSecret.A1B2C3D4-E5F6-7890-ABCD-EF1234567890")
    }

    func testDeleteAllRemovesHTTPTokenAndClientSecret() {
        let store = InMemoryMCPSecretStore()
        let id = UUID()
        store.setString("tok", account: MCPSecretAccount.httpAuthToken(serverID: id))
        store.setString("sec", account: MCPSecretAccount.oauthClientSecret(serverID: id))
        store.setString("otok", account: MCPSecretAccount.oauthToken(serverID: id))

        store.deleteAll(serverID: id, environmentKeys: [])

        XCTAssertNil(store.string(account: MCPSecretAccount.httpAuthToken(serverID: id)))
        XCTAssertNil(store.string(account: MCPSecretAccount.oauthClientSecret(serverID: id)))
        XCTAssertNil(store.string(account: MCPSecretAccount.oauthToken(serverID: id)))
    }

    // MARK: - Authorizer selection

    func testAuthenticationDefaultsToDCRWhenNoHTTPAuth() {
        let store = InMemoryMCPSecretStore()
        let auth = MCPOAuthCoordinator.authentication(for: httpConfig(auth: nil), secretStore: store)
        XCTAssertEqual(auth, .none(clientID: "ghostwire"))
    }

    func testAuthenticationPublicClientWhenNoSecret() {
        let store = InMemoryMCPSecretStore()
        let config = httpConfig(auth: .oauthClient(clientID: "slack-id", loopbackPort: nil, loopbackPath: nil))
        let auth = MCPOAuthCoordinator.authentication(for: config, secretStore: store)
        XCTAssertEqual(auth, .none(clientID: "slack-id"))
    }

    func testAuthenticationConfidentialWhenSecretPresent() {
        let store = InMemoryMCPSecretStore()
        let config = httpConfig(auth: .oauthClient(clientID: "gh-id", loopbackPort: nil, loopbackPath: nil))
        store.setString("gh-secret", account: MCPSecretAccount.oauthClientSecret(serverID: config.id))
        let auth = MCPOAuthCoordinator.authentication(for: config, secretStore: store)
        XCTAssertEqual(auth, .clientSecretPost(clientID: "gh-id", clientSecret: "gh-secret"))
    }

    // MARK: - Pinned loopback redirect URI

    func testRedirectURIUsesPinnedPortAndPath() {
        let config = httpConfig(auth: .oauthClient(clientID: "x", loopbackPort: 51777, loopbackPath: "/callback/"))
        let uri = MCPOAuthCoordinator.redirectURI(for: config)
        // absoluteString is what's sent as redirect_uri — the trailing slash
        // (Asana) must survive verbatim (URL.path would strip it).
        XCTAssertEqual(uri.absoluteString, "http://127.0.0.1:51777/callback/")
    }

    func testRedirectURIFallsBackToHashPortWhenUnpinned() {
        let id = UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!
        let config = httpConfig(id: id, auth: .oauthClient(clientID: "x", loopbackPort: nil, loopbackPath: nil))
        let uri = MCPOAuthCoordinator.redirectURI(for: config)
        XCTAssertEqual(uri.port, Int(MCPOAuthCoordinator.loopbackPort(for: id)))
        XCTAssertEqual(uri.path, "/callback")
    }

    func testRedirectURINormalizesPathMissingLeadingSlash() {
        // Codex P2: a pinned path like "callback" (no leading slash) must not
        // build "…:<port>callback" and force-unwrap-crash.
        let config = httpConfig(auth: .oauthClient(clientID: "x", loopbackPort: 51777, loopbackPath: "callback"))
        let uri = MCPOAuthCoordinator.redirectURI(for: config)
        XCTAssertEqual(uri.absoluteString, "http://127.0.0.1:51777/callback")
    }

    func testNormalizedLoopbackPathAddsLeadingSlashAndDefaults() {
        XCTAssertEqual(MCPOAuthCoordinator.normalizedLoopbackPath("callback"), "/callback")
        XCTAssertEqual(MCPOAuthCoordinator.normalizedLoopbackPath("/callback/"), "/callback/")
        XCTAssertEqual(MCPOAuthCoordinator.normalizedLoopbackPath(nil), "/callback")
        XCTAssertEqual(MCPOAuthCoordinator.normalizedLoopbackPath(""), "/callback")
        XCTAssertEqual(MCPOAuthCoordinator.normalizedLoopbackPath("  "), "/callback")
    }

    func testRedirectURIForDCRConfigUsesHashFallback() {
        let id = UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!
        let config = httpConfig(id: id, auth: nil)
        let uri = MCPOAuthCoordinator.redirectURI(for: config)
        XCTAssertEqual(uri.port, Int(MCPOAuthCoordinator.loopbackPort(for: id)))
        XCTAssertEqual(uri.path, "/callback")
    }

    // MARK: - API-key / Bearer request modifier

    private func applied(_ auth: MCPHTTPAuth, token: String?, header: String) -> String? {
        var request = URLRequest(url: URL(string: "https://mcp.example.com/")!)
        request = auth.requestModifier(token: token)(request)
        return request.value(forHTTPHeaderField: header)
    }

    func testBearerRequestModifierSetsAuthorizationHeader() {
        XCTAssertEqual(applied(.bearer, token: "tok123", header: "Authorization"), "Bearer tok123")
    }

    func testHeaderRequestModifierSetsCustomHeaderRaw() {
        XCTAssertEqual(applied(.header(name: "x-api-key"), token: "tok123", header: "x-api-key"), "tok123")
    }

    func testRequestModifierIsIdentityForOAuthClient() {
        let auth = MCPHTTPAuth.oauthClient(clientID: "x", loopbackPort: nil, loopbackPath: nil)
        XCTAssertNil(applied(auth, token: "tok", header: "Authorization"))
    }

    func testRequestModifierIsIdentityWhenTokenMissing() {
        XCTAssertNil(applied(.bearer, token: nil, header: "Authorization"))
    }

    // MARK: - Transport detection (add-sheet input routing)

    func testDetectsHTTPForCleanURL() {
        XCTAssertEqual(detectMCPTransportKind(from: "https://huggingface.co/mcp"), .http)
        XCTAssertEqual(detectMCPTransportKind(from: "http://127.0.0.1:8080/mcp"), .http)
    }

    func testDetectsHTTPDespiteLeadingWhitespaceFromPaste() {
        // The real bug: a stray leading space when pasting misrouted an http
        // URL to the stdio (local-command) path.
        XCTAssertEqual(detectMCPTransportKind(from: " https://huggingface.co/mcp"), .http)
        XCTAssertEqual(detectMCPTransportKind(from: "\thttps://huggingface.co/mcp"), .http)
    }

    func testDetectsHTTPDespiteTrailingWhitespaceAndCase() {
        XCTAssertEqual(detectMCPTransportKind(from: "https://x/mcp\n"), .http)
        XCTAssertEqual(detectMCPTransportKind(from: "HTTPS://x/mcp"), .http)
    }

    func testDetectsStdioForCommand() {
        XCTAssertEqual(detectMCPTransportKind(from: "npx -y @example/server"), .stdio)
        XCTAssertEqual(detectMCPTransportKind(from: "  npx -y @example/server"), .stdio)
    }
}
