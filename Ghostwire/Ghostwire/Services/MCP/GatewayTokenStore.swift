//
//  GatewayTokenStore.swift
//  Ghostwire
//
//  GW-308: single source of truth for the gateway's bearer token.
//
//  The token is a STATIC, long-lived, shared secret: the host (Claude Code)
//  stores it in plaintext in ~/.claude.json and never refreshes it, so it must
//  stay STABLE across launches AND across builds. Keychain was the wrong bucket
//  — its ACL is signing-identity-scoped, so an ad-hoc/dev build can't read a
//  release build's item, reads nil, and mints a fresh token → the registered
//  token goes stale (HTTP 401, "not connected"). We keep the token in a plaintext
//  Application Support file (same trust level as the host config that already
//  holds it; the endpoint is localhost-only + token-gated). Keychain remains a
//  one-time, non-destructive migration source so already-registered installs
//  keep their existing token. Real secrets (downstream OAuth/API keys) stay in
//  Keychain — only this shared, plaintext-consumed token moves to a file.
//
//  STORAGE POSTURE. Losing Keychain means file permissions are the only
//  remaining protection, so the token is owner-only (0600) in an owner-only
//  directory (0700) for its entire visible life — see `writeFile`. That sits
//  under `~/Library/Application Support` (0700) inside `~` (0750), so another
//  local user is already blocked by traversal; the explicit perms are defence in
//  depth. What is deliberately NOT defended against is a process running as this
//  user, which could read `~/.claude.json` for the same token anyway.
//

import Foundation
import OSLog

struct GatewayTokenStore {
    static let log = Logger(subsystem: "com.ghostwire.notch", category: "mcp-gateway-token")

    let fileURL: URL
    let keychain: MCPSecretStore

    /// `Application Support/Ghostwire/MCP/gateway-token` — same canonical root as
    /// the gateway's sibling stores (ToolUsageStore, ShelfPersistenceService).
    static let canonicalURL: URL = {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return support
            .appendingPathComponent("Ghostwire", isDirectory: true)
            .appendingPathComponent("MCP", isDirectory: true)
            .appendingPathComponent("gateway-token")
    }()

    init(fileURL: URL = GatewayTokenStore.canonicalURL,
         keychain: MCPSecretStore = KeychainMCPSecretStore.shared) {
        self.fileURL = fileURL
        self.keychain = keychain
    }

    /// File → Keychain (one-time migration) → mint. Idempotent: never rewrites a
    /// token that already exists in the file, so a registered host keeps working.
    func loadOrCreate() -> String {
        // Runs on the read path too, not just on write: an install that already
        // has a token file never calls `writeFile` again, so this is the only
        // place its directory posture gets corrected.
        ensureDirectoryPosture()

        // 1. File is the source of truth.
        if let token = readFile(), !token.isEmpty { return token }

        // 2. One-time, non-destructive migration: preserve an existing Keychain
        //    token so an already-registered host keeps working. Leave the
        //    Keychain item in place (harmless).
        if let legacy = keychain.string(account: MCPSecretAccount.gatewayToken), !legacy.isEmpty {
            // A failure here is self-healing: the token is still in Keychain, so
            // the next launch retries the migration.
            if !writeFile(legacy) {
                Self.log.error("Could not persist migrated gateway token to \(fileURL.path, privacy: .public)")
            }
            return legacy
        }

        // 3. First run anywhere: mint once and persist.
        let token = UUID().uuidString
        if !writeFile(token) {
            // This is the GW-308 failure mode itself: an unpersisted token works
            // for this launch and rotates on the next one, silently orphaning the
            // host's registration. Nothing to fall back to — say so loudly.
            Self.log.error(
                "Minted gateway token could not be persisted to \(fileURL.path, privacy: .public) — it WILL rotate on next launch and break an existing MCP registration")
        }
        return token
    }

    /// Owner-only directory, created if absent. `createDirectory` only applies
    /// attributes to directories it actually creates, and this one already exists
    /// at 0755 on any install that shipped before GW-308 (it is shared with
    /// ToolUsageStore), so the explicit `setAttributes` is what fixes upgrades.
    private func ensureDirectoryPosture() {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try? fm.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    private func readFile() -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Atomic, and owner-only for the token's whole visible life. Returns whether
    /// the token actually reached disk — an unpersisted token is the GW-308 bug.
    ///
    /// `Data.write(options: .atomic)` renames a temp file into place, and that temp
    /// inherits the umask (observed 0644), so narrowing with a `chmod` *afterwards*
    /// leaves a window where the token is world-readable at its final path. Instead
    /// we create the temp at 0600 up front and rename that inode into place, so the
    /// destination is never observable at looser perms. `.usingNewMetadataOnly`
    /// makes the 0600 win even when replacing a pre-existing loose file.
    private func writeFile(_ token: String) -> Bool {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        ensureDirectoryPosture()

        let temp = dir.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString)")
        guard fm.createFile(
            atPath: temp.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        else { return false }

        do {
            _ = try fm.replaceItemAt(fileURL, withItemAt: temp, options: [.usingNewMetadataOnly])
            return true
        } catch {
            try? fm.removeItem(at: temp)  // never leave a readable stray behind
            return false
        }
    }
}
