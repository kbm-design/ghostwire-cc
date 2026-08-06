//
//  GatewayRegistrationAudit.swift
//  Ghostwire
//
//  GW-351: detect a host that registered the gateway with a token that is no
//  longer the live one, and say so. Symptom without this: the connector 401s,
//  the user sees "not connected" next to a perfectly valid port, and nothing
//  explains why — the exact confusion GW-308 opened with.
//
//  Two ways to be in that state, both still reachable after GW-308 stopped the
//  token rotating: registered before that fix landed, or hit its known edge
//  (a dev build first to run post-fix on a machine whose registration came from
//  a release-build Keychain token).
//
//  READ-ONLY, DELIBERATELY. `MCPServeRegistration` documents the standing trust
//  posture: Ghostwire never WRITES an agent's config. Reading one to compare a
//  token is fine; auto-repair is not. We show the command; the user runs it.
//
//  Parsed with `JSONSerialization` rather than `Codable` for the same reason
//  `AgentMCPConfigImporter` is: `~/.claude.json` is ~185KB of mostly-unrelated
//  client state whose shape drifts release to release. Read the keys we
//  understand, ignore everything else, never fail the whole read on a sibling.
//

import Foundation

enum GatewayRegistrationAudit {
    /// What the host's config says about our gateway.
    enum Status: Equatable {
        /// No `~/.claude.json`, or it holds no gateway entry. Not an error —
        /// the user simply hasn't run the command yet.
        case notRegistered
        /// Registered, and the token matches the live one.
        case current(scopes: [String])
        /// Registered with a token that is no longer live. `scopes` says where
        /// the stale entries are, because a project-scoped leftover is a
        /// different fix from a user-scoped one.
        case stale(scopes: [String])

        var needsReconnect: Bool {
            if case .stale = self { return true }
            return false
        }
    }

    static let userScopeLabel = "user"

    /// Compare every registered gateway entry against `liveToken`.
    ///
    /// A config can hold more than one entry for the same server — GW-350 found
    /// exactly that: a stale project-scoped registration under
    /// `projects["/Users/<user>"]` alongside a working user-scoped one. So a
    /// single "does it match" answer would be wrong. If ANY entry is stale we
    /// report stale, because that is the one producing the 401.
    static func status(liveToken: String, configURL: URL = defaultConfigURL) -> Status {
        guard !liveToken.isEmpty,
            let data = try? Data(contentsOf: configURL),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .notRegistered }

        var staleScopes: [String] = []
        var currentScopes: [String] = []

        func inspect(_ servers: Any?, scope: String) {
            guard let servers = servers as? [String: Any],
                let entry = servers[GatewayRegistration.serverName] as? [String: Any]
            else { return }
            // A registration we can't read a token out of is BROKEN, not absent.
            // Skipping it reported `.notRegistered` — or worse `.current`, if
            // another scope happened to match — while Claude went on using that
            // entry and 401ing against us. That is precisely the silent failure
            // this audit exists to surface, so an unparseable entry counts as
            // stale for its scope.
            guard let registered = bearerToken(from: entry), registered == liveToken else {
                staleScopes.append(scope)
                return
            }
            currentScopes.append(scope)
        }

        inspect(root["mcpServers"], scope: userScopeLabel)
        let projects = root["projects"] as? [String: Any] ?? [:]
        for path in projects.keys.sorted() {
            inspect((projects[path] as? [String: Any])?["mcpServers"], scope: path)
        }

        if !staleScopes.isEmpty { return .stale(scopes: staleScopes) }
        if !currentScopes.isEmpty { return .current(scopes: currentScopes) }
        return .notRegistered
    }

    /// Pull the bearer out of an entry's headers.
    ///
    /// Header NAMES are case-insensitive per RFC 9110 and the CLI writes
    /// whatever the user typed, so match case-insensitively. The scheme prefix
    /// is matched case-insensitively too but the token itself is compared
    /// verbatim — it is a secret, not a word.
    static func bearerToken(from entry: [String: Any]) -> String? {
        guard let headers = entry["headers"] as? [String: Any] else { return nil }
        for (name, value) in headers where name.lowercased() == "authorization" {
            guard let value = value as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("bearer ") else { return trimmed }
            return String(trimmed.dropFirst("bearer ".count))
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static var defaultConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }
}
