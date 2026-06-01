//
//  CodexHookInstaller.swift
//  Ghostwire
//
//  Auto-installs OpenAI Codex CLI hooks on app launch.
//  Mirrors HookInstaller (Claude Code) but targets ~/.codex/hooks.json.
//
//  Codex shares Claude's hook architecture: JSON-over-stdin/stdout, same
//  PascalCase event names, and a PermissionRequest output that is byte-identical
//  to Claude's ({hookSpecificOutput:{hookEventName,decision:{behavior}}}). So the
//  same buddi-hook.py serves both agents and no socket/event changes are needed.
//
//  Differences from Claude handled here:
//   - Codex has no `Notification` and no `SessionEnd` event — omitted.
//   - Hooks live in ~/.codex/hooks.json (dedicated file), not settings.json.
//   - Codex requires one-time hook trust via `/hooks` in the CLI before a newly
//     installed hook will run (it hashes each hook). The app cannot auto-trust;
//     first-run UX should surface this. See GW-149.
//

import Foundation

struct CodexHookInstaller {

    /// Install hook script and update ~/.codex/hooks.json on app launch
    static func installIfNeeded() {
        let codexDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
        let hooksDir = codexDir.appendingPathComponent("hooks")
        let pythonScript = hooksDir.appendingPathComponent("buddi-hook.py")
        let hooksFile = codexDir.appendingPathComponent("hooks.json")

        // Only install if the user actually has Codex set up.
        guard FileManager.default.fileExists(atPath: codexDir.path) else { return }

        try? FileManager.default.createDirectory(
            at: hooksDir,
            withIntermediateDirectories: true
        )

        if let bundled = Bundle.main.url(forResource: "buddi-hook", withExtension: "py") {
            try? FileManager.default.removeItem(at: pythonScript)
            try? FileManager.default.copyItem(at: bundled, to: pythonScript)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: pythonScript.path
            )
        }

        updateHooks(at: hooksFile)
    }

    private static func updateHooks(at hooksURL: URL) {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: hooksURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        let python = detectPython()
        let command = "BUDDI_AGENT=codex \(python) ~/.codex/hooks/buddi-hook.py"
        let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
        let hookEntryWithTimeout: [[String: Any]] = [["type": "command", "command": command, "timeout": 86400]]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withMatcherAndTimeout: [[String: Any]] = [["matcher": "*", "hooks": hookEntryWithTimeout]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        // Codex HookEventName set (codex-rs/protocol). No Notification, no SessionEnd.
        let hookEvents: [(String, [[String: Any]])] = [
            ("UserPromptSubmit", withoutMatcher),
            ("PreToolUse", withMatcher),
            ("PostToolUse", withMatcher),
            ("PermissionRequest", withMatcherAndTimeout),
            ("Stop", withoutMatcher),
            ("SubagentStop", withoutMatcher),
            ("SessionStart", withoutMatcher),
            ("PreCompact", withoutMatcher),
        ]

        for (event, config) in hookEvents {
            // Re-tag on every launch: strip any existing buddi hook commands, then
            // append the current (correctly-tagged) config. Skipping when present
            // would leave stale/untagged commands from older installs in place.
            var existingEvent = hooks[event] as? [[String: Any]] ?? []
            existingEvent = existingEvent.compactMap { entry -> [String: Any]? in
                guard var entryHooks = entry["hooks"] as? [[String: Any]] else { return entry }
                entryHooks.removeAll { ($0["command"] as? String ?? "").contains("buddi-hook.py") }
                // Drop the entry only if it was buddi-only; preserve co-located user hooks.
                guard !entryHooks.isEmpty else { return nil }
                var newEntry = entry
                newEntry["hooks"] = entryHooks
                return newEntry
            }
            existingEvent.append(contentsOf: config)
            hooks[event] = existingEvent
        }

        json["hooks"] = hooks

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: hooksURL)
        }
    }

    /// Check if Codex hooks are currently installed
    static func isInstalled() -> Bool {
        let hooksFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("hooks.json")

        guard let data = try? Data(contentsOf: hooksFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        for (_, value) in hooks {
            if let entries = value as? [[String: Any]] {
                for entry in entries {
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        for hook in entryHooks {
                            if let cmd = hook["command"] as? String,
                               cmd.contains("buddi-hook.py") {
                                return true
                            }
                        }
                    }
                }
            }
        }
        return false
    }

    /// Uninstall hooks from ~/.codex/hooks.json and remove script
    static func uninstall() {
        let codexDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
        let pythonScript = codexDir.appendingPathComponent("hooks").appendingPathComponent("buddi-hook.py")
        let hooksFile = codexDir.appendingPathComponent("hooks.json")

        try? FileManager.default.removeItem(at: pythonScript)

        guard let data = try? Data(contentsOf: hooksFile),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        for (event, value) in hooks {
            if var entries = value as? [[String: Any]] {
                entries.removeAll { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { hook in
                            let cmd = hook["command"] as? String ?? ""
                            return cmd.contains("buddi-hook.py")
                        }
                    }
                    return false
                }

                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: hooksFile)
        }
    }

    private static func detectPython() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return "python3"
            }
        } catch {}

        return "python"
    }
}
