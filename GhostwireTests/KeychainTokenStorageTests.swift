import MCP
import XCTest

@testable import Ghostwire

final class KeychainTokenStorageTests: XCTestCase {
    func testEnvAccountNamingIsPerServerPerKey() {
        let id = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
        XCTAssertEqual(
            MCPSecretAccount.env(serverID: id, key: "API_KEY"),
            "env.AAAAAAAA-0000-0000-0000-000000000000.API_KEY"
        )
        XCTAssertEqual(
            MCPSecretAccount.oauthToken(serverID: id),
            "oauth.AAAAAAAA-0000-0000-0000-000000000000"
        )
    }

    func testInMemoryStoreRoundTrip() {
        let store = InMemoryMCPSecretStore()
        store.setString("sk-12345", account: "env.x.API_KEY")
        XCTAssertEqual(store.string(account: "env.x.API_KEY"), "sk-12345")
        store.delete(account: "env.x.API_KEY")
        XCTAssertNil(store.string(account: "env.x.API_KEY"))
    }

    func testRemovingServerSecretsClearsAllItsAccounts() {
        let store = InMemoryMCPSecretStore()
        let id = UUID()
        store.setString("v1", account: MCPSecretAccount.env(serverID: id, key: "A"))
        store.setString("v2", account: MCPSecretAccount.env(serverID: id, key: "B"))
        store.setString("tok", account: MCPSecretAccount.oauthToken(serverID: id))
        store.deleteAll(serverID: id, environmentKeys: ["A", "B"])
        XCTAssertNil(store.string(account: MCPSecretAccount.env(serverID: id, key: "A")))
        XCTAssertNil(store.string(account: MCPSecretAccount.env(serverID: id, key: "B")))
        XCTAssertNil(store.string(account: MCPSecretAccount.oauthToken(serverID: id)))
    }

    func testKeychainTokenStorageRoundTripsOAuthToken() throws {
        let secretStore = InMemoryMCPSecretStore()
        let serverID = UUID()
        let storage = KeychainTokenStorage(serverID: serverID, secretStore: secretStore)
        let token = OAuthAccessToken(
            value: "abc", tokenType: "Bearer", expiresAt: nil,
            scopes: [], authorizationServer: nil, refreshToken: nil
        )
        storage.save(token)
        XCTAssertEqual(storage.load()?.value, "abc")
        storage.clear()
        XCTAssertNil(storage.load())
        XCTAssertNil(secretStore.data(account: MCPSecretAccount.oauthToken(serverID: serverID)))
    }
}
