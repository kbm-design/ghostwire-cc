//
//  MCPServerConfig.swift
//  Ghostwire
//
//  GW-219: persisted configuration for one external MCP server.
//  NCC's OWN config — separate from agent configs. Never holds secret
//  values: env entries are key NAMES whose values live in the Keychain.
//

import Foundation

enum MCPTransportConfig: Codable, Equatable {
    /// Spawn a local server process. `environmentKeys` are the names of env
    /// vars to inject at spawn; their values are stored in the Keychain
    /// (service com.ghostwire.mcp, account "env.<serverID>.<KEY>").
    case stdio(command: String, arguments: [String], environmentKeys: [String])
    /// Hosted server over Streamable HTTP (SSE when streaming).
    case http(endpoint: URL)

    var displayBadge: String {
        switch self {
        case .stdio: return "stdio"
        case .http: return "http"
        }
    }
}

/// GW-291/292: how Ghostwire authenticates outbound to an `.http` server.
/// `nil` on the config = the default: dynamic client registration (RFC 7591)
/// handled by the SDK, no user setup. Only meaningful for `.http` transport.
///
/// Secret VALUES never live here — `client_id` and header names are public,
/// but the API-key/bearer token and any OAuth `client_secret` live in the
/// Keychain (see `MCPSecretAccount.httpAuthToken` / `oauthClientSecret`).
enum MCPHTTPAuth: Codable, Equatable {
    /// Static credential sent as `Authorization: Bearer <token>`.
    case bearer
    /// Static credential sent as `<name>: <token>` (e.g. `x-api-key`).
    case header(name: String)
    /// Pre-registered OAuth client. `loopbackPort`/`loopbackPath` pin an exact
    /// redirect URI for servers that require one (else the UUID-hash port and
    /// `/callback` are used). A `client_secret` in the Keychain makes it a
    /// confidential client; absent = public/PKCE-only.
    case oauthClient(clientID: String, loopbackPort: UInt16?, loopbackPath: String?)

    /// Builds the per-request header injector for the static-token cases.
    /// Returns the identity transform for the OAuth case (the SDK authorizer
    /// supplies the header) or when no token is available.
    func requestModifier(token: String?) -> (URLRequest) -> URLRequest {
        guard let token, !token.isEmpty else { return { $0 } }
        switch self {
        case .bearer:
            return { request in
                var request = request
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return request
            }
        case .header(let name):
            return { request in
                var request = request
                request.setValue(token, forHTTPHeaderField: name)
                return request
            }
        case .oauthClient:
            return { $0 }
        }
    }
}

/// Which transport an add-sheet input string denotes.
enum MCPTransportKind: Equatable {
    case http
    case stdio
}

/// Pure transport detection for the add-server sheet. Trims leading/trailing
/// whitespace (and is case-insensitive) FIRST — a stray leading space from a
/// paste must not misroute an `https://` URL to the stdio (local-command) path.
func detectMCPTransportKind(from rawInput: String) -> MCPTransportKind {
    let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ? .http : .stdio
}

/// GW-214: one tool bound as an ambient feed card.
///
/// Binding is a SECOND opt-in, deliberately separate from `allowedTools`:
/// allowing a tool says "Ghostwire may call this when I ask", binding it says
/// "call it on a timer forever". `MCPFeedSource` still goes through
/// `callAllowedTool`, so a binding can never widen what may be called — a tool
/// bound but not allowed simply fails closed.
struct MCPFeedToolBinding: Codable, Equatable, Identifiable {
    var tool: String
    /// Arguments for the call, as a JSON object literal. `{}` — not `nil` — is
    /// the default: strict (zod-validated) servers reject a missing `arguments`
    /// field with "expected object, received undefined".
    ///
    /// This is the one field on this config a user could put a secret in, and it
    /// persists in plain text like everything else here. Settings says so
    /// inline; credentials belong in `httpAuth` / the Keychain, not in a call.
    var argumentsJSON: String = "{}"

    var id: String { tool }

    init(tool: String, argumentsJSON: String = "{}") {
        self.tool = tool
        self.argumentsJSON = argumentsJSON
    }
    // Parsing `argumentsJSON` into SDK `Value`s lives in MCPFeedSource.swift so
    // this file — the persisted, auditable, secret-free config — stays free of
    // the MCP SDK.
}

struct MCPProbeRecord: Codable, Equatable {
    var date: Date
    var toolCount: Int
    /// Tool names that declare an outputSchema (from tools/list — no call needed).
    var toolsWithOutputSchema: [String]
    /// Last debug-run result, if the user has run an allowed tool.
    var lastRunTool: String?
    var lastRunReturnedStructuredContent: Bool?
}

struct MCPServerConfig: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var transport: MCPTransportConfig
    /// Per-TOOL read-only allowlist. Default empty = default-deny.
    var allowedTools: Set<String> = []
    /// GW-291/292: outbound auth for `.http` servers. nil = dynamic client
    /// registration (the pre-GW-291 default; legacy configs decode to nil).
    var httpAuth: MCPHTTPAuth?
    var isEnabled: Bool = true
    /// GW-214: tools whose results render as ambient feed cards.
    ///
    /// OPTIONAL, and it has to stay that way. Swift's synthesized `Codable` does
    /// NOT fall back to a property's default value for a missing key, and
    /// `MCPServerConfigStore.load` decodes with `try?` — so a non-optional new
    /// key would fail to decode every pre-GW-214 `mcp-servers.json` and silently
    /// wipe the user's entire server list on upgrade. Same reason `httpAuth` is
    /// optional. Read it through `feedBindings`.
    var feedTools: [MCPFeedToolBinding]?
    /// Trust gate for stdio (spawning = code execution). Holds the exact
    /// command signature the user approved; nil or mismatch = won't spawn.
    var trustedCommandSignature: String?
    /// Absolute executable path resolved at add-time against the login-shell PATH.
    var resolvedExecutablePath: String?
    var lastProbe: MCPProbeRecord?

    /// Canonical signature of what would be executed. Any edit to the
    /// command line changes this and invalidates prior trust.
    var commandSignature: String? {
        guard case .stdio(let command, let arguments, _) = transport else { return nil }
        return ([command] + arguments).joined(separator: "\u{1F}")
    }

    /// Non-optional view of `feedTools`, filtered to bindings that could
    /// actually run: a tool dropped from the allowlist stops feeding rather than
    /// producing a card that fails closed on every poll.
    var feedBindings: [MCPFeedToolBinding] {
        (feedTools ?? []).filter { allowedTools.contains($0.tool) }
    }

    var isTrusted: Bool {
        switch transport {
        case .http: return true  // no code execution on our machine
        case .stdio: return trustedCommandSignature != nil && trustedCommandSignature == commandSignature
        }
    }
}
