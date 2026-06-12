//
//  MCPOAuthCoordinator.swift
//  Ghostwire
//
//  GW-219: Ghostwire's OWN OAuth. The SDK auto-handles RFC 9728/8414
//  discovery, dynamic client registration, and PKCE; our part is the
//  browser redirect (ASWebAuthenticationSession) and Keychain persistence.
//  NEVER reads other apps' tokens. Browser presentation is anchored to the
//  Settings window — never the notch (window-level constraint).
//
//  Non-interactive contexts (launch/wake reconnects) must never pop a
//  browser: presentAuthorizationURL throws unless the user pressed
//  Authorize/Connect, and the server then shows status "Needs auth".
//

import AppKit
import AuthenticationServices
import Foundation
import MCP

struct MCPAuthInteractionRequired: LocalizedError {
    var errorDescription: String? {
        "Authorization required — open the server in Settings and press Authorize."
    }
}

/// SDK TokenStorage backed by our Keychain secret store, one account per server.
final class KeychainTokenStorage: TokenStorage, @unchecked Sendable {
    private let account: String
    private let secretStore: MCPSecretStore

    init(serverID: UUID, secretStore: MCPSecretStore = KeychainMCPSecretStore.shared) {
        self.account = MCPSecretAccount.oauthToken(serverID: serverID)
        self.secretStore = secretStore
    }

    func save(_ token: OAuthAccessToken) {
        if let data = try? JSONEncoder().encode(token) {
            secretStore.setData(data, account: account)
        }
    }

    func load() -> OAuthAccessToken? {
        secretStore.data(account: account).flatMap {
            try? JSONDecoder().decode(OAuthAccessToken.self, from: $0)
        }
    }

    func clear() {
        secretStore.delete(account: account)
    }
}

final class MCPOAuthCoordinator: NSObject, @unchecked Sendable {
    static let shared = MCPOAuthCoordinator()

    private static let callbackScheme = "ghostwire"
    private static let redirectURI = URL(string: "ghostwire://oauth/callback")!

    /// Only true while the user is explicitly connecting/authorizing from
    /// Settings. Guards against browser pop-ups from background reconnects.
    private var interactiveGrantInFlight = false

    func beginInteractiveGrant() { interactiveGrantInFlight = true }
    func endInteractiveGrant() { interactiveGrantInFlight = false }

    /// One authorizer per server config; per-server Keychain token storage.
    func authorizer(for config: MCPServerConfig) -> OAuthAuthorizer {
        OAuthAuthorizer(
            configuration: OAuthConfiguration(
                grantType: .authorizationCode,
                // DCR replaces this when the AS supports RFC 7591.
                authentication: .none(clientID: "ghostwire"),
                authorizationRedirectURI: Self.redirectURI,
                clientName: "Ghostwire",
                authorizationDelegate: self
            ),
            tokenStorage: KeychainTokenStorage(serverID: config.id)
        )
    }
}

extension MCPOAuthCoordinator: OAuthAuthorizationDelegate {
    func presentAuthorizationURL(_ url: URL) async throws -> URL {
        guard interactiveGrantInFlight else { throw MCPAuthInteractionRequired() }
        return try await Self.presentOnMain(url: url)
    }

    @MainActor
    private static func presentOnMain(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: Self.callbackScheme
            ) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? MCPAuthInteractionRequired())
                }
            }
            session.presentationContextProvider = MCPAuthPresentationAnchor.shared
            session.start()
        }
    }
}

/// Anchors the auth sheet to the Settings window (falls back to key window).
final class MCPAuthPresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = MCPAuthPresentationAnchor()
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
    }
}
