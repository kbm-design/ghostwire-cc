//
//  ConnectorCatalog.swift
//  Ghostwire
//
//  GW-332 §2 / GW-449: the browsable list of hosted MCP servers the Connections
//  pane offers when you have nothing configured yet.
//
//  An entry is DATA, not an integration. GW-291/292 already handle both auth
//  shapes, and a tier-1 server connects with `httpAuth = nil` because the
//  swift-sdk performs dynamic client registration (RFC 7591) on its own — so
//  adding a connector to this catalog is adding a row to a JSON file, and there
//  is no per-server code anywhere in the app.
//
//  THE SECURITY LINE: this file is fetched from the network, so it may only
//  ever carry NAMES, URLS AND LABELS. `ConnectorCatalogEntry` has no field that
//  can describe something executable, and `Codable` drops unknown keys — so a
//  hostile or compromised catalog cannot introduce an stdio command even if it
//  ships one. That is a structural guarantee, not a check to remember: don't
//  add a command/args/env field to this model. Local servers are added by hand
//  through `MCPAddServerSheet`, behind the GW-219 trust gate, and that stays
//  the only path by which Ghostwire will ever spawn a process.
//
//  Verification status is deliberately carried, not assumed: every entry ships
//  `verified: false` until GW-448 measures a real OAuth round trip against it.
//  Nothing has been connected end-to-end from Ghostwire yet.
//

import Combine
import Foundation

// MARK: - Model

/// The tile a connector renders as: a rounded square holding either a bundled
/// brand mark or, failing that, a letter.
///
/// **The tile survives having a real logo.** Several of these marks are
/// monochrome black (Vercel, Notion, Resend) and would disappear on the pane's
/// black ground, so the logo goes INSIDE the tile rather than replacing it.
///
/// `tint` is the load-bearing distinction. A monochrome mark is template-
/// rendered in `foreground` and keeps its brand-coloured tile. A self-coloured
/// mark (Figma's five colours, PostHog's blue/orange/yellow, Cloudflare's
/// orange-and-white) must render as authored and therefore needs a NEUTRAL
/// tile — tinting it would flatten it to a silhouette, and a brand-coloured
/// tile would swallow the parts that match it.
struct ConnectorIcon: Codable, Equatable, Sendable {
    /// One or two characters. The fallback whenever `asset` is absent — which
    /// is every hand-added server, and any catalog entry whose logo we don't
    /// have yet. Longer values are the catalog's mistake to make; the card
    /// clips rather than reflows.
    let monogram: String
    /// Asset-catalog name of a bundled SVG (`connector-<id>`). Bundled, never
    /// fetched: pulling 17 images from 17 vendor hosts on pane open would tell
    /// each of them you opened the pane, which the local-first principle in
    /// AGENTS.md rules out.
    let asset: String?
    /// True = template-render in `foreground` (monochrome marks only).
    let tint: Bool?
    let background: String?
    let foreground: String?
    /// Only for near-black tiles, which would otherwise vanish into the pane's
    /// black ground (Railway).
    let border: String?
}

struct ConnectorCatalogEntry: Codable, Equatable, Identifiable, Sendable {
    /// Stable slug. The dedupe key across catalog revisions — NOT the display
    /// name, which a vendor can rebrand.
    let id: String
    let name: String
    let endpoint: URL
    /// ~3 words. The grid is 3-across in a 920pt window, which leaves ~207pt
    /// per card; anything longer truncates. See GW-449.
    let blurb: String
    let category: String?
    /// 1 = one-click (DCR) · 2 = needs our client_id · 0 = no auth.
    /// Carried as data so widening the catalog doesn't need a new file format.
    /// **Nothing renders it yet** — the tier treatment is undesigned (GW-450).
    let tier: Int?
    /// False until a real end-to-end connect has been measured (GW-448).
    let verified: Bool?
    /// Monogram tile. Absent, or absent a colour, falls back to the neutral
    /// tile — see `ConnectorIcon`.
    let icon: ConnectorIcon?
}

struct ConnectorCatalogFile: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let generated: String?
    let connectors: [ConnectorCatalogEntry]
}

// MARK: - Store

@MainActor
final class ConnectorCatalog: ObservableObject {
    static let shared = ConnectorCatalog()

    /// Hosted beside the appcast in the public `ghostwire-releases` repo
    /// (GW-215) — already CDN-backed and already pushed to, so "refresh the
    /// catalog" is a commit rather than a service. Note the raw feed is
    /// CDN-cached for a few minutes after a push.
    static let remoteURL = URL(
        string: "https://raw.githubusercontent.com/Ghostwire-Design/ghostwire-releases/main/catalog.json"
    )!

    /// The highest `schemaVersion` this build understands. A remote file above
    /// it is ignored entirely rather than partially decoded — an old build must
    /// fall back to its bundled copy, not guess at a format it has never seen.
    static let supportedSchemaVersion = 1

    /// A corrupt or hostile file can't turn the grid into an allocation bomb.
    static let maxEntries = 500

    private static let minimumRefreshInterval: TimeInterval = 60 * 60 * 24

    @Published private(set) var entries: [ConnectorCatalogEntry] = []

    private let cacheURL: URL
    private let session: URLSession
    private var isRefreshing = false

    /// `nonisolated` because it backs a default argument, which is evaluated in
    /// the *caller's* isolation — a MainActor-isolated static there is an error
    /// under the Swift 6 language mode.
    nonisolated static let defaultCacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ghostwire")
        .appendingPathComponent("catalog.json")

    init(cacheURL: URL = ConnectorCatalog.defaultCacheURL, session: URLSession = .shared) {
        self.cacheURL = cacheURL
        self.session = session
        entries = Self.loadLocal(cacheURL: cacheURL)
    }

    // MARK: - Load

    /// Cache first, bundled second. The bundled copy is the floor: it ships with
    /// the app, so the pane is never empty offline or on first launch.
    private static func loadLocal(cacheURL: URL) -> [ConnectorCatalogEntry] {
        if let data = try? Data(contentsOf: cacheURL),
            let cached = decode(data)
        {
            return cached
        }
        return bundled()
    }

    static func bundled() -> [ConnectorCatalogEntry] {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let decoded = decode(data)
        else {
            // A missing bundled catalog is a build mistake (the file lives in
            // the synced Resources group), not a runtime condition — but the
            // pane degrades to "add manually" rather than failing.
            assertionFailure("ConnectorCatalog: bundled catalog.json missing or unreadable")
            return []
        }
        return decoded
    }

    /// Decode + validate. Returns nil for a file this build shouldn't use at
    /// all; drops individual entries that fail their own checks.
    static func decode(_ data: Data) -> [ConnectorCatalogEntry]? {
        guard let file = try? JSONDecoder().decode(ConnectorCatalogFile.self, from: data) else {
            return nil
        }
        guard file.schemaVersion == supportedSchemaVersion else { return nil }

        var seen = Set<String>()
        var result: [ConnectorCatalogEntry] = []
        for entry in file.connectors {
            guard result.count < maxEntries else { break }
            // https only. A catalog is fetched over the network, so it must not
            // be able to point the client at a plaintext endpoint (credentials
            // ride these connections) or at a non-network scheme.
            guard entry.endpoint.scheme?.lowercased() == "https" else { continue }
            guard entry.endpoint.host?.isEmpty == false else { continue }
            guard !entry.id.isEmpty, !entry.name.isEmpty else { continue }
            guard seen.insert(entry.id).inserted else { continue }
            result.append(entry)
        }
        return result
    }

    // MARK: - Refresh

    /// Fetches the hosted catalog and caches it. Silent on every failure: a
    /// catalog that can't be reached is not an error the user can act on, and
    /// the bundled copy already answers the question the pane is asking.
    func refreshIfStale() async {
        guard NSClassFromString("XCTestCase") == nil else { return }
        guard !isRefreshing else { return }
        if let modified = try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date,
            Date().timeIntervalSince(modified) < Self.minimumRefreshInterval
        {
            return
        }
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var request = URLRequest(url: Self.remoteURL)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let decoded = Self.decode(data)
        else { return }

        // Only overwrite the cache with a file that survived validation, so a
        // truncated or rejected fetch can never replace a good local copy.
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
        entries = decoded
    }
}
