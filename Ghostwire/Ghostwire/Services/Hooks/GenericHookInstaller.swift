//
//  GenericHookInstaller.swift
//  Ghostwire
//
//  Spec-driven hook installer for the third-party agent cluster (GW-175):
//  Cursor, Copilot, Factory droid, Qoder, CodeBuddy, gemini-cli (GW-174). Each
//  is described by a `HookInstallSpec` and installed/uninstalled through this
//  one code path, instead of a bespoke installer file per agent.
//
//  These agents converged on the Claude-Code hook model — a pre-tool event
//  that blocks, plus exit-code-2 as a universal deny lever — so the shared
//  ghostwire-hook.py adapter normalises their dialects on the way in and
//  denormalises the decision on the way out (see ghostwire-hook.py). No
//  HookSocketServer / session / approval changes are needed.
//
//  Two on-disk shapes are handled:
//   - .matcherGroup: Claude/Codex-style { hooks: { Event: [{matcher,hooks:[…]}] } }
//     in either a shared settings.json (Qoder, CodeBuddy, Copilot) or a
//     dedicated hooks.json (Factory droid).
//   - .cursorFlat: Cursor's { version:1, hooks: { event: [{command,type,…}] } }.
//
//  Field spelling / event names per agent should be re-confirmed against
//  current vendor docs before relying on a given agent in production.
//

import Foundation

struct HookInstallSpec {
    enum Nesting {
        /// Claude/Codex-style matcher-group nesting (settings.json or hooks.json).
        case matcherGroup
        /// Cursor's flat per-event array with a top-level `version`.
        case cursorFlat
    }

    /// GHOSTWIRE_AGENT value + AgentIdentity key.
    let agentId: String
    /// CLI executable name used for detection, e.g. "cursor-agent".
    let binaryName: String
    /// Config directory under $HOME, e.g. ".cursor".
    let configDirName: String
    /// Config file relative to the config dir, e.g. "hooks.json" / "settings.json".
    let configFile: String
    let nesting: Nesting
    /// Top-level `version` to stamp (Cursor wants 1); nil = omit.
    let topLevelVersion: Int?
    /// Native event names to register, and whether each is a blocking gate
    /// (gate events get the long approval timeout).
    let events: [(name: String, isGate: Bool)]
    /// Unit the agent reads the hook `timeout` field in. Claude/Codex and the
    /// Claude-schema clones take SECONDS; gemini-cli feeds the same field
    /// straight to `setTimeout`, so it is MILLISECONDS there (verified in
    /// @google/gemini-cli 0.54.0 `hookRunner.ts`: `DEFAULT_HOOK_TIMEOUT = 6e4`
    /// documented as the 60-second default). Writing 86400 to Gemini would cap
    /// a human approval at 86 seconds instead of a day — GW-174.
    var gateTimeoutUnit: GateTimeoutUnit = .seconds

    enum GateTimeoutUnit {
        case seconds
        case milliseconds
    }

    // Paths are computed against an injectable home dir so tests can install
    // into a temp directory instead of the user's real ~/.
    func configDirURL(_ home: URL) -> URL { home.appendingPathComponent(configDirName) }
    func configFileURL(_ home: URL) -> URL { configDirURL(home).appendingPathComponent(configFile) }
    func hooksDirURL(_ home: URL) -> URL { configDirURL(home).appendingPathComponent("hooks") }
    func scriptURL(_ home: URL) -> URL { hooksDirURL(home).appendingPathComponent("ghostwire-hook.py") }
}

enum GenericHookInstaller {

    /// How long a gate hook may hold while a human decides. Matches
    /// `DECISION_TIMEOUT_SECONDS` in ghostwire-hook.py — the agent owns the
    /// deadline, Ghostwire never expires a gate on a timer (GW-408).
    private static let approvalTimeoutSeconds = 86400

    private static func gateTimeout(_ spec: HookInstallSpec) -> Int {
        switch spec.gateTimeoutUnit {
        case .seconds: return approvalTimeoutSeconds
        case .milliseconds: return approvalTimeoutSeconds * 1000
        }
    }

    // MARK: Specs

    static let cursor = HookInstallSpec(
        agentId: "cursor",
        binaryName: "cursor-agent",
        configDirName: ".cursor",
        configFile: "hooks.json",
        nesting: .cursorFlat,
        topLevelVersion: 1,
        events: [
            ("preToolUse", true),
            ("beforeShellExecution", true),
            ("beforeMCPExecution", true),
            ("postToolUse", false),
            // Turn-start reset: without it a session sits in waitingForInput after
            // stop and the next turn's gate arrives with no processing event between
            // (Claude parity comes from UserPromptSubmit) — GW-175 live-drive finding.
            ("beforeSubmitPrompt", false),
            // GW-311: carries the assistant's reply text. Cursor's transcript is
            // written lazily, so this is how the notch chat gets prose.
            ("afterAgentResponse", false),
            ("stop", false),
            ("sessionStart", false),
            ("sessionEnd", false),
        ]
    )

    static let copilot = HookInstallSpec(
        agentId: "copilot",
        binaryName: "copilot",
        configDirName: ".copilot",
        configFile: "settings.json",
        nesting: .matcherGroup,
        topLevelVersion: nil,
        events: [
            ("preToolUse", true),
            ("postToolUse", false),
            ("sessionStart", false),
            ("sessionEnd", false),
            ("stop", false),
        ]
    )

    static let factory = HookInstallSpec(
        agentId: "factory",
        binaryName: "droid",
        configDirName: ".factory",
        configFile: "hooks.json",
        nesting: .matcherGroup,
        topLevelVersion: nil,
        events: [
            ("PreToolUse", true),
            ("PostToolUse", false),
            ("Stop", false),
            ("SessionStart", false),
            ("SessionEnd", false),
        ]
    )

    static let qoder = HookInstallSpec(
        agentId: "qoder",
        binaryName: "qodercli",
        configDirName: ".qoder",
        configFile: "settings.json",
        nesting: .matcherGroup,
        topLevelVersion: nil,
        events: [
            ("PreToolUse", true),
            ("PostToolUse", false),
            ("Stop", false),
        ]
    )

    static let codebuddy = HookInstallSpec(
        agentId: "codebuddy",
        binaryName: "codebuddy",
        configDirName: ".codebuddy",
        configFile: "settings.json",
        nesting: .matcherGroup,
        topLevelVersion: nil,
        events: [
            ("PreToolUse", true),
            ("PostToolUse", false),
            ("Stop", false),
            ("SessionStart", false),
            ("SessionEnd", false),
        ]
    )

    // gemini-cli (GW-174). Verified against @google/gemini-cli 0.54.0 source,
    // not docs — the bundle is on disk at
    // /opt/homebrew/lib/node_modules/@google/gemini-cli/bundle.
    //
    //  - Config lives in ~/.gemini/settings.json under `hooks`, Claude-style
    //    matcher groups. The merged (user + workspace) tree is what runs; only
    //    WORKSPACE hooks go through the trust warning, so a user-scope install
    //    needs no re-trust step (unlike Codex).
    //  - `BeforeTool` is the only gate: it runs to completion BEFORE the policy
    //    engine is consulted, and a silent hook leaves the policy decision
    //    untouched. Silence is therefore a true step-aside on Gemini — the
    //    native `ask_user` prompt still renders (GW-413 satisfied).
    //  - There is no `Stop`; `AfterAgent` is the end-of-turn event and it also
    //    carries the assistant's reply, so the adapter fans it out into an
    //    AgentMessage + a Stop.
    //  - `timeout` is MILLISECONDS here — see HookInstallSpec.gateTimeoutUnit.
    static let gemini = HookInstallSpec(
        agentId: "gemini",
        binaryName: "gemini",
        configDirName: ".gemini",
        configFile: "settings.json",
        nesting: .matcherGroup,
        topLevelVersion: nil,
        events: [
            ("BeforeTool", true),
            ("AfterTool", false),
            // Claude's UserPromptSubmit / Stop equivalents.
            ("BeforeAgent", false),
            ("AfterAgent", false),
            ("SessionStart", false),
            ("SessionEnd", false),
            ("Notification", false),
            ("PreCompress", false),
        ],
        gateTimeoutUnit: .milliseconds
    )

    static let all: [HookInstallSpec] = [cursor, copilot, factory, qoder, codebuddy, gemini]

    // MARK: Install

    static func installIfNeeded(
        _ spec: HookInstallSpec,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        binaryAvailable: Bool? = nil
    ) {
        // Only install when the agent's CLI is actually present. Detect by the
        // binary (config dirs linger after a CLI is removed), not the config
        // dir. `binaryAvailable` is injected by tests.
        guard binaryAvailable ?? isBinaryAvailable(spec.binaryName) else { return }

        // Create the config + hooks dir if the CLI hasn't run yet to make it.
        try? FileManager.default.createDirectory(
            at: spec.hooksDirURL(home), withIntermediateDirectories: true
        )

        if let bundled = Bundle.main.url(forResource: "ghostwire-hook", withExtension: "py") {
            try? FileManager.default.removeItem(at: spec.scriptURL(home))
            try? FileManager.default.copyItem(at: bundled, to: spec.scriptURL(home))
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: spec.scriptURL(home).path
            )
        }
        // Clean up any legacy buddi-hook.py left by older installs.
        try? FileManager.default.removeItem(
            at: spec.hooksDirURL(home).appendingPathComponent("buddi-hook.py")
        )

        updateHooks(spec, home: home)
    }

    private static func hookCommand(_ spec: HookInstallSpec) -> String {
        "GHOSTWIRE_AGENT=\(spec.agentId) \(detectPython()) ~/\(spec.configDirName)/hooks/ghostwire-hook.py"
    }

    private static func updateHooks(_ spec: HookInstallSpec, home: URL) {
        // An existing config we cannot fully understand must be left alone.
        // These files hold the user's whole agent configuration (MCP servers,
        // auth, model, other vendors' hooks); starting from `[:]` and writing
        // back would replace all of it with nothing but our hooks. Better to
        // install no hook than to eat someone's settings.json. Only a genuinely
        // absent file may be created from scratch — a read failure, a parse
        // failure, and a `hooks` value in a shape we cannot merge into all abort.
        let configURL = spec.configFileURL(home)
        var json: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: configURL.path) {
            guard let data = try? Data(contentsOf: configURL) else { return }
            if !data.isEmpty {
                guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return
                }
                if existing["hooks"] != nil, !(existing["hooks"] is [String: Any]) { return }
                json = existing
            }
        }

        if let version = spec.topLevelVersion {
            json["version"] = version
        }

        let command = hookCommand(spec)
        var hooks = json["hooks"] as? [String: Any] ?? [:]

        for (event, isGate) in spec.events {
            // Re-tag on every launch: strip any existing Ghostwire entries
            // (incl. legacy buddi-hook.py), then append the current command —
            // preserving co-located user hooks.
            switch spec.nesting {
            case .matcherGroup:
                var entries = hooks[event] as? [[String: Any]] ?? []
                entries = entries.compactMap { entry in
                    guard var entryHooks = entry["hooks"] as? [[String: Any]] else { return entry }
                    entryHooks.removeAll { isOurHookCommand($0["command"] as? String ?? "") }
                    guard !entryHooks.isEmpty else { return nil }
                    var newEntry = entry
                    newEntry["hooks"] = entryHooks
                    return newEntry
                }
                var hookObj: [String: Any] = ["type": "command", "command": command]
                if isGate { hookObj["timeout"] = gateTimeout(spec) }
                entries.append(["matcher": "*", "hooks": [hookObj]])
                hooks[event] = entries

            case .cursorFlat:
                var entries = hooks[event] as? [[String: Any]] ?? []
                entries.removeAll { isOurHookCommand($0["command"] as? String ?? "") }
                var hookObj: [String: Any] = ["type": "command", "command": command]
                if isGate { hookObj["timeout"] = gateTimeout(spec) }
                entries.append(hookObj)
                hooks[event] = entries
            }
        }

        json["hooks"] = hooks

        if let data = try? JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: configURL)
        }
    }

    // MARK: Status

    static func isInstalled(
        _ spec: HookInstallSpec,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        guard let data = try? Data(contentsOf: spec.configFileURL(home)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }
        for (_, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            for entry in entries {
                switch spec.nesting {
                case .matcherGroup:
                    if let entryHooks = entry["hooks"] as? [[String: Any]],
                       entryHooks.contains(where: { isOurHookCommand($0["command"] as? String ?? "") }) {
                        return true
                    }
                case .cursorFlat:
                    if isOurHookCommand(entry["command"] as? String ?? "") { return true }
                }
            }
        }
        return false
    }

    // MARK: Uninstall

    static func uninstall(
        _ spec: HookInstallSpec,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        try? FileManager.default.removeItem(at: spec.scriptURL(home))
        try? FileManager.default.removeItem(
            at: spec.hooksDirURL(home).appendingPathComponent("buddi-hook.py")
        )

        guard let data = try? Data(contentsOf: spec.configFileURL(home)),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        for (event, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            switch spec.nesting {
            case .matcherGroup:
                // Strip only our inner hooks; keep the matcher entry (and any
                // co-located user hooks) when it still has hooks left.
                entries = entries.compactMap { entry in
                    guard var entryHooks = entry["hooks"] as? [[String: Any]] else { return entry }
                    entryHooks.removeAll { isOurHookCommand($0["command"] as? String ?? "") }
                    guard !entryHooks.isEmpty else { return nil }
                    var newEntry = entry
                    newEntry["hooks"] = entryHooks
                    return newEntry
                }
            case .cursorFlat:
                entries.removeAll { isOurHookCommand($0["command"] as? String ?? "") }
            }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        if let data = try? JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: spec.configFileURL(home))
        }
    }

    // MARK: Helpers

    /// Directories a GUI app must check directly: launchd gives `LSUIElement`
    /// apps a minimal PATH that misses ~/.local/bin, Homebrew, etc., so a bare
    /// `which` would not find e.g. cursor-agent. Mirrors TmuxPathFinder /
    /// WindowFinder's fixed-path approach (no shell spawn, sync, fast).
    private static let binarySearchDirs: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "\(home)/.bun/bin",
            "\(home)/bin",
        ]
    }()

    /// Whether the agent's CLI executable is present in a known bin location.
    static func isBinaryAvailable(_ name: String) -> Bool {
        let fm = FileManager.default
        return binarySearchDirs.contains { fm.isExecutableFile(atPath: "\($0)/\(name)") }
    }

    /// Matches our hook command, including the legacy buddi-hook.py name so upgrades clean it up.
    private static func isOurHookCommand(_ cmd: String) -> Bool {
        cmd.contains("ghostwire-hook.py") || cmd.contains("buddi-hook.py")
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
            if process.terminationStatus == 0 { return "python3" }
        } catch {}
        return "python"
    }
}
