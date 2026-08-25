//
//  SensitiveClipAccess.swift
//  Ghostwire
//
//  GW-166: the ONE gate in front of a sealed clip's plaintext. Reveal, copy,
//  paste-to-field, send-to-agent and "Not sensitive" all funnel through
//  `plaintext(for:reason:)` — so there is a single place to audit, and no way to
//  add an action that quietly skips the prompt.
//
//  AUTH: `LAPolicy.deviceOwnerAuthentication` — Touch ID where available, with
//  the account password as the fallback the policy provides for free (the
//  ticket's "Touch ID, password fallback"). Behind the `LocalAuthenticating`
//  seam so tests never see a prompt.
//
//  GRACE WINDOW: after a successful unlock an entry stays open for
//  `graceInterval` (2 min). Without it, "reveal, read it, copy it" costs two
//  prompts and users learn to hate the feature. The window is per-entry, held in
//  memory only, and never persisted — a relaunch re-locks everything.
//
//  NOTCH WINDOW LEVEL: the notch panel outranks system panels, so anything modal
//  raised while it is open risks rendering behind it. The auth call is bracketed
//  with `SharingStateManager.begin/endInteraction()` so the notch at least can't
//  dismiss itself mid-prompt (the QuickShareService idiom).
//
//  TEST SAFETY: `DeviceOwnerAuthenticator` hard-refuses under XCTest — the test
//  host is the live app (GW-444), and a suite that raises a Touch ID sheet hangs
//  CI forever.
//

import Foundation
import LocalAuthentication
import os

// MARK: - Authentication seam

protocol LocalAuthenticating: AnyObject {
    /// Prompt the device owner. Returns false on cancel, lockout, or any error —
    /// the caller treats every falsy outcome identically (fail closed).
    func authenticate(reason: String) async -> Bool
}

/// Touch ID with the system's own password fallback.
final class DeviceOwnerAuthenticator: LocalAuthenticating {
    static let shared = DeviceOwnerAuthenticator()

    private static let logger = Logger(subsystem: "com.ghostwire.notch", category: "sensitive-clip")

    func authenticate(reason: String) async -> Bool {
        // Never raise a biometric sheet from the test host (GW-444).
        guard NSClassFromString("XCTestCase") == nil else { return false }

        let context = LAContext()
        // `.deviceOwnerAuthentication` already falls back to the account
        // password, so no custom fallback title is needed or wanted.
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            Self.logger.error("no auth policy available: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            return false
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}

/// Test double. `result` decides every outcome; `callCount` proves the grace
/// window actually suppresses repeat prompts.
final class StubAuthenticator: LocalAuthenticating {
    var result: Bool
    private(set) var callCount = 0

    init(result: Bool) { self.result = result }

    func authenticate(reason: String) async -> Bool {
        callCount += 1
        return result
    }
}

// MARK: - Access coordinator

@MainActor
final class SensitiveClipAccess {
    static let shared = SensitiveClipAccess()

    /// How long one successful unlock keeps an entry open.
    static let graceInterval: TimeInterval = 120

    private let authenticator: LocalAuthenticating
    private let store: ClipboardHistoryStore
    /// entry id -> when its unlock expires. In memory only, by design.
    private var unlockedUntil: [UUID: Date] = [:]

    init(
        authenticator: LocalAuthenticating = DeviceOwnerAuthenticator.shared,
        store: ClipboardHistoryStore = .shared
    ) {
        self.authenticator = authenticator
        self.store = store
    }

    // MARK: - Gate

    /// Plaintext for `entry`, prompting first unless the entry is inside its
    /// grace window. Nil when auth failed/was cancelled, or when the clip can't
    /// be decrypted (missing key). A non-sensitive entry passes straight through
    /// so callers don't need to branch.
    func plaintext(for entry: ClipboardEntry, reason: String) async -> String? {
        guard entry.isSensitive else { return store.plaintext(of: entry) }

        if !isUnlocked(entry.id) {
            SharingStateManager.shared.beginInteraction()
            let ok = await authenticator.authenticate(reason: reason)
            SharingStateManager.shared.endInteraction()
            guard ok else { return nil }
            noteUnlocked(entry.id)
        }
        return store.plaintext(of: entry)
    }

    // MARK: - Grace window (pure enough to test directly)

    func isUnlocked(_ id: UUID, now: Date = Date()) -> Bool {
        guard let expiry = unlockedUntil[id] else { return false }
        if expiry > now { return true }
        unlockedUntil[id] = nil
        return false
    }

    func noteUnlocked(_ id: UUID, now: Date = Date()) {
        // Opportunistic sweep: entries deleted while unlocked would otherwise
        // linger here until something asked about them by id.
        unlockedUntil = unlockedUntil.filter { $0.value > now }
        unlockedUntil[id] = now.addingTimeInterval(Self.graceInterval)
    }

    /// Close one entry's window early (the "Hide" affordance on a revealed card).
    func relock(_ id: UUID) { unlockedUntil[id] = nil }

    /// Close every window — history cleared, or the surface went away.
    func relockAll() { unlockedUntil.removeAll() }
}
