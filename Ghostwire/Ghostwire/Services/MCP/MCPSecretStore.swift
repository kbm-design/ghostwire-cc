//
//  MCPSecretStore.swift
//  Ghostwire
//
//  GW-219: the ONLY place MCP secrets live. Generic-password items under
//  service "com.ghostwire.mcp". Env values + Ghostwire's own OAuth tokens.
//  Never lifts other apps' credentials (Claude Code's tokens are PKCE-scoped
//  to its own registration — see T6 research).
//

import Foundation
import Security

enum MCPSecretAccount {
    static func env(serverID: UUID, key: String) -> String { "env.\(serverID.uuidString).\(key)" }
    static func oauthToken(serverID: UUID) -> String { "oauth.\(serverID.uuidString)" }
    /// GW-292: static API-key / bearer token for an `.http` server.
    static func httpAuthToken(serverID: UUID) -> String { "http.token.\(serverID.uuidString)" }
    /// GW-291: pre-registered OAuth `client_secret` (confidential clients).
    static func oauthClientSecret(serverID: UUID) -> String { "oauth.clientSecret.\(serverID.uuidString)" }
    /// GW-253: the gateway's HTTP bearer token — one stable value across
    /// launches so a registered agent keeps working.
    static let gatewayToken = "gateway.token"
}

protocol MCPSecretStore: AnyObject {
    func setString(_ value: String, account: String)
    func string(account: String) -> String?
    func setData(_ value: Data, account: String)
    func data(account: String) -> Data?
    func delete(account: String)
}

extension MCPSecretStore {
    /// Remove every secret belonging to a server (called on server removal).
    func deleteAll(serverID: UUID, environmentKeys: [String]) {
        for key in environmentKeys {
            delete(account: MCPSecretAccount.env(serverID: serverID, key: key))
        }
        delete(account: MCPSecretAccount.oauthToken(serverID: serverID))
        delete(account: MCPSecretAccount.httpAuthToken(serverID: serverID))
        delete(account: MCPSecretAccount.oauthClientSecret(serverID: serverID))
    }
}

final class KeychainMCPSecretStore: MCPSecretStore {
    static let shared = KeychainMCPSecretStore()
    private let service = "com.ghostwire.mcp"

    func setString(_ value: String, account: String) {
        setData(Data(value.utf8), account: account)
    }

    func string(account: String) -> String? {
        data(account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    func setData(_ value: Data, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: value]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = value
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func data(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Test double — also used by previews.
final class InMemoryMCPSecretStore: MCPSecretStore {
    private var storage: [String: Data] = [:]
    func setString(_ value: String, account: String) { storage[account] = Data(value.utf8) }
    func string(account: String) -> String? { storage[account].flatMap { String(data: $0, encoding: .utf8) } }
    func setData(_ value: Data, account: String) { storage[account] = value }
    func data(account: String) -> Data? { storage[account] }
    func delete(account: String) { storage[account] = nil }
}
