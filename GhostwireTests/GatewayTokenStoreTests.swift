//
//  GatewayTokenStoreTests.swift
//  GhostwireTests
//
//  GW-308: the gateway bearer token must be STABLE across launches and builds so
//  a `claude mcp add` registration never goes stale. These tests pin the
//  file → keychain(migrate) → mint precedence and the anti-rotation no-op.
//

import XCTest

@testable import Ghostwire

final class GatewayTokenStoreTests: XCTestCase {
    private var tempURL: URL!

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw308-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("gateway-token")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
    }

    private func store(keychain: MCPSecretStore = InMemoryMCPSecretStore()) -> GatewayTokenStore {
        GatewayTokenStore(fileURL: tempURL, keychain: keychain)
    }

    private func store(
        keychain: MCPSecretStore = InMemoryMCPSecretStore(),
        temporaryName: @escaping @Sendable (String) -> String
    ) -> GatewayTokenStore {
        GatewayTokenStore(fileURL: tempURL, keychain: keychain, temporaryName: temporaryName)
    }

    private func fileContents() -> String? {
        (try? Data(contentsOf: tempURL)).flatMap { String(data: $0, encoding: .utf8) }
    }

    // 1. File is the source of truth — wins over a different Keychain value.
    func testFileTokenTakesPrecedenceOverKeychain() {
        try? FileManager.default.createDirectory(
            at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("from-file".utf8).write(to: tempURL)
        let keychain = InMemoryMCPSecretStore()
        keychain.setString("from-keychain", account: MCPSecretAccount.gatewayToken)

        XCTAssertEqual(store(keychain: keychain).loadOrCreate(), "from-file")
    }

    // 2. Migration: no file yet, Keychain has a token → return it AND persist to
    //    the file, so an already-registered host keeps its existing token.
    func testMigratesKeychainTokenToFilePreservingValue() {
        let keychain = InMemoryMCPSecretStore()
        keychain.setString("legacy-token", account: MCPSecretAccount.gatewayToken)

        let token = store(keychain: keychain).loadOrCreate()

        XCTAssertEqual(token, "legacy-token")
        XCTAssertEqual(fileContents(), "legacy-token")  // value preserved on disk
    }

    // 3. Mint: nothing anywhere → a non-empty token is generated and persisted;
    //    a second load returns the same (stable).
    func testMintsAndPersistsWhenNothingExists() {
        let s = store()
        let first = s.loadOrCreate()
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(fileContents(), first)
        XCTAssertEqual(s.loadOrCreate(), first)  // reused, not regenerated
    }

    // 4. Anti-rotation: with a file present, the token never changes and the file
    //    is left untouched (the core regression guard for GW-308).
    func testNoOpWhenFileAlreadyPresent() {
        try? FileManager.default.createDirectory(
            at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("stable".utf8).write(to: tempURL)
        let s = store()

        XCTAssertEqual(s.loadOrCreate(), "stable")
        XCTAssertEqual(s.loadOrCreate(), "stable")
        XCTAssertEqual(fileContents(), "stable")
    }

    // 5. Two stores over the same file resolve to the same token (survives the
    //    app being relaunched / rebuilt).
    func testStableAcrossInstances() {
        let keychain = InMemoryMCPSecretStore()
        let first = GatewayTokenStore(fileURL: tempURL, keychain: keychain).loadOrCreate()
        let second = GatewayTokenStore(fileURL: tempURL, keychain: keychain).loadOrCreate()
        XCTAssertEqual(first, second)
    }

    // 6. A blank file is treated as absent → falls through to mint.
    func testEmptyFileFallsThroughToMint() {
        try? FileManager.default.createDirectory(
            at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("   \n".utf8).write(to: tempURL)

        let token = store().loadOrCreate()
        XCTAssertFalse(token.isEmpty)
        XCTAssertEqual(token.trimmingCharacters(in: .whitespacesAndNewlines), token)
    }

    // MARK: - Storage posture
    //
    // The token trades Keychain for a plaintext file, so owner-only perms are the
    // whole remaining protection. These pin it.

    private func permissions(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).intValue
    }

    // 7. A minted token lands owner-only, in an owner-only directory.
    func testMintedTokenFileIsOwnerOnly() throws {
        _ = store().loadOrCreate()

        XCTAssertEqual(try permissions(of: tempURL), 0o600)
        XCTAssertEqual(try permissions(of: tempURL.deletingLastPathComponent()), 0o700)
    }

    // 8. Replacing a pre-existing world-readable file still lands 0600 — the
    //    regression guard for the chmod-after-atomic-write window, where the token
    //    was briefly observable at 0644 at its final path.
    func testReplacingALooseFileStillLandsOwnerOnly() throws {
        let dir = tempURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("loose".utf8).write(to: tempURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tempURL.path)

        // Migration is the path that overwrites an existing file.
        let keychain = InMemoryMCPSecretStore()
        keychain.setString("legacy-token", account: MCPSecretAccount.gatewayToken)
        try Data("".utf8).write(to: tempURL)  // blank → falls through to migration
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tempURL.path)

        XCTAssertEqual(store(keychain: keychain).loadOrCreate(), "legacy-token")
        XCTAssertEqual(try permissions(of: tempURL), 0o600)
    }

    // 9. Upgrade path: the MCP directory already exists at 0755 (it predates
    //    GW-308 and is shared with ToolUsageStore) and a token file is already
    //    present, so nothing is written — the read path still has to tighten it.
    func testTightensPreExistingDirectoryOnReadPath() throws {
        let dir = tempURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("already-registered".utf8).write(to: tempURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)

        XCTAssertEqual(store().loadOrCreate(), "already-registered")  // token untouched
        XCTAssertEqual(try permissions(of: dir), 0o700)
    }

    // 10. The atomic temp file is never left behind — a stray copy of the token
    //    beside the real one would defeat the perms work above.
    func testLeavesNoTemporaryFilesBehind() throws {
        _ = store().loadOrCreate()

        let dir = tempURL.deletingLastPathComponent()
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(entries, [tempURL.lastPathComponent])
    }

    func testUnreadableExistingFileIsNotClobberedWithFreshToken() throws {
        let dir = tempURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("registered-token".utf8).write(to: tempURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: tempURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
        }

        let loaded = store().loadOrCreate()

        XCTAssertFalse(loaded.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
        XCTAssertEqual(fileContents(), "registered-token")
    }

    func testTemporarySymlinkIsNotFollowedWhenWritingToken() throws {
        let dir = tempURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let victim = dir.appendingPathComponent("victim.txt")
        try Data("do-not-touch".utf8).write(to: victim)
        let tempName = ".gateway-token.fixed"
        let temp = dir.appendingPathComponent(tempName)
        try FileManager.default.createSymbolicLink(at: temp, withDestinationURL: victim)

        let keychain = InMemoryMCPSecretStore()
        keychain.setString("legacy-token", account: MCPSecretAccount.gatewayToken)

        let loaded = store(keychain: keychain) { _ in tempName }.loadOrCreate()

        XCTAssertEqual(loaded, "legacy-token")
        let victimContents = try String(contentsOf: victim, encoding: .utf8)
        XCTAssertEqual(victimContents, "do-not-touch")
        XCTAssertNil(fileContents(), "write should fail closed instead of following a symlink")
    }
}
