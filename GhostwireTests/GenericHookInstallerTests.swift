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
        XCTAssertEqual(AgentIdentity.tint(for: "CURSOR"), AgentIdentity.cursor) // case-insensitive
        XCTAssertEqual(AgentIdentity.tint(for: "nope"), AgentIdentity.neutral)
        XCTAssertEqual(AgentIdentity.tint(for: nil), AgentIdentity.neutral)
    }
}
