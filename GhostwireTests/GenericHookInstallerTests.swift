//
//  GenericHookInstallerTests.swift
//  GhostwireTests
//
//  GW-175: round-trip tests for the spec-driven third-party agent installer
//  (Cursor + the Family-A cluster). Installs into a temp home dir via the
//  injected `home:` seam — no real ~/.cursor etc. is touched.
//

import XCTest
@testable import Ghostwire

final class GenericHookInstallerTests: XCTestCase {

    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostwire-hooktest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: helpers

    private func makeConfigDir(_ name: String) throws {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(name), withIntermediateDirectories: true
        )
    }

    private func readJSON(_ spec: HookInstallSpec) throws -> [String: Any] {
        let data = try Data(contentsOf: spec.configFileURL(home))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func isOurs(_ cmd: Any?) -> Bool {
        (cmd as? String)?.contains("ghostwire-hook.py") ?? false
    }

    // MARK: cursorFlat

    func testCursorInstallWritesFlatHooksWithVersionAndTimeout() throws {
        let spec = GenericHookInstaller.cursor
        GenericHookInstaller.installIfNeeded(spec, home: home, binaryAvailable: true)

        XCTAssertTrue(GenericHookInstaller.isInstalled(spec, home: home))
        let json = try readJSON(spec)
        XCTAssertEqual(json["version"] as? Int, 1)

        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        // Gate event: flat entry carrying our command + the approval timeout.
        let pre = try XCTUnwrap(hooks["preToolUse"] as? [[String: Any]])
        let gate = try XCTUnwrap(pre.first { isOurs($0["command"]) })
        XCTAssertEqual(gate["type"] as? String, "command")
        XCTAssertEqual(gate["timeout"] as? Int, 86400)
        XCTAssertTrue((gate["command"] as? String)?.contains("GHOSTWIRE_AGENT=cursor") ?? false)

        // Shell + MCP gates are registered too.
        let shell = try XCTUnwrap(hooks["beforeShellExecution"] as? [[String: Any]])
        XCTAssertTrue(shell.contains { isOurs($0["command"]) })
        let mcp = try XCTUnwrap(hooks["beforeMCPExecution"] as? [[String: Any]])
        XCTAssertTrue(mcp.contains { isOurs($0["command"]) })

        // Non-gate event: no timeout.
        let post = try XCTUnwrap(hooks["postToolUse"] as? [[String: Any]])
        let postEntry = try XCTUnwrap(post.first { isOurs($0["command"]) })
        XCTAssertNil(postEntry["timeout"])
    }

    // MARK: matcherGroup

    func testMatcherGroupInstallWritesNestedHooks() throws {
        let spec = GenericHookInstaller.qoder
        GenericHookInstaller.installIfNeeded(spec, home: home, binaryAvailable: true)

        XCTAssertTrue(GenericHookInstaller.isInstalled(spec, home: home))
        let json = try readJSON(spec)
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let pre = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        let group = try XCTUnwrap(pre.first)
        XCTAssertEqual(group["matcher"] as? String, "*")
        let inner = try XCTUnwrap(group["hooks"] as? [[String: Any]])
        let hook = try XCTUnwrap(inner.first { isOurs($0["command"]) })
        XCTAssertEqual(hook["timeout"] as? Int, 86400)
        XCTAssertTrue((hook["command"] as? String)?.contains("GHOSTWIRE_AGENT=qoder") ?? false)
    }

    func testGeminiInstallStampsTimeoutInMilliseconds() throws {
        // gemini-cli feeds the hook `timeout` field straight to setTimeout, so
        // it is MILLISECONDS there while every other agent reads seconds
        // (@google/gemini-cli 0.54.0, DEFAULT_HOOK_TIMEOUT = 6e4 = the
        // documented 60s default). 86400 here would cap a human approval at
        // 86 seconds — GW-174.
        let spec = GenericHookInstaller.gemini
        GenericHookInstaller.installIfNeeded(spec, home: home, binaryAvailable: true)

        XCTAssertTrue(GenericHookInstaller.isInstalled(spec, home: home))
        let json = try readJSON(spec)
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])

        let before = try XCTUnwrap(hooks["BeforeTool"] as? [[String: Any]])
        let group = try XCTUnwrap(before.first)
        XCTAssertEqual(group["matcher"] as? String, "*")
        let hook = try XCTUnwrap((group["hooks"] as? [[String: Any]])?.first { isOurs($0["command"]) })
        XCTAssertEqual(hook["timeout"] as? Int, 86_400_000)
        XCTAssertTrue((hook["command"] as? String)?.contains("GHOSTWIRE_AGENT=gemini") ?? false)

        // Telemetry events stay untimed, and AfterAgent must be registered —
        // gemini-cli has no Stop, so it is the only end-of-turn signal.
        let afterAgent = try XCTUnwrap(hooks["AfterAgent"] as? [[String: Any]])
        let telemetry = try XCTUnwrap(
            (afterAgent.first?["hooks"] as? [[String: Any]])?.first { isOurs($0["command"]) }
        )
        XCTAssertNil(telemetry["timeout"])
    }

    func testSecondsAgentsKeepSecondsTimeout() throws {
        // Guard the unit split from regressing in the other direction.
        for spec in GenericHookInstaller.all where spec.gateTimeoutUnit == .seconds {
            let scratch = home.appendingPathComponent(spec.agentId)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            GenericHookInstaller.installIfNeeded(spec, home: scratch, binaryAvailable: true)
            let data = try Data(contentsOf: spec.configFileURL(scratch))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
            let gateEvent = try XCTUnwrap(spec.events.first { $0.isGate }?.name)
            let entries = try XCTUnwrap(hooks[gateEvent] as? [[String: Any]])
            let timeouts = entries.compactMap { entry -> Int? in
                if let inner = entry["hooks"] as? [[String: Any]] {
                    return inner.first { isOurs($0["command"]) }?["timeout"] as? Int
                }
                return isOurs(entry["command"]) ? entry["timeout"] as? Int : nil
            }
            XCTAssertEqual(timeouts.first, 86400, "\(spec.agentId) gate timeout")
        }
    }

    // MARK: config safety

    func testInstallLeavesAnUnparseableConfigAlone() throws {
        // These files hold the user's whole agent config. Overwriting one we
        // could not read would replace it with hooks and nothing else.
        let spec = GenericHookInstaller.gemini
        try makeConfigDir(".gemini")
        let broken = "{ not json at all"
        try broken.write(to: spec.configFileURL(home), atomically: true, encoding: .utf8)

        GenericHookInstaller.installIfNeeded(spec, home: home, binaryAvailable: true)

        XCTAssertEqual(try String(contentsOf: spec.configFileURL(home), encoding: .utf8), broken)
        XCTAssertFalse(GenericHookInstaller.isInstalled(spec, home: home))
    }

    func testInstallLeavesAConfigWithAnUnmergeableHooksShapeAlone() throws {
        // `hooks` present but not an object is a shape we cannot merge into.
        // Overwriting it would silently drop whatever the user meant by it.
        let spec = GenericHookInstaller.gemini
        try makeConfigDir(".gemini")
        let existing: [String: Any] = ["hooks": ["not", "an", "object"], "model": ["name": "x"]]
        try JSONSerialization.data(withJSONObject: existing)
            .write(to: spec.configFileURL(home))
        let before = try Data(contentsOf: spec.configFileURL(home))

        GenericHookInstaller.installIfNeeded(spec, home: home, binaryAvailable: true)

        XCTAssertEqual(try Data(contentsOf: spec.configFileURL(home)), before)
        XCTAssertFalse(GenericHookInstaller.isInstalled(spec, home: home))
    }

    func testInstallLeavesAnUnreadableConfigAlone() throws {
        // A read failure on an existing file is not permission to replace it.
        let spec = GenericHookInstaller.gemini
        try makeConfigDir(".gemini")
        try Data("{}".utf8).write(to: spec.configFileURL(home))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: spec.configFileURL(home).path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: spec.configFileURL(home).path
            )
        }

        GenericHookInstaller.installIfNeeded(spec, home: home, binaryAvailable: true)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: spec.configFileURL(home).path
        )
        XCTAssertEqual(try String(contentsOf: spec.configFileURL(home), encoding: .utf8), "{}")
    }

    func testInstallPreservesUnrelatedTopLevelSettings() throws {
        let spec = GenericHookInstaller.gemini
        try makeConfigDir(".gemini")
        let existing: [String: Any] = [
            "mcpServers": ["linear": ["command": "npx"]],
            "model": ["name": "gemini-3-pro"],
        ]
        try JSONSerialization.data(withJSONObject: existing)
            .write(to: spec.configFileURL(home))

        GenericHookInstaller.installIfNeeded(spec, home: home, binaryAvailable: true)

        let json = try readJSON(spec)
        XCTAssertNotNil(json["mcpServers"])
        XCTAssertEqual((json["model"] as? [String: Any])?["name"] as? String, "gemini-3-pro")
        XCTAssertTrue(GenericHookInstaller.isInstalled(spec, home: home))
    }

    // MARK: detection guard

    func testInstallSkipsWhenBinaryAbsent() throws {
        let spec = GenericHookInstaller.factory
        GenericHookInstaller.installIfNeeded(spec, home: home, binaryAvailable: false)
        XCTAssertFalse(GenericHookInstaller.isInstalled(spec, home: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: spec.configFileURL(home).path))
    }

    func testBinaryAvailabilityChecksKnownBinDirs() {
        // /bin/ls is in the search dirs; a bogus name is not.
        XCTAssertTrue(GenericHookInstaller.isBinaryAvailable("ls"))
        XCTAssertFalse(GenericHookInstaller.isBinaryAvailable("ghostwire-no-such-binary-xyz"))
    }

    // MARK: idempotence

    func testInstallTwiceDoesNotDuplicate() throws {
        let spec = GenericHookInstaller.codebuddy
        GenericHookInstaller.installIfNeeded(spec, home: home, binaryAvailable: true)
        GenericHookInstaller.installIfNeeded(spec, home: home, binaryAvailable: true)

        let json = try readJSON(spec)
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let pre = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        let ourGroups = pre.filter { group in
            (group["hooks"] as? [[String: Any]])?.contains { isOurs($0["command"]) } ?? false
        }
        XCTAssertEqual(ourGroups.count, 1, "re-install should re-tag, not duplicate")
    }

    // MARK: uninstall

    func testUninstallRemovesOurHooks() throws {
        let spec = GenericHookInstaller.cursor
        GenericHookInstaller.installIfNeeded(spec, home: home, binaryAvailable: true)
        XCTAssertTrue(GenericHookInstaller.isInstalled(spec, home: home))

        GenericHookInstaller.uninstall(spec, home: home)
        XCTAssertFalse(GenericHookInstaller.isInstalled(spec, home: home))
    }

    func testUninstallPreservesCoLocatedUserHooks() throws {
        try makeConfigDir(".qoder")
        let spec = GenericHookInstaller.qoder
        // Seed a user-owned hook in a gate event before we ever install.
        let userHook = "/usr/bin/my-user-hook"
        let seed: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "*", "hooks": [["type": "command", "command": userHook]]]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: seed)
        try data.write(to: spec.configFileURL(home))

        GenericHookInstaller.installIfNeeded(spec, home: home, binaryAvailable: true)
        GenericHookInstaller.uninstall(spec, home: home)

        let json = try readJSON(spec)
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let pre = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        let userStillThere = pre.contains { group in
            (group["hooks"] as? [[String: Any]])?
                .contains { ($0["command"] as? String) == userHook } ?? false
        }
        XCTAssertTrue(userStillThere, "user's own hook must survive our uninstall")
        XCTAssertFalse(GenericHookInstaller.isInstalled(spec, home: home))
    }

    func testUninstallPreservesUserHookSharingOurMatcherGroup() throws {
        try makeConfigDir(".qoder")
        let spec = GenericHookInstaller.qoder
        let userHook = "/usr/bin/co-located-user-hook"
        let ourCommand = "GHOSTWIRE_AGENT=qoder python3 ~/.qoder/hooks/ghostwire-hook.py"
        // Externally co-located: our command and a user command share ONE matcher
        // entry's hooks array (what the P2 finding flagged).
        let seed: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "*", "hooks": [
                        ["type": "command", "command": userHook],
                        ["type": "command", "command": ourCommand],
                    ]]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: seed).write(to: spec.configFileURL(home))

        GenericHookInstaller.uninstall(spec, home: home)

        let json = try readJSON(spec)
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let pre = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        let group = try XCTUnwrap(pre.first)
        let inner = try XCTUnwrap(group["hooks"] as? [[String: Any]])
        XCTAssertTrue(inner.contains { ($0["command"] as? String) == userHook },
                      "co-located user hook must survive uninstall")
        XCTAssertFalse(inner.contains { isOurs($0["command"]) }, "our hook should be gone")
    }

    // MARK: registry coverage

    func testAllSpecsHaveUniqueIdsAndOneGate() {
        let ids = GenericHookInstaller.all.map(\.agentId)
        XCTAssertEqual(Set(ids).count, ids.count, "agent ids must be unique")
        for spec in GenericHookInstaller.all {
            XCTAssertTrue(spec.events.contains { $0.isGate }, "\(spec.agentId) needs a gate event")
        }
    }

    // MARK: identity tints

    func testTintForKnownAndUnknownAgents() {
        XCTAssertEqual(AgentIdentity.tint(for: "cursor"), AgentIdentity.cursor)
        XCTAssertEqual(AgentIdentity.tint(for: "copilot"), AgentIdentity.copilot)
        XCTAssertEqual(AgentIdentity.tint(for: "factory"), AgentIdentity.factory)
        XCTAssertEqual(AgentIdentity.tint(for: "qoder"), AgentIdentity.qoder)
        XCTAssertEqual(AgentIdentity.tint(for: "codebuddy"), AgentIdentity.codebuddy)
        XCTAssertEqual(AgentIdentity.tint(for: "gemini"), AgentIdentity.gemini)
        XCTAssertEqual(AgentIdentity.tint(for: "CURSOR"), AgentIdentity.cursor) // case-insensitive
        XCTAssertEqual(AgentIdentity.tint(for: "nope"), AgentIdentity.neutral)
        XCTAssertEqual(AgentIdentity.tint(for: nil), AgentIdentity.neutral)
    }
}
