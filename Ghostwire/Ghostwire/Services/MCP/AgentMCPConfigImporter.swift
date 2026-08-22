//
//  AgentMCPConfigImporter.swift
//  Ghostwire
//
//  GW-332 Phase 1: read the MCP servers the user has already configured for
//  Claude Code and offer them for import. Zero typing, and the command/args/env
//  are ones they've already proven work.
//
//  Read-only. This never writes to ~/.claude.json — Claude Code owns that file
//  (the same trust posture MCPServeRegistration documents).
//
//  Deliberately free of the MCP SDK and of AppKit so it stays a pure, testable
//  parser: everything here is value-in / value-out.
//

import Foundation

/// One MCP server found in another agent's config file, before it becomes a
/// `MCPServerConfig`.
///
/// SECURITY: `environment` and `httpAuthToken` carry **plaintext credentials**
/// lifted out of the agent config. They exist only between parse and import,
/// and import puts them in the Keychain (`MCPSecretAccount`). Nothing on this
/// type is ever encoded into `~/.ghostwire/mcp-servers.json` — that file stays
/// secret-free, and `MCPServerConfigStoreTests` asserts it.
struct DiscoveredMCPServer: Identifiable, Equatable {
    enum Transport: Equatable {
        case stdio(command: String, arguments: [String])
        case http(endpoint: URL)
    }

    /// Why an entry we found can't be offered for import. `nil` = importable.
    ///
    /// Blocked entries are still listed. A server the user knows they have,
    /// silently missing from the list, reads as "Ghostwire didn't find it" —
    /// which sends them hunting instead of telling them the reason.
    enum Blocker: Equatable {
        /// A credential is baked into the command line (e.g.
        /// `--access-token sbp_…`). Args are part of `commandSignature`, so
        /// importing this would write the secret into `mcp-servers.json`.
        /// Verified live 2026-08-05: a real `~/.claude.json` had exactly this.
        case credentialInCommandLine(flag: String)
        /// `https://user:pass@host/…` — same problem, in the endpoint.
        case credentialInEndpoint
        /// Ghostwire's own `mcp-serve` / gateway registration. Importing it
        /// would point Ghostwire at itself.
        case selfReference
        /// Already in Ghostwire's list (matched on command signature/endpoint,
        /// never on name).
        case alreadyAdded

        var reason: String {
            switch self {
            case .credentialInCommandLine(let flag):
                return "The command line contains a credential (\(flag)). "
                    + "Ghostwire keeps secrets in the Keychain, and a command line is stored "
                    + "in plain text — add this one manually with the key in an env var."
            case .credentialInEndpoint:
                return "The URL embeds a username/password. Add it manually so the "
                    + "credential can go in the Keychain."
            case .selfReference:
                return "This is Ghostwire's own MCP server."
            case .alreadyAdded:
                return "Already added."
            }
        }
    }

    var name: String
    var transport: Transport
    /// Env var name → plaintext value from the agent config. Keychain-bound at
    /// import; only the KEY NAMES reach `MCPServerConfig`.
    var environment: [String: String]
    /// Outbound auth derived from the entry's `headers` (`.http` only).
    var httpAuth: MCPHTTPAuth?
    /// Plaintext token behind `httpAuth`. Keychain-bound at import.
    var httpAuthToken: String?
    /// Headers we found but can't represent as `MCPHTTPAuth`. Surfaced in the
    /// sheet rather than dropped silently — an import that quietly loses a
    /// required header produces a server that just fails.
    var unmappedHeaderNames: [String] = []
    /// Where it was found: "Global" and/or project paths. A server can appear
    /// in several scopes; they're unioned rather than listed as duplicates.
    var scopes: [String]
    var blocker: Blocker?
    /// Dedupe key: the stdio command signature, or the normalized endpoint.
    /// NEVER the name — two projects name the same Figma endpoint differently.
    let signature: String

    var id: String { signature }
    var isImportable: Bool { blocker == nil }

    /// What to show as the server's identity line.
    var commandLine: String {
        switch transport {
        case .stdio(let command, let arguments):
            return ([command] + arguments).joined(separator: " ")
        case .http(let endpoint):
            return endpoint.absoluteString
        }
    }

    var transportBadge: String {
        switch transport {
        case .stdio: return "stdio"
        case .http: return "http"
        }
    }
}

enum AgentMCPConfigImporter {
    /// Claude Code's config. One file, two places to look — see `discover`.
    static var claudeCodeConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    static var claudeCodeConfigExists: Bool {
        FileManager.default.fileExists(atPath: claudeCodeConfigURL.path)
    }

    /// Whether there is anything the user could actually import RIGHT NOW.
    ///
    /// NOT the same as `claudeCodeConfigExists`, and the difference is the
    /// whole point: Claude Code writes `~/.claude.json` for everyone, MCP
    /// servers or not. Gating an offer on the file's existence promises
    /// "you already have servers set up" to people who have none, and drops
    /// them into an empty sheet (Codex P2, 2026-08-22).
    ///
    /// Also excludes servers already added — re-offering an import you've
    /// completed is the same false promise one step later.
    static func hasImportableServers(existing: [MCPServerConfig]) -> Bool {
        guard claudeCodeConfigExists else { return false }
        guard let discovered = try? discover(
            claudeCodeConfigAt: claudeCodeConfigURL, existing: existing)
        else { return false }
        return discovered.contains { $0.isImportable }
    }

    enum DiscoveryError: LocalizedError, Equatable {
        case unreadable
        case malformed

        var errorDescription: String? {
            switch self {
            case .unreadable: return "Couldn't read ~/.claude.json."
            case .malformed: return "~/.claude.json isn't in the expected format."
            }
        }
    }

    /// Walks **both** `mcpServers` and every `projects[*].mcpServers`.
    ///
    /// THE gotcha of this ticket: the top-level map alone misses most servers.
    /// Verified on a real config 2026-08-05 — 6 servers at top level, 11 more
    /// spread across 8 project entries, including one under
    /// `projects["/Users/<user>"]` that a top-level-only walk never sees.
    ///
    /// Parsed with `JSONSerialization` rather than `Codable` on purpose: the
    /// file is ~185KB of mostly-unrelated client state (71 project entries,
    /// caches, counters) whose shape drifts release to release. We read the two
    /// keys we understand and ignore everything else, so a new sibling key
    /// can't fail the decode. (The `summary` → `ai-title` rename that froze
    /// every session title is the same lesson.)
    static func discover(
        claudeCodeConfigAt url: URL,
        existing: [MCPServerConfig]
    ) throws -> [DiscoveredMCPServer] {
        guard let data = try? Data(contentsOf: url) else { throw DiscoveryError.unreadable }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DiscoveryError.malformed
        }

        var bySignature: [String: DiscoveredMCPServer] = [:]
        var order: [String] = []

        func absorb(_ maps: [String: Any]?, scope: String) {
            guard let maps else { return }
            for name in maps.keys.sorted() {
                guard let raw = maps[name] as? [String: Any],
                    var server = parseEntry(name: name, raw: raw, scope: scope)
                else { continue }
                if var existingHit = bySignature[server.signature] {
                    // Same server, another scope. Keep the first name/shape and
                    // just record where else it lives.
                    if !existingHit.scopes.contains(scope) { existingHit.scopes.append(scope) }
                    bySignature[server.signature] = existingHit
                } else {
                    server.blocker = blocker(for: server, existing: existing)
                    bySignature[server.signature] = server
                    order.append(server.signature)
                }
            }
        }

        absorb(root["mcpServers"] as? [String: Any], scope: globalScopeLabel)

        // THE walk that matters. Project keys are absolute paths.
        let projects = root["projects"] as? [String: Any] ?? [:]
        for path in projects.keys.sorted() {
            let project = projects[path] as? [String: Any]
            absorb(project?["mcpServers"] as? [String: Any], scope: path)
        }

        let all = order.compactMap { bySignature[$0] }
        // Importable first, then alphabetical — the blocked rows are context,
        // not the point of the sheet.
        return all.sorted {
            $0.isImportable == $1.isImportable
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : $0.isImportable
        }
    }

    static let globalScopeLabel = "Global"

    // MARK: - One entry

    /// Key set observed on a real config: `type`, `command`, `args`, `env`,
    /// `url`, `headers`. `type` is treated as a hint, not a requirement —
    /// Claude Code accepts entries without it.
    static func parseEntry(name: String, raw: [String: Any], scope: String)
        -> DiscoveredMCPServer? {
        let declaredType = (raw["type"] as? String)?.lowercased()
        let command = (raw["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString = (raw["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let environment = (raw["env"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }

        let isHTTP: Bool
        switch declaredType {
        case "http", "sse", "streamable-http", "http-stream":
            // `sse` maps onto the same endpoint shape; HTTPClientTransport with
            // streaming negotiates SSE. A legacy SSE-only server will fail to
            // connect with a visible error, which beats being invisible here.
            isHTTP = true
        case "stdio":
            isHTTP = false
        default:
            isHTTP = urlString?.isEmpty == false
        }

        if isHTTP {
            guard let urlString, let endpoint = URL(string: urlString), endpoint.scheme != nil
            else { return nil }
            let headers = (raw["headers"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            let (auth, token, unmapped) = mapHeaders(headers)
            return DiscoveredMCPServer(
                name: name,
                transport: .http(endpoint: endpoint),
                environment: [:],  // env is meaningless for a hosted server
                httpAuth: auth,
                httpAuthToken: token,
                unmappedHeaderNames: unmapped,
                scopes: [scope],
                blocker: nil,
                signature: normalizedEndpointSignature(endpoint)
            )
        }

        guard let command, !command.isEmpty else { return nil }
        // Every element must be a string. Silently dropping one would change
        // the command line — better to skip the entry than to import a
        // different program than the user configured.
        let rawArgs = raw["args"]
        let arguments: [String]
        if rawArgs == nil || rawArgs is NSNull {
            arguments = []
        } else if let list = rawArgs as? [String] {
            arguments = list
        } else {
            return nil
        }

        return DiscoveredMCPServer(
            name: name,
            transport: .stdio(command: command, arguments: arguments),
            environment: environment,
            httpAuth: nil,
            httpAuthToken: nil,
            scopes: [scope],
            blocker: nil,
            signature: commandSignature(command: command, arguments: arguments)
        )
    }

    // MARK: - Signatures (dedupe is on these, never on name)

    /// Byte-identical to `MCPServerConfig.commandSignature` so a discovered
    /// entry and an already-added config compare directly.
    static func commandSignature(command: String, arguments: [String]) -> String {
        ([command] + arguments).joined(separator: "\u{1F}")
    }

    /// Case-folds scheme/host and drops a trailing slash so `…/mcp` and
    /// `…/mcp/` on `LOCALHOST` vs `localhost` are one server.
    static func normalizedEndpointSignature(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        // Credentials must not change the identity of an endpoint.
        components.user = nil
        components.password = nil
        var path = components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        components.path = path
        return components.string ?? url.absoluteString
    }

    static func signature(of config: MCPServerConfig) -> String {
        switch config.transport {
        case .stdio(let command, let arguments, _):
            return commandSignature(command: command, arguments: arguments)
        case .http(let endpoint):
            return normalizedEndpointSignature(endpoint)
        }
    }

    // MARK: - Headers → MCPHTTPAuth

    /// Recognized auth headers, lowercased. Anything else can't be represented
    /// by `MCPHTTPAuth` and is reported rather than dropped.
    private static let authHeaderNames: Set<String> = [
        "authorization", "x-api-key", "api-key", "x-auth-token",
    ]

    static func mapHeaders(_ headers: [String: String])
        -> (auth: MCPHTTPAuth?, token: String?, unmapped: [String]) {
        var auth: MCPHTTPAuth?
        var token: String?
        var unmapped: [String] = []

        for name in headers.keys.sorted() {
            let value = headers[name] ?? ""
            guard authHeaderNames.contains(name.lowercased()), auth == nil, !value.isEmpty else {
                unmapped.append(name)
                continue
            }
            if name.lowercased() == "authorization",
                value.lowercased().hasPrefix("bearer ") {
                // Store the bare token; `.bearer` re-adds the scheme on send,
                // so keeping the prefix would produce "Bearer Bearer …".
                auth = .bearer
                token = String(value.dropFirst("bearer ".count))
                    .trimmingCharacters(in: .whitespaces)
            } else {
                auth = .header(name: name)
                token = value
            }
        }
        return (auth, token, unmapped)
    }

    // MARK: - Blockers

    /// Flags whose *next* argument is a credential. Matching on the flag name
    /// (not on the value's shape) keeps this from mistaking an innocuous
    /// argument for a token — a false positive here hides a working server.
    private static let credentialFlags: Set<String> = [
        "--access-token", "--accesstoken", "--api-key", "--apikey", "--auth",
        "--auth-token", "--bearer", "--client-secret", "--key", "--pass",
        "--password", "--secret", "--token",
    ]

    static func credentialFlag(inArguments arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            let lowered = argument.lowercased()
            if let separator = lowered.firstIndex(of: "=") {
                let flag = String(lowered[lowered.startIndex..<separator])
                let value = argument[argument.index(after: separator)...]
                if credentialFlags.contains(flag), !value.isEmpty { return flag }
                continue
            }
            guard credentialFlags.contains(lowered) else { continue }
            let next = index + 1
            // A trailing flag with nothing after it isn't carrying a secret.
            guard next < arguments.count, !arguments[next].isEmpty,
                !arguments[next].hasPrefix("-")
            else { continue }
            return lowered
        }
        return nil
    }

    /// Ghostwire's own registrations. Both names are ones **Ghostwire wrote**
    /// (`MCPServeRegistration` / `GatewayRegistration` run `claude mcp add
    /// <serverName>`), so matching on them is reading back our own convention,
    /// not guessing at a third party's.
    static func isSelfReference(name: String, transport: DiscoveredMCPServer.Transport) -> Bool {
        if name == MCPServeRegistration.serverName || name == GatewayRegistration.serverName {
            return true
        }
        if case .stdio(let command, let arguments) = transport {
            return arguments.contains(MCPServeRegistration.serveArgument)
                && (command as NSString).lastPathComponent == "Ghostwire"
        }
        return false
    }

    static func blocker(for server: DiscoveredMCPServer, existing: [MCPServerConfig])
        -> DiscoveredMCPServer.Blocker? {
        if isSelfReference(name: server.name, transport: server.transport) { return .selfReference }
        switch server.transport {
        case .stdio(_, let arguments):
            if let flag = credentialFlag(inArguments: arguments) {
                return .credentialInCommandLine(flag: flag)
            }
        case .http(let endpoint):
            let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
            if components?.user?.isEmpty == false || components?.password?.isEmpty == false {
                return .credentialInEndpoint
            }
        }
        if existing.contains(where: { signature(of: $0) == server.signature }) {
            return .alreadyAdded
        }
        return nil
    }
}
