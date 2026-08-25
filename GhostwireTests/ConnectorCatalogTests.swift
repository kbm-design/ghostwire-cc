import AppKit
import XCTest

@testable import Ghostwire

/// GW-332 §2 / GW-449.
///
/// `ConnectorCatalog.decode` is the trust boundary for a file fetched off the
/// network, so most of what's here is about what it REFUSES. The shipped
/// catalog is checked too — a bad blurb or a broken endpoint in `catalog.json`
/// is a shipping defect, not a data-entry one, because the pane renders it
/// verbatim.
@MainActor
final class ConnectorCatalogTests: XCTestCase {

    private func file(
        schemaVersion: Int = ConnectorCatalog.supportedSchemaVersion,
        connectors: [[String: Any]]
    ) -> Data {
        let object: [String: Any] = [
            "schemaVersion": schemaVersion,
            "generated": "2026-08-21",
            "connectors": connectors,
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func entry(
        id: String = "example",
        name: String = "Example",
        endpoint: String = "https://mcp.example.com/mcp",
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var object: [String: Any] = [
            "id": id, "name": name, "endpoint": endpoint, "blurb": "Does a thing",
        ]
        object.merge(extra) { _, new in new }
        return object
    }

    // MARK: - The shipped catalog

    /// The bundled file is the offline floor — if it doesn't decode, the pane is
    /// empty on first launch for everyone.
    func testBundledCatalogDecodes() throws {
        let url = try XCTUnwrap(
            Bundle(for: type(of: self)).url(forResource: "catalog", withExtension: "json")
                ?? Bundle.main.url(forResource: "catalog", withExtension: "json"),
            "catalog.json is not in the bundle — check it's under the synced Resources group"
        )
        let entries = try XCTUnwrap(ConnectorCatalog.decode(try Data(contentsOf: url)))
        XCTAssertFalse(entries.isEmpty)

        for entry in entries {
            XCTAssertEqual(entry.endpoint.scheme, "https", "\(entry.name) endpoint must be https")
            // 3-across at 920pt leaves ~207pt per card, of which card chrome
            // (padding, icon, trailing slot, gaps) takes 94 — so the text lane
            // is ~112pt ≈ 18 characters at 11pt.
            //
            // This was a WORD count first and that was wrong: "Designs and
            // templates" is three words and truncated on a real screen. Count
            // characters, and don't relax this without re-measuring the lane.
            XCTAssertLessThanOrEqual(
                entry.blurb.count, 18,
                "\(entry.name) blurb “\(entry.blurb)” is \(entry.blurb.count) chars — "
                    + "the card truncates past 18")
        }
        XCTAssertEqual(
            Set(entries.map(\.id)).count, entries.count, "catalog.json has duplicate ids")
    }

    /// Every shipped connector carries a real bundled logo, and the asset it
    /// names actually exists.
    ///
    /// Airtable, Asana, Cal.com and Retool were CUT from the catalog rather
    /// than shipped on a letter tile (Keelan's call, 2026-08-21) — a grid where
    /// some cards are brand marks and others are grey initials reads as broken
    /// rather than as incomplete. The monogram path stays in
    /// `ConnectorIconTile` because hand-added servers (qmd, figma-desktop) will
    /// always need it; it just isn't a state the CATALOG may ship.
    ///
    /// Re-add those four the moment a square symbol exists for them.
    func testEveryCatalogEntryHasABundledLogo() throws {
        let url = try XCTUnwrap(
            Bundle(for: type(of: self)).url(forResource: "catalog", withExtension: "json")
                ?? Bundle.main.url(forResource: "catalog", withExtension: "json"))
        let entries = try XCTUnwrap(ConnectorCatalog.decode(try Data(contentsOf: url)))

        for entry in entries {
            let asset = try XCTUnwrap(
                entry.icon?.asset,
                "\(entry.name) has no logo — cut it from the catalog rather than "
                    + "shipping a monogram tile beside real brand marks")
            XCTAssertNotNil(
                NSImage(named: asset),
                "\(entry.name) names asset “\(asset)” which isn't in Assets.xcassets")
        }
    }

    /// GW-448 measured every entry (2026-08-25, docs/gw448-connector-verification.md).
    /// `verified: true` is allowed ONLY for the servers that completed the whole
    /// chain — DCR → loopback OAuth → tools/list → one real read-only
    /// `tools/call` through `callAllowedTool`. "Connected" alone (Cloudflare,
    /// PostHog: no zero-input read-only tool to call) does not qualify. Adding
    /// a name here without a measured pass is the claim the ticket exists to stop.
    func testBundledCatalogVerifiedMatchesMeasuredPasses() throws {
        let url = try XCTUnwrap(
            Bundle(for: type(of: self)).url(forResource: "catalog", withExtension: "json")
                ?? Bundle.main.url(forResource: "catalog", withExtension: "json"))
        let entries = try XCTUnwrap(ConnectorCatalog.decode(try Data(contentsOf: url)))
        let measuredPasses: Set<String> = [
            "canva", "granola", "linear", "notion", "railway", "resend", "vercel",
        ]
        XCTAssertEqual(Set(entries.filter { $0.verified == true }.map(\.id)), measuredPasses)
    }

    // MARK: - What it refuses

    /// The structural guarantee: a remote catalog cannot introduce something
    /// executable, because the model has nowhere to put it. If this test ever
    /// needs changing, the change is wrong.
    func testExecutableFieldsAreDroppedEntirely() throws {
        let data = file(connectors: [
            entry(extra: [
                "command": "npx",
                "args": ["-y", "@evil/server"],
                "env": ["TOKEN": "hunter2"],
                "transport": "stdio",
            ])
        ])
        let entries = try XCTUnwrap(ConnectorCatalog.decode(data))
        XCTAssertEqual(entries.count, 1)
        // It survives as a hosted entry with its URL — and nothing else came along.
        XCTAssertEqual(entries[0].endpoint.absoluteString, "https://mcp.example.com/mcp")
        let mirrored = Mirror(reflecting: entries[0]).children.compactMap(\.label)
        for forbidden in ["command", "args", "env", "transport", "arguments"] {
            XCTAssertFalse(
                mirrored.contains(forbidden),
                "ConnectorCatalogEntry grew a \(forbidden) field — a network-fetched file "
                    + "must never be able to describe something that runs")
        }
    }

    func testNonHTTPSEndpointsAreDropped() throws {
        let data = file(connectors: [
            entry(id: "plaintext", endpoint: "http://mcp.example.com/mcp"),
            entry(id: "file", endpoint: "file:///tmp/evil"),
            entry(id: "good", endpoint: "https://mcp.example.com/mcp"),
        ])
        let entries = try XCTUnwrap(ConnectorCatalog.decode(data))
        XCTAssertEqual(entries.map(\.id), ["good"])
    }

    /// A build must not partially decode a format it has never seen — it falls
    /// back to its bundled copy instead.
    func testFutureSchemaVersionIsRejectedWholesale() {
        let data = file(
            schemaVersion: ConnectorCatalog.supportedSchemaVersion + 1,
            connectors: [entry()])
        XCTAssertNil(ConnectorCatalog.decode(data))
    }

    func testDuplicateIDsKeepTheFirstOnly() throws {
        let data = file(connectors: [
            entry(id: "linear", name: "Linear"),
            entry(id: "linear", name: "Linear (impostor)", endpoint: "https://evil.example/mcp"),
        ])
        let entries = try XCTUnwrap(ConnectorCatalog.decode(data))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "Linear")
    }

    func testEmptyIdentityIsDropped() throws {
        let data = file(connectors: [
            entry(id: "", name: "No id"),
            entry(id: "no-name", name: ""),
            entry(id: "fine", name: "Fine"),
        ])
        let entries = try XCTUnwrap(ConnectorCatalog.decode(data))
        XCTAssertEqual(entries.map(\.id), ["fine"])
    }

    func testEntryCountIsCapped() throws {
        let over = ConnectorCatalog.maxEntries + 50
        let data = file(connectors: (0..<over).map { entry(id: "server-\($0)") })
        let entries = try XCTUnwrap(ConnectorCatalog.decode(data))
        XCTAssertEqual(entries.count, ConnectorCatalog.maxEntries)
    }

    func testGarbageIsRejected() {
        XCTAssertNil(ConnectorCatalog.decode(Data("not json".utf8)))
        XCTAssertNil(ConnectorCatalog.decode(Data()))
        XCTAssertNil(ConnectorCatalog.decode(Data("{}".utf8)))
    }
}
