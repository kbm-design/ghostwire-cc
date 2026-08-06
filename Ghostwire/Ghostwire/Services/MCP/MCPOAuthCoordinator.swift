//
//  MCPOAuthCoordinator.swift
//  Ghostwire
//
//  GW-219: Ghostwire's OWN OAuth. The SDK auto-handles RFC 9728/8414
//  discovery, dynamic client registration, and PKCE; our part is the
//  browser redirect (loopback HTTP listener per MCP spec) and Keychain
//  persistence.
//
//  Redirect pattern: per-server deterministic localhost port
//  (http://127.0.0.1:<port>/callback). The port is derived from the
//  server's UUID so it is stable across launches — DCR registers the
//  exact URI, which must not change.
//
//  Non-interactive contexts (launch/wake reconnects) must never pop a
//  browser: presentAuthorizationURL throws unless the user pressed
//  Authorize/Connect, and the server then shows status "Needs auth".
//

import AppKit
import Foundation
import MCP
import Network

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

    /// Only true while the user is explicitly connecting/authorizing from
    /// Settings. Guards against browser pop-ups from background reconnects.
    private var interactiveGrantInFlight = false

    func beginInteractiveGrant() { interactiveGrantInFlight = true }
    func endInteractiveGrant() { interactiveGrantInFlight = false }

    /// Deterministic loopback port per server (mcp-remote's pattern): the DCR
    /// registration pins the exact redirect URI, so the port must be stable
    /// across launches. Range 49152±... avoid privileged/common ports.
    static func loopbackPort(for serverID: UUID) -> UInt16 {
        var hash: UInt64 = 5381
        for byte in serverID.uuidString.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return UInt16(10000 + (hash % 45000))
    }

    static func redirectURI(for serverID: UUID) -> URL {
        URL(string: "http://127.0.0.1:\(loopbackPort(for: serverID))/callback")!
    }

    /// GW-291: redirect URI honoring a pinned loopback port/path when the
    /// server carries a pre-registered OAuth client that requires an exact
    /// registered callback (Slack/Asana). Falls back to the UUID-hash port
    /// and `/callback` otherwise.
    static func redirectURI(for config: MCPServerConfig) -> URL {
        if case .oauthClient(_, let port, let path) = config.httpAuth {
            let resolvedPort = port ?? loopbackPort(for: config.id)
            let resolvedPath = normalizedLoopbackPath(path)
            // Normalized path is always well-formed, but never force-unwrap a
            // parsed URL — fall back to the hash default if it somehow fails.
            return URL(string: "http://127.0.0.1:\(resolvedPort)\(resolvedPath)")
                ?? redirectURI(for: config.id)
        }
        return redirectURI(for: config.id)
    }

    /// Normalize a user-entered pinned callback path: trim it, default to
    /// `/callback` when empty, and guarantee a leading slash so the redirect
    /// URL is always well-formed (a bare `callback` would corrupt the port).
    static func normalizedLoopbackPath(_ path: String?) -> String {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "/callback" }
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }

    /// GW-291: which token-endpoint auth the SDK should use for this server.
    /// - no `httpAuth`        → `.none("ghostwire")`, leaving DCR to run.
    /// - `.oauthClient` only  → `.none(clientID)`, a pinned public/PKCE client.
    /// - `.oauthClient` + secret in Keychain → `.clientSecretPost` (confidential).
    /// (`.bearer`/`.header` never build an authorizer — they inject a header.)
    static func authentication(
        for config: MCPServerConfig,
        secretStore: MCPSecretStore = KeychainMCPSecretStore.shared
    ) -> OAuthConfiguration.TokenEndpointAuthentication {
        guard case .oauthClient(let clientID, _, _) = config.httpAuth else {
            return .none(clientID: "ghostwire")
        }
        if let secret = secretStore.string(
            account: MCPSecretAccount.oauthClientSecret(serverID: config.id)), !secret.isEmpty {
            return .clientSecretPost(clientID: clientID, clientSecret: secret)
        }
        return .none(clientID: clientID)
    }

    /// One authorizer per server config; per-server Keychain token storage.
    func authorizer(
        for config: MCPServerConfig,
        secretStore: MCPSecretStore = KeychainMCPSecretStore.shared
    ) -> OAuthAuthorizer {
        OAuthAuthorizer(
            configuration: OAuthConfiguration(
                grantType: .authorizationCode,
                authentication: Self.authentication(for: config, secretStore: secretStore),
                authorizationRedirectURI: Self.redirectURI(for: config),
                clientName: "Ghostwire",
                authorizationDelegate: self
            ),
            tokenStorage: KeychainTokenStorage(serverID: config.id, secretStore: secretStore)
        )
    }
}

extension MCPOAuthCoordinator: OAuthAuthorizationDelegate {
    func presentAuthorizationURL(_ url: URL) async throws -> URL {
        guard interactiveGrantInFlight else { throw MCPAuthInteractionRequired() }
        // The redirect_uri we registered is embedded in the authorize URL.
        guard let redirect = Self.redirectURI(fromAuthorizeURL: url),
              let port = redirect.port.map(UInt16.init) else {
            throw MCPAuthInteractionRequired()
        }
        guard let expectedState = Self.queryValue("state", in: url), !expectedState.isEmpty else {
            throw MCPAuthInteractionRequired()
        }
        let listener = try OAuthLoopbackListener(
            port: port, expectedPath: redirect.path, expectedState: expectedState)
        defer { listener.stop() }
        await MainActor.run { NSWorkspace.shared.open(url) }
        return try await listener.waitForCallback(timeout: 180)
    }

    /// Extract the redirect_uri query parameter from the authorize URL.
    static func redirectURI(fromAuthorizeURL url: URL) -> URL? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "redirect_uri" }?.value.flatMap(URL.init(string:))
    }

    static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }
}

// MARK: - OAuthLoopbackListener

/// Minimal HTTP listener on 127.0.0.1 that captures the OAuth callback redirect.
///
/// NWListener accepts the first connection whose request path matches
/// `expectedPath`, writes a minimal 200 response, and returns the full
/// callback URL. Non-matching paths (e.g. /favicon.ico) receive a 404 and
/// the listener keeps waiting within the overall timeout.
final class OAuthLoopbackListener: @unchecked Sendable {
    private let port: UInt16
    private let expectedPath: String
    private let expectedState: String
    private var listener: NWListener?
    private var activeConnections: [NWConnection] = []
    private let queue = DispatchQueue(label: "com.ghostwire.oauth-loopback")

    init(port: UInt16, expectedPath: String, expectedState: String) throws {
        self.port = port
        self.expectedPath = expectedPath
        self.expectedState = expectedState

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw OAuthLoopbackError.invalidPort
        }
        let params = NWParameters.tcp
        // The port rides in requiredLocalEndpoint; passing it to init(using:on:)
        // as well makes NWListener fail at start with a conflict.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
        let l = try NWListener(using: params)
        self.listener = l
    }

    func waitForCallback(timeout: TimeInterval) async throws -> URL {
        guard let listener else { throw OAuthLoopbackError.listenerNotStarted }

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let lock = NSLock()

            func resume(with result: Result<URL, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }

            // Timeout task
            let timeoutItem = DispatchWorkItem {
                resume(with: .failure(OAuthLoopbackError.timeout))
            }
            queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.queue.async {
                    self.activeConnections.append(connection)
                }
                self.handleConnection(
                    connection,
                    port: self.port,
                    expectedPath: self.expectedPath,
                    expectedState: self.expectedState,
                    onMatch: { url in
                        timeoutItem.cancel()
                        resume(with: .success(url))
                    },
                    onNoMatch: { _ in
                        // Non-matching path; keep waiting.
                    }
                )
                connection.start(queue: self.queue)
            }

            listener.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    timeoutItem.cancel()
                    resume(with: .failure(error))
                default:
                    break
                }
            }

            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            for conn in self.activeConnections { conn.cancel() }
            self.activeConnections.removeAll()
        }
    }

    // MARK: Private

    private func handleConnection(
        _ connection: NWConnection,
        port: UInt16,
        expectedPath: String,
        expectedState: String,
        onMatch: @escaping (URL) -> Void,
        onNoMatch: @escaping (String) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
            guard let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            let raw = String(decoding: data, as: UTF8.self)
            // Parse the request line: "GET /path?query HTTP/1.1"
            let requestLine = raw.components(separatedBy: "\r\n").first ?? ""
            let parts = requestLine.components(separatedBy: " ")
            guard parts.count >= 2 else {
                connection.cancel()
                return
            }
            let requestTarget = parts[1] // e.g. "/callback?code=abc&state=xyz"
            let pathOnly = requestTarget.components(separatedBy: "?").first ?? requestTarget

            if pathOnly == expectedPath {
                let callbackURL = URL(string: "http://127.0.0.1:\(port)\(requestTarget)")
                guard Self.headersAreLocal(raw, port: port),
                      Self.queryValue("state", in: callbackURL) == expectedState else {
                    Self.send(status: "400 Bad Request", body: "", on: connection)
                    onNoMatch(pathOnly)
                    return
                }
                let body = "<html><body><h2>Connected.</h2><p>You can close this tab and return to Ghostwire.</p></body></html>"
                Self.send(status: "200 OK", body: body, contentType: "text/html", on: connection)
                if let url = callbackURL {
                    onMatch(url)
                }
            } else {
                Self.send(status: "404 Not Found", body: "", on: connection)
                onNoMatch(pathOnly)
            }
        }
    }

    private static func queryValue(_ name: String, in url: URL?) -> String? {
        guard let url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    private static func headersAreLocal(_ raw: String, port: UInt16) -> Bool {
        let lines = raw.components(separatedBy: "\r\n").dropFirst()
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        if let host = headers["host"], host != "127.0.0.1:\(port)" {
            return false
        }
        if let origin = headers["origin"],
           let url = URL(string: origin),
           url.host != "127.0.0.1" && url.host != "localhost" {
            return false
        }
        return true
    }

    private static func send(
        status: String,
        body: String,
        contentType: String = "text/plain",
        on connection: NWConnection
    ) {
        let bodyBytes = body.utf8
        let response =
            "HTTP/1.1 \(status)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(bodyBytes.count)\r\n" +
            "Connection: close\r\n\r\n" +
            body
        connection.send(
            content: response.data(using: .utf8),
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }
}

enum OAuthLoopbackError: LocalizedError {
    case invalidPort
    case listenerNotStarted
    case timeout
    case badRequestLine

    var errorDescription: String? {
        switch self {
        case .invalidPort: return "Invalid loopback port for OAuth listener."
        case .listenerNotStarted: return "OAuth loopback listener was not started."
        case .timeout: return "Timed out waiting for the browser sign-in to complete."
        case .badRequestLine: return "Could not parse HTTP request from browser callback."
        }
    }
}
