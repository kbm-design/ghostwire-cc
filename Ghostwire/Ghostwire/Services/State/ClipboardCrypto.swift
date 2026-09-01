//
//  ClipboardCrypto.swift
//  Ghostwire
//
//  GW-166: encryption-at-rest for credential-shaped clips. Two pieces:
//
//    • `ClipboardKeyStore` — where the 256-bit key lives. The real one is a
//      Keychain generic-password item under service "com.ghostwire.clipboard"
//      (the MCPSecretStore idiom), created on first use.
//    • `ClipboardSealer`   — pure AES-256-GCM seal/open + a keyed fingerprint,
//      unit-testable against a literal key with no Keychain in sight.
//
//  KEY ACCESSIBILITY: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
//  `ThisDeviceOnly` keeps the key off iCloud Keychain — the clips are local-only
//  by design and a synced key would quietly widen that blast radius.
//  `WhenUnlocked` is right because every read happens behind a Touch ID prompt,
//  which by definition only occurs on an unlocked Mac.
//
//  FINGERPRINT: consecutive-copy dedupe needs to compare two clips, but GCM uses
//  a fresh nonce per seal so two seals of the same plaintext differ. A plain
//  SHA-256 would work, except it is stored in the JSON alongside the ciphertext
//  and a low-entropy secret would be trivially brute-forced from it. So the
//  fingerprint is an HMAC-SHA256 under the same Keychain key: useless without
//  the key, stable for the same plaintext.
//
//  TEST SAFETY: `KeychainClipboardKeyStore` refuses to run under XCTest (the
//  test host is the LIVE app — GW-444), so the suite can never create, read or
//  overwrite the user's real key. Tests inject `InMemoryClipboardKeyStore`.
//

import CryptoKit
import Foundation
import Security

// MARK: - Key store seam

/// Where the clipboard sealing key comes from. One method: the store owns
/// creation, so a caller can never be handed a half-initialised key.
protocol ClipboardKeyStore: AnyObject {
    /// The persistent 256-bit key, creating it on first use. Nil when the key is
    /// unavailable (locked/failed Keychain, or running under XCTest) — callers
    /// MUST fail closed rather than falling back to plaintext.
    func loadOrCreateKey() -> SymmetricKey?
}

final class KeychainClipboardKeyStore: ClipboardKeyStore {
    static let shared = KeychainClipboardKeyStore()

    private let service = "com.ghostwire.clipboard"
    private let account = "clip.sealing.key"
    /// Cached so a scroll through history isn't one Keychain round-trip per row.
    private var cached: SymmetricKey?

    func loadOrCreateKey() -> SymmetricKey? {
        // The XCTest host IS the live app (GW-444): never touch the user's real
        // Keychain item from a test run.
        guard NSClassFromString("XCTestCase") == nil else { return nil }
        if let cached { return cached }
        if let existing = read() {
            cached = existing
            return existing
        }
        let fresh = SymmetricKey(size: .bits256)
        guard store(fresh) else { return nil }
        cached = fresh
        return fresh
    }

    private func read() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    private func store(_ key: SymmetricKey) -> Bool {
        let data = key.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Lost a race with another launch — take whatever is on disk so both
            // processes seal under the same key.
            return read() != nil
        }
        return status == errSecSuccess
    }
}

/// Test double (and preview stand-in). Holds one key for the object's lifetime;
/// never touches the Keychain.
final class InMemoryClipboardKeyStore: ClipboardKeyStore {
    private var key: SymmetricKey?

    init(key: SymmetricKey? = nil) { self.key = key }

    func loadOrCreateKey() -> SymmetricKey? {
        if let key { return key }
        let fresh = SymmetricKey(size: .bits256)
        key = fresh
        return fresh
    }
}

/// Test double for the fail-closed path: no key is ever available.
final class UnavailableClipboardKeyStore: ClipboardKeyStore {
    func loadOrCreateKey() -> SymmetricKey? { nil }
}

// MARK: - Sealing (pure)

enum ClipboardSealer {
    /// AES-256-GCM seal. Returns the `combined` representation (nonce ‖
    /// ciphertext ‖ tag) — one `Data` to persist, self-describing on open.
    static func seal(_ plaintext: String, key: SymmetricKey) -> Data? {
        guard let box = try? AES.GCM.seal(Data(plaintext.utf8), using: key) else { return nil }
        return box.combined
    }

    /// Open a `combined` sealed box. Nil on a wrong key, a truncated box, or a
    /// tag mismatch — all indistinguishable to the caller on purpose.
    static func open(_ sealed: Data, key: SymmetricKey) -> String? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let data = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Keyed, deterministic fingerprint for dedupe. HMAC-SHA256 under the
    /// sealing key, hex, truncated to 128 bits — plenty for equality, and
    /// unusable as a brute-force oracle without the key.
    static func fingerprint(_ plaintext: String, key: SymmetricKey) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(plaintext.utf8), using: key)
        return mac.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
