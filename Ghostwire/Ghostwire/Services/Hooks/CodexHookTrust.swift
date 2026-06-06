//
//  CodexHookTrust.swift
//  Ghostwire
//
//  Detects whether Codex currently trusts the Ghostwire hooks (GW-196).
//
//  Codex gates non-managed command hooks behind a one-time trust step: it
//  records trust against each hook's *current hash* in the `[hooks.state]`
//  section of ~/.codex/config.toml and skips any new-or-changed hook until the
//  user re-trusts it with `/hooks` in the CLI. When our hook command changes
//  (e.g. the buddi-hook.py -> ghostwire-hook.py rename) the previously-trusted
//  hash no longer covers the new command, so Codex silently stops firing it.
//  This is a pure visibility gap — the allow/deny round-trip itself works once
//  the hook is trusted. Users otherwise discover it via dead approvals.
//
//  `[hooks.state]` schema (verified against a real ~/.codex/config.toml @ 0.136.0):
//
//      [hooks.state]
//      [hooks.state."/Users/me/.codex/hooks.json:pre_tool_use:0:0"]
//      trusted_hash = "sha256:42e7…f69c"
//      enabled = true        # optional; absent means trusted-and-enabled
//
//  The dotted key is `<hooks-file-path>:<event_snake_case>:<arrayIndex>:<hookIndex>`:
//    - event name is the snake_case form of the PascalCase hooks.json event
//      (PreToolUse -> pre_tool_use, PermissionRequest -> permission_request)
//    - arrayIndex = position within that event's array in hooks.json
//    - hookIndex  = position within that entry's "hooks" array
//  A changed hook produces a NEW key at the next free index (the trust block is
//  append-only), so a position whose state key is missing has never been trusted.
//
//  Detection strategy — two layers, neither recomputes the hash:
//    The exact bytes Codex feeds into the sha256 are NOT documented and live
//    inside the Codex binary, so we deliberately do NOT try to recompute the
//    hash (guessing it would be fragile and silently wrong).
//
//    1. Coverage. Every Ghostwire hook position present in hooks.json must have
//       a corresponding trusted, not-disabled `[hooks.state]` entry. When a new
//       command lands at a *new* position (state key absent) this drops and we
//       report `.retrustRequired`. This catches new installs and appended hooks.
//
//    2. Installer-anchored stale-trust (GW-196 P1). Coverage alone is fooled by
//       an *in-place* command change: when a Ghostwire hook's command changes at
//       the SAME (event, arrayIndex, hookIndex) position — exactly the
//       buddi -> ghostwire rename — Codex leaves the old state entry in place with
//       its now-stale `trusted_hash`, then silently skips the hook. Coverage sees
//       a trusted entry at that key and wrongly reports `.trusted`.
//       To close this we lean on the installer (which runs every launch): before
//       it rewrites hooks.json it records, per changed position, the stale
//       `trusted_hash` then present in config.toml into a pending re-trust map
//       (see CodexHookInstaller + `Defaults.codexPendingRetrust`). Here, after
//       coverage, we report `.retrustRequired` for any position whose current
//       `trusted_hash` still equals that recorded stale value. Once Codex rewrites
//       the hash (the user re-trusted via `/hooks`), the values diverge and we
//       clear the pending entry and treat the hook as trusted.
//
//    Honest limitation: an in-place command change that happened BEFORE this
//    feature shipped has no recorded stale hash, so it can't be detected
//    retroactively (it looks identical to a genuinely-trusted hook). Acceptable:
//    the installer records on every launch from now on, so the next rename is
//    covered.
//

import Defaults
import Foundation

enum CodexHookTrust {

    /// Trust verdict for the Ghostwire hooks Codex is configured to run.
    enum TrustStatus: Equatable {
        /// Codex isn't set up, or Ghostwire hooks aren't installed yet — there
        /// is nothing to trust. Treated as "not applicable", never as untrusted.
        case notConfigured
        /// Every installed Ghostwire hook has a trusted, enabled state entry.
        case trusted
        /// At least one installed Ghostwire hook lacks a trusted entry (or is
        /// explicitly disabled) — the user must run `/hooks` in Codex to trust it.
        case retrustRequired
    }

    /// Recompute the current trust status from disk. Cheap plain file I/O —
    /// safe to call on settings-window open and after every install run.
    static func currentStatus() -> TrustStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexDir = home.appendingPathComponent(".codex")
        let hooksFile = codexDir.appendingPathComponent("hooks.json")
        let configFile = codexDir.appendingPathComponent("config.toml")

        // Codex not set up at all → nothing to trust.
        guard FileManager.default.fileExists(atPath: codexDir.path) else {
            return .notConfigured
        }

        let hooksJSON = (try? Data(contentsOf: hooksFile))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let configTOML = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""

        // Apply the installer-anchored stale-trust map (GW-196). Pure evaluation
        // returns both the verdict and any pending entries to drop (Codex has
        // since rewritten the hash ⇒ the user re-trusted), which we persist here.
        let pending = Defaults[.codexPendingRetrust]
        let result = evaluate(
            hooksJSON: hooksJSON,
            configTOML: configTOML,
            hooksFilePath: hooksFile.path,
            pendingRetrust: pending
        )
        if !result.clearedKeys.isEmpty {
            var next = pending
            for key in result.clearedKeys { next.removeValue(forKey: key) }
            Defaults[.codexPendingRetrust] = next
        }
        return result.status
    }

    // MARK: - Pure detection (unit-tested over sample inputs)

    /// One installed Ghostwire hook and the `[hooks.state]` key it should map to.
    struct InstalledHook: Equatable {
        let event: String        // PascalCase, as written in hooks.json
        let arrayIndex: Int
        let hookIndex: Int

        /// The `[hooks.state]` dotted key (without the surrounding quotes) for a
        /// given hooks-file path. e.g. "<path>:pre_tool_use:0:0".
        func stateKey(hooksFilePath: String) -> String {
            "\(hooksFilePath):\(CodexHookTrust.snakeCase(event)):\(arrayIndex):\(hookIndex)"
        }
    }

    /// Outcome of a pure trust evaluation: the verdict plus any pending
    /// re-trust keys that should be dropped because Codex has since rewritten
    /// the hash (the user re-trusted). Persistence happens at the caller's edge.
    struct Evaluation: Equatable {
        let status: TrustStatus
        let clearedKeys: [String]
    }

    /// Pure form: derive trust from the parsed hooks.json, the raw config.toml
    /// text, and the absolute hooks-file path used to key state entries.
    /// Convenience wrapper over `evaluate` for callers that only want the
    /// verdict and carry no pending re-trust map (and for coverage-only tests).
    static func status(
        hooksJSON: [String: Any]?,
        configTOML: String,
        hooksFilePath: String,
        pendingRetrust: [String: String] = [:]
    ) -> TrustStatus {
        evaluate(
            hooksJSON: hooksJSON,
            configTOML: configTOML,
            hooksFilePath: hooksFilePath,
            pendingRetrust: pendingRetrust
        ).status
    }

    /// Pure trust evaluation over (hooks.json, config.toml, hooks-file path,
    /// pending re-trust map). Layer 1 is coverage; layer 2 is the
    /// installer-anchored stale-trust check (GW-196) — see the file header.
    static func evaluate(
        hooksJSON: [String: Any]?,
        configTOML: String,
        hooksFilePath: String,
        pendingRetrust: [String: String]
    ) -> Evaluation {
        let installed = ghostwireHooks(in: hooksJSON)
        // No Ghostwire hooks present → nothing for Codex to trust.
        guard !installed.isEmpty else { return Evaluation(status: .notConfigured, clearedKeys: []) }

        let state = parseHooksState(configTOML)
        // No trust block at all yet (e.g. brand-new install, user hasn't opened
        // /hooks once) → the hooks won't fire until trusted.
        guard !state.isEmpty else { return Evaluation(status: .retrustRequired, clearedKeys: []) }

        // Layer 1 — coverage: every installed position needs a trusted entry.
        for hook in installed {
            let key = hook.stateKey(hooksFilePath: hooksFilePath)
            guard let entry = state[key], entry.isTrusted else {
                return Evaluation(status: .retrustRequired, clearedKeys: [])
            }
        }

        // Layer 2 — installer-anchored stale-trust. A pending entry means the
        // installer changed that hook's command in place and saved the
        // trusted_hash that was current at the time. If config.toml still carries
        // that exact stale hash, Codex is skipping the hook → re-trust required.
        // If the hash has since changed, Codex re-trusted the new command; drop
        // the pending entry and keep treating the position as trusted.
        var clearedKeys: [String] = []
        var staleStillPresent = false
        for hook in installed {
            let key = hook.stateKey(hooksFilePath: hooksFilePath)
            guard let staleHash = pendingRetrust[key] else { continue }
            let currentHash = state[key]?.trustedHash
            if currentHash == staleHash {
                staleStillPresent = true
            } else {
                clearedKeys.append(key)
            }
        }

        return Evaluation(
            status: staleStillPresent ? .retrustRequired : .trusted,
            clearedKeys: clearedKeys
        )
    }

    /// Enumerate the Ghostwire hook positions in hooks.json, in the same
    /// (event, arrayIndex, hookIndex) order Codex uses to key `[hooks.state]`.
    static func ghostwireHooks(in json: [String: Any]?) -> [InstalledHook] {
        guard let hooks = json?["hooks"] as? [String: Any] else { return [] }
        var result: [InstalledHook] = []
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            for (arrayIndex, entry) in entries.enumerated() {
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { continue }
                for (hookIndex, hook) in entryHooks.enumerated() {
                    let cmd = hook["command"] as? String ?? ""
                    if isGhostwireHookCommand(cmd) {
                        result.append(InstalledHook(
                            event: event,
                            arrayIndex: arrayIndex,
                            hookIndex: hookIndex
                        ))
                    }
                }
            }
        }
        return result
    }

    /// The command string at a given (event, arrayIndex, hookIndex) position in
    /// a parsed hooks.json, or nil if no hook exists there. Used to diff the old
    /// and new hooks.json across an installer rewrite.
    static func command(at hook: InstalledHook, in json: [String: Any]?) -> String? {
        guard let hooks = json?["hooks"] as? [String: Any],
              let entries = hooks[hook.event] as? [[String: Any]],
              hook.arrayIndex < entries.count,
              let entryHooks = entries[hook.arrayIndex]["hooks"] as? [[String: Any]],
              hook.hookIndex < entryHooks.count else {
            return nil
        }
        return entryHooks[hook.hookIndex]["command"] as? String
    }

    /// Installer-side stale-trust capture (GW-196). Given the hooks.json the
    /// installer is about to overwrite (`oldHooksJSON`), the hooks.json it will
    /// write (`newHooksJSON`), the current `[hooks.state]` map, and the hooks-file
    /// path, return the pending re-trust entries to record: position key ->
    /// stale trusted_hash.
    ///
    /// An entry is recorded only for a Ghostwire position whose command changes
    /// IN PLACE (same key, old command is also ours but differs from the new one)
    /// AND that currently has a trusted_hash in config.toml. A position with no
    /// current trusted_hash needs no entry — coverage detection already flags it.
    /// Pure over the parsed inputs so it's unit-testable on sample strings.
    static func staleTrustPositions(
        oldHooksJSON: [String: Any]?,
        newHooksJSON: [String: Any]?,
        state: [String: StateEntry],
        hooksFilePath: String
    ) -> [String: String] {
        var pending: [String: String] = [:]
        for hook in ghostwireHooks(in: newHooksJSON) {
            let newCmd = command(at: hook, in: newHooksJSON)
            guard let oldCmd = command(at: hook, in: oldHooksJSON),
                  isGhostwireHookCommand(oldCmd),
                  oldCmd != newCmd else {
                continue
            }
            let key = hook.stateKey(hooksFilePath: hooksFilePath)
            // Only record if Codex had actually trusted the old command here;
            // otherwise coverage detection handles the missing-entry case.
            if let staleHash = state[key]?.trustedHash {
                pending[key] = staleHash
            }
        }
        return pending
    }

    /// A single `[hooks.state]` entry's trust state.
    struct StateEntry: Equatable {
        let trustedHash: String?
        let enabled: Bool?   // nil = key absent (Codex default = enabled)

        /// Trusted iff a hash is recorded and the entry isn't explicitly disabled.
        var isTrusted: Bool { trustedHash != nil && enabled != false }
    }

    /// Minimal line-based parser for the `[hooks.state]` section of config.toml.
    /// We only need the dotted sub-table keys plus their `trusted_hash` /
    /// `enabled` fields, so we avoid pulling in a full TOML dependency.
    ///
    /// Both layouts seen in real files are handled:
    ///   [hooks.state."<key>"]            (sub-table header, fields on next lines)
    ///   trusted_hash = "sha256:…"
    /// Returns a map of dotted-key (unquoted) -> StateEntry.
    static func parseHooksState(_ toml: String) -> [String: StateEntry] {
        var entries: [String: (hash: String?, enabled: Bool?)] = [:]
        var currentKey: String?

        for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("[") {
                // A new table header. Capture it if it's a hooks.state sub-table,
                // otherwise leave the section (subsequent fields aren't ours).
                if let key = hooksStateSubTableKey(line) {
                    currentKey = key
                    if entries[key] == nil { entries[key] = (nil, nil) }
                } else {
                    currentKey = nil
                }
                continue
            }

            guard let key = currentKey else { continue }
            if let (field, value) = keyValue(line) {
                var entry = entries[key] ?? (nil, nil)
                switch field {
                case "trusted_hash":
                    entry.hash = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                case "enabled":
                    entry.enabled = (value == "true")
                default:
                    break
                }
                entries[key] = entry
            }
        }

        return entries.mapValues { StateEntry(trustedHash: $0.hash, enabled: $0.enabled) }
    }

    // MARK: - Helpers

    /// Matches our hook command, including the legacy buddi-hook.py name (mirrors
    /// CodexHookInstaller.isOurHookCommand so detection and install agree).
    static func isGhostwireHookCommand(_ cmd: String) -> Bool {
        cmd.contains("ghostwire-hook.py") || cmd.contains("buddi-hook.py")
    }

    /// PascalCase event name -> snake_case, matching Codex's state keys
    /// (PreToolUse -> pre_tool_use, PermissionRequest -> permission_request).
    static func snakeCase(_ pascal: String) -> String {
        var out = ""
        for (i, ch) in pascal.enumerated() {
            if ch.isUppercase {
                if i != 0 { out.append("_") }
                out.append(Character(ch.lowercased()))
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// Extract the unquoted dotted key from a `[hooks.state."<key>"]` header.
    /// Returns nil for the bare `[hooks.state]` header or any other table.
    private static func hooksStateSubTableKey(_ header: String) -> String? {
        // Strip the surrounding [ ].
        guard header.hasPrefix("["), header.hasSuffix("]") else { return nil }
        let inner = String(header.dropFirst().dropLast())
        let prefix = "hooks.state."
        guard inner.hasPrefix(prefix) else { return nil }
        let quoted = String(inner.dropFirst(prefix.count))
        // The key itself is a basic-quoted string: "…".
        guard quoted.hasPrefix("\""), quoted.hasSuffix("\""), quoted.count >= 2 else { return nil }
        return String(quoted.dropFirst().dropLast())
    }

    /// Split a `field = value` line into its trimmed parts (value keeps quotes).
    private static func keyValue(_ line: String) -> (String, String)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let field = line[..<eq].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard !field.isEmpty else { return nil }
        return (field, value)
    }
}
