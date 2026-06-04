//
//  CodexHookTrustTests.swift
//  GhostwireTests
//
//  GW-196: Codex marks the Ghostwire hooks untrusted when their command changes
//  (e.g. the buddi-hook.py -> ghostwire-hook.py rename) and silently stops
//  firing them until the user re-trusts via `/hooks`. CodexHookTrust detects
//  this by checking that every installed Ghostwire hook position in hooks.json
//  has a trusted, enabled `[hooks.state]` entry in config.toml.
//
//  The exact bytes Codex feeds into the sha256 are undocumented and internal to
//  the binary, so detection is coverage-based (is there a trusted entry for this
//  position?) rather than a hash recompute. These are pure functions over sample
//  toml / hooks.json strings — no disk, no Codex install required.
//

import XCTest
@testable import Ghostwire

final class CodexHookTrustTests: XCTestCase {

    private let hooksPath = "/Users/me/.codex/hooks.json"

    // A minimal hooks.json with one Ghostwire-tagged command per event, in the
    // matcher/no-matcher shapes CodexHookInstaller writes.
    private func hooksJSON(command: String = "GHOSTWIRE_AGENT=codex python3 ~/.codex/hooks/ghostwire-hook.py") -> [String: Any] {
        [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "*", "hooks": [["type": "command", "command": command]]]
                ],
                "Stop": [
                    ["hooks": [["type": "command", "command": command]]]
                ],
            ]
        ]
    }

    // MARK: - State parsing

    func testParsesSubTableEntries() {
        let toml = """
        [hooks.state]

        [hooks.state."\(hooksPath):pre_tool_use:0:0"]
        trusted_hash = "sha256:42e7f4894f995941c4a69724b3c3450149186ab3d3e4f72b369449007264f69c"
        enabled = true

        [hooks.state."\(hooksPath):stop:0:0"]
        trusted_hash = "sha256:1057130d5b49274469ac6953e45bf192142883f104f0bf9463cc7e7ecca20173"
        """
        let state = CodexHookTrust.parseHooksState(toml)

        XCTAssertEqual(
            state["\(hooksPath):pre_tool_use:0:0"]?.trustedHash,
            "sha256:42e7f4894f995941c4a69724b3c3450149186ab3d3e4f72b369449007264f69c"
        )
        XCTAssertEqual(state["\(hooksPath):pre_tool_use:0:0"]?.enabled, true)
        // enabled absent => nil (Codex default = enabled); still trusted.
        XCTAssertNil(state["\(hooksPath):stop:0:0"]?.enabled)
        XCTAssertTrue(state["\(hooksPath):stop:0:0"]?.isTrusted ?? false)
    }

    func testIgnoresUnrelatedTables() {
        // The trust block sits between other tables in a real config.toml; the
        // parser must not bleed fields across section boundaries.
        let toml = """
        [hooks.state."\(hooksPath):pre_tool_use:0:0"]
        trusted_hash = "sha256:aaa"

        [desktop]
        appearanceTheme = "dark"
        trusted_hash = "sha256:should-not-be-captured"
        """
        let state = CodexHookTrust.parseHooksState(toml)
        XCTAssertEqual(state.count, 1)
        XCTAssertEqual(state["\(hooksPath):pre_tool_use:0:0"]?.trustedHash, "sha256:aaa")
    }

    func testDisabledEntryIsNotTrusted() {
        let toml = """
        [hooks.state."\(hooksPath):pre_tool_use:0:0"]
        trusted_hash = "sha256:aaa"
        enabled = false
        """
        let entry = CodexHookTrust.parseHooksState(toml)["\(hooksPath):pre_tool_use:0:0"]
        XCTAssertEqual(entry?.enabled, false)
        XCTAssertFalse(entry?.isTrusted ?? true)
    }

    // MARK: - Hook enumeration

    func testEnumeratesGhostwireHooksWithPositions() {
        let hooks = CodexHookTrust.ghostwireHooks(in: hooksJSON())
        XCTAssertEqual(hooks.count, 2)
        XCTAssertTrue(hooks.contains(.init(event: "PreToolUse", arrayIndex: 0, hookIndex: 0)))
        XCTAssertTrue(hooks.contains(.init(event: "Stop", arrayIndex: 0, hookIndex: 0)))
    }

    func testIgnoresForeignHookCommands() {
        let json: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "*", "hooks": [["type": "command", "command": "some-other-tool.sh"]]]
                ]
            ]
        ]
        XCTAssertTrue(CodexHookTrust.ghostwireHooks(in: json).isEmpty)
    }

    func testStateKeyUsesSnakeCaseEvent() {
        let hook = CodexHookTrust.InstalledHook(event: "PermissionRequest", arrayIndex: 1, hookIndex: 0)
        XCTAssertEqual(
            hook.stateKey(hooksFilePath: hooksPath),
            "\(hooksPath):permission_request:1:0"
        )
    }

    func testSnakeCaseConversion() {
        XCTAssertEqual(CodexHookTrust.snakeCase("PreToolUse"), "pre_tool_use")
        XCTAssertEqual(CodexHookTrust.snakeCase("PermissionRequest"), "permission_request")
        XCTAssertEqual(CodexHookTrust.snakeCase("Stop"), "stop")
        XCTAssertEqual(CodexHookTrust.snakeCase("SessionStart"), "session_start")
    }

    // MARK: - End-to-end status

    func testTrustedWhenEveryHookHasTrustedEntry() {
        let toml = """
        [hooks.state."\(hooksPath):pre_tool_use:0:0"]
        trusted_hash = "sha256:aaa"
        enabled = true

        [hooks.state."\(hooksPath):stop:0:0"]
        trusted_hash = "sha256:bbb"
        """
        let status = CodexHookTrust.status(
            hooksJSON: hooksJSON(),
            configTOML: toml,
            hooksFilePath: hooksPath
        )
        XCTAssertEqual(status, .trusted)
    }

    func testRetrustRequiredWhenAHookPositionIsMissing() {
        // Only PreToolUse is trusted; Stop has no state entry — the canonical
        // post-rename / first-install state where Codex won't fire that hook.
        let toml = """
        [hooks.state."\(hooksPath):pre_tool_use:0:0"]
        trusted_hash = "sha256:aaa"
        """
        let status = CodexHookTrust.status(
            hooksJSON: hooksJSON(),
            configTOML: toml,
            hooksFilePath: hooksPath
        )
        XCTAssertEqual(status, .retrustRequired)
    }

    func testRetrustRequiredWhenEntryIsDisabled() {
        let toml = """
        [hooks.state."\(hooksPath):pre_tool_use:0:0"]
        trusted_hash = "sha256:aaa"

        [hooks.state."\(hooksPath):stop:0:0"]
        trusted_hash = "sha256:bbb"
        enabled = false
        """
        let status = CodexHookTrust.status(
            hooksJSON: hooksJSON(),
            configTOML: toml,
            hooksFilePath: hooksPath
        )
        XCTAssertEqual(status, .retrustRequired)
    }

    func testRetrustRequiredWhenNoTrustBlockYet() {
        // hooks.json has our hooks, config.toml has no [hooks.state] at all.
        let status = CodexHookTrust.status(
            hooksJSON: hooksJSON(),
            configTOML: "model = \"gpt-5.5\"\n",
            hooksFilePath: hooksPath
        )
        XCTAssertEqual(status, .retrustRequired)
    }

    func testNotConfiguredWhenNoGhostwireHooks() {
        // Codex is set up but our hooks aren't installed — nothing to trust.
        let status = CodexHookTrust.status(
            hooksJSON: ["hooks": [String: Any]()],
            configTOML: "[hooks.state]\n",
            hooksFilePath: hooksPath
        )
        XCTAssertEqual(status, .notConfigured)
    }

    func testNotConfiguredWhenHooksJSONAbsent() {
        let status = CodexHookTrust.status(
            hooksJSON: nil,
            configTOML: "[hooks.state]\n",
            hooksFilePath: hooksPath
        )
        XCTAssertEqual(status, .notConfigured)
    }

    func testLegacyBuddiCommandStillCountsAsOurs() {
        // A stale buddi-hook.py command is still "ours"; if it lacks a trusted
        // entry we correctly report re-trust required (the exact rename bug).
        let json = hooksJSON(command: "BUDDI_AGENT=codex python3 ~/.codex/hooks/buddi-hook.py")
        XCTAssertEqual(CodexHookTrust.ghostwireHooks(in: json).count, 2)
        let status = CodexHookTrust.status(
            hooksJSON: json,
            configTOML: "[hooks.state]\n",
            hooksFilePath: hooksPath
        )
        XCTAssertEqual(status, .retrustRequired)
    }

    func testRealWorldKeyShape() {
        // Guards the exact key format against a real ~/.codex/config.toml line:
        // [hooks.state."<path>:pre_tool_use:0:0"] with a sha256: hash.
        let toml = """
        [hooks.state."\(hooksPath):pre_tool_use:0:0"]
        trusted_hash = "sha256:42e7f4894f995941c4a69724b3c3450149186ab3d3e4f72b369449007264f69c"
        enabled = true
        """
        let state = CodexHookTrust.parseHooksState(toml)
        let key = CodexHookTrust.InstalledHook(event: "PreToolUse", arrayIndex: 0, hookIndex: 0)
            .stateKey(hooksFilePath: hooksPath)
        XCTAssertTrue(state[key]?.isTrusted ?? false)
    }
}
