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
//  Detection strategy — coverage, not hash recompute:
//    The exact bytes Codex feeds into the sha256 are NOT documented and live
//    inside the Codex binary, so we deliberately do NOT try to recompute the
//    hash (guessing it would be fragile and silently wrong). Instead we check
//    that every Ghostwire hook position currently present in hooks.json has a
//    corresponding trusted `[hooks.state]` entry that is not explicitly
//    disabled. The rename failure mode surfaces exactly here: the new command
//    lands at a position whose state key is absent (or its old hash entry was
//    superseded), so coverage drops and we report `.retrustRequired`.
//

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

        return status(
            hooksJSON: hooksJSON,
            configTOML: configTOML,
            hooksFilePath: hooksFile.path
        )
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

    /// Pure form: derive trust from the parsed hooks.json, the raw config.toml
    /// text, and the absolute hooks-file path used to key state entries.
    static func status(
        hooksJSON: [String: Any]?,
        configTOML: String,
        hooksFilePath: String
    ) -> TrustStatus {
        let installed = ghostwireHooks(in: hooksJSON)
        // No Ghostwire hooks present → nothing for Codex to trust.
        guard !installed.isEmpty else { return .notConfigured }

        let state = parseHooksState(configTOML)
        // No trust block at all yet (e.g. brand-new install, user hasn't opened
        // /hooks once) → the hooks won't fire until trusted.
        guard !state.isEmpty else { return .retrustRequired }

        for hook in installed {
            let key = hook.stateKey(hooksFilePath: hooksFilePath)
            guard let entry = state[key], entry.isTrusted else {
                return .retrustRequired
            }
        }
        return .trusted
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
